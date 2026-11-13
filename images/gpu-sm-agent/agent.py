#!/usr/bin/env python3
"""gpu-sm-agent: per-pod SM caps on top of KAI/Run:ai GPU fractions.

Runs as a privileged, hostPID DaemonSet next to KAI's gpu-fractioning mpsd.

Contract for an enforced pod (set by the platform, not by the user):
  annotations:
    gpu-fraction / gpu-memory        -> KAI, memory cap (driver-enforced, exact)
    ci.gpu/sm-percent: "25"          -> this agent, MPS active-thread percentage
    ci.gpu/mps-ns: "<name>"          -> this agent, MPS namespace name [a-z0-9]{1,30}
  volume: hostPath /run/nvidia-mps/shared/<name>  (type: Directory)
          mounted in the container; CUDA_MPS_PIPE_DIRECTORY points at it.
  kubelet keeps retrying the hostPath mount until the agent has created the
  namespace, so the container never starts without its cap.

Each tick the agent:
  1. reconciles MPS namespaces (create / fix percentage / delete orphans with
     the agent's prefix). The namespace's pinned-memory limit mirrors the value
     KAI wrote to nvidia.com/container.<c>.gpu-memory.request, as a second cap:
     under Sysbox, KAI's memacct sometimes applies another pod's limit.
  2. enforces: any GPU process that belongs to an enforced pod must be an MPS
     client (M+C) attached to that pod's own namespace; otherwise SIGKILL.
     This covers native contexts (skipping MPS) and joining another namespace
     through the /run/nvidia-mps tree that KAI's fractiond mounts into the pod.

Needs: hostPID, CAP_KILL, and an unconfined AppArmor profile (containerd's
default profile blocks signals to Sysbox containers).
"""
import json, os, re, signal, ssl, subprocess, sys, time, urllib.request

NODE = os.environ["NODE_NAME"]
PIPE = os.environ.get("MPS_CONTROL_PIPE", "/run/nvidia-mps")
SERVER = os.environ.get("MPS_SERVER", "shared")
PREFIX = os.environ.get("NS_PREFIX", "ci")
TICK = float(os.environ.get("TICK_SECONDS", "0.5"))
A_PCT, A_NS = "ci.gpu/sm-percent", "ci.gpu/mps-ns"
NAME_RE = re.compile(r"^[a-z0-9]{1,30}$")

SA = "/var/run/secrets/kubernetes.io/serviceaccount"
API = f"https://{os.environ['KUBERNETES_SERVICE_HOST']}:{os.environ['KUBERNETES_SERVICE_PORT']}"
CTX = ssl.create_default_context(cafile=f"{SA}/ca.crt")


def log(**kw):
    print(json.dumps({"ts": time.strftime("%H:%M:%S"), **kw}), flush=True)


def mps(*args, check=True):
    env = dict(os.environ, CUDA_MPS_PIPE_DIRECTORY=PIPE)
    r = subprocess.run(["nvidia-cuda-mps-control", "-p", "3", *args],
                       env=env, capture_output=True, text=True, timeout=10)
    if check and r.returncode != 0:
        raise RuntimeError(f"mps {' '.join(args)}: {r.stdout.strip()} {r.stderr.strip()}")
    return r.stdout


def node_pods():
    token = open(f"{SA}/token").read()
    req = urllib.request.Request(
        f"{API}/api/v1/pods?fieldSelector=spec.nodeName%3D{NODE}",
        headers={"Authorization": f"Bearer {token}"})
    with urllib.request.urlopen(req, context=CTX, timeout=5) as r:
        return json.load(r)["items"]


def desired(pods):
    """pod uid -> (ns name, pct, pod ref) for live pods carrying the annotations."""
    out, seen = {}, {}
    for p in pods:
        a = p["metadata"].get("annotations", {})
        if A_PCT not in a:
            continue
        ref = f'{p["metadata"]["namespace"]}/{p["metadata"]["name"]}'
        ns, pct = a.get(A_NS, ""), a[A_PCT]
        if p["status"].get("phase") in ("Succeeded", "Failed"):
            continue
        if not (NAME_RE.match(ns) and ns.startswith(PREFIX)):
            log(event="reject", pod=ref, reason=f"bad {A_NS}={ns!r} (need {PREFIX}[a-z0-9], <=30)")
            continue
        try:
            pct = float(pct); assert 1 <= pct <= 100
        except Exception:
            log(event="reject", pod=ref, reason=f"bad {A_PCT}={a[A_PCT]!r}")
            continue
        if ns in seen:
            log(event="reject", pod=ref, reason=f"namespace {ns} already used by {seen[ns]}")
            continue
        mem = kai_memory_mib(a)
        if mem is None:
            # KAI has not bound the pod yet; wait so the namespace is never
            # created without its memory cap.
            continue
        seen[ns] = ref
        out[p["metadata"]["uid"].replace("-", "_")] = (ns, pct, ref, mem)
    return out


def kai_memory_mib(annotations):
    """GPU memory KAI allotted to the pod, from nvidia.com/container.<c>.gpu-memory.request.

    Under Sysbox, KAI's memacct mis-attributes clients (they live in a nested
    <container>.scope/init.scope cgroup) and can apply another pod's limit, so the
    agent mirrors KAI's value onto the MPS namespace as a second, correct cap.
    """
    units = {"Ki": 1 / 1024, "Mi": 1, "Gi": 1024, "Ti": 1024 * 1024}
    vals = []
    for k, v in annotations.items():
        if k.startswith("nvidia.com/container.") and k.endswith(".gpu-memory.request"):
            m = re.match(r"^(\d+)(Ki|Mi|Gi|Ti)?$", v)
            if m:
                vals.append(int(int(m.group(1)) * units.get(m.group(2) or "Mi", 1)))
    return sum(vals) if vals else None


def mem_to_mib(s):
    m = re.match(r"^([\d.]+)([KMG])$", s)
    if not m:
        return None  # "unlimited"
    return float(m.group(1)) * {"K": 1 / 1024, "M": 1, "G": 1024}[m.group(2)]


def current_namespaces():
    """name -> (active thread percentage, pinned memory limit MiB or None)."""
    res = {}
    for line in mps("namespace", "list").splitlines()[1:]:
        f = line.split()
        if len(f) >= 5 and f[1] == SERVER:
            res[f[0]] = (float(f[4]), mem_to_mib(f[3]))
    return res


def reconcile(want):
    have = current_namespaces()
    wanted = {ns: (pct, mem) for ns, pct, _, mem in want.values()}
    for ns, (pct, mem) in wanted.items():
        if ns not in have:
            mps("namespace", "create", ns, f"--server={SERVER}")
            log(event="ns-create", ns=ns, pct=pct, mem_mib=mem)
        cur_pct, cur_mem = have.get(ns, (None, None))
        if cur_pct is None or abs(cur_pct - pct) > 1e-6 or cur_mem is None or abs(cur_mem - mem) > 1:
            mps("namespace", "set", ns, f"--server={SERVER}",
                f"--active-thread-percentage={pct:g}", f"--pinned-memory-limit={mem}M")
            log(event="ns-set", ns=ns, pct=pct, mem_mib=mem)
    for ns in have:
        if ns.startswith(PREFIX) and ns not in wanted:
            mps("namespace", "delete", ns, f"--server={SERVER}", check=False)
            log(event="ns-delete", ns=ns)


def gpu_processes():
    """[(pid, type)] from nvidia-smi; type is 'C', 'M+C', 'G', ..."""
    out = subprocess.run(["nvidia-smi", "-q", "-d", "PIDS"], capture_output=True,
                         text=True, timeout=10).stdout
    procs, pid = [], None
    for line in out.splitlines():
        line = line.strip()
        if line.startswith("Process ID"):
            pid = int(line.split(":")[1])
        elif line.startswith("Type") and pid is not None:
            procs.append((pid, line.split(":")[1].strip())); pid = None
    return procs


def mps_client_namespaces():
    """pid -> MPS namespace name for every connected MPS client."""
    res = {}
    for line in mps("client", "list", "--all", "--format=csv,noheader", check=False).splitlines():
        # PID,SERVER,DEVICE,PCI ID,LINUX NS,MAWS NS,CMD   (PID = host pid)
        # MAWS NS looks like "shared/citest (5)"
        f = [x.strip() for x in line.split(",")]
        if len(f) >= 6 and f[0].isdigit():
            res[int(f[0])] = f[5].split("/")[-1].split(" ")[0]
    return res


def pod_uid_of(pid):
    try:
        cg = open(f"/proc/{pid}/cgroup").read()
    except OSError:
        return None
    m = re.search(r"pod([0-9a-f]{8}_[0-9a-f]{4}_[0-9a-f]{4}_[0-9a-f]{4}_[0-9a-f]{12})", cg)
    return m.group(1) if m else None


UNLISTED = {}          # pid -> consecutive ticks seen as M+C but not in client list
UNLISTED_GRACE = 4    # ticks (~2 s) allowed for a connecting client to appear


def enforce(want):
    procs = gpu_processes()
    clients = mps_client_namespaces() if any(t == "M+C" for _, t in procs) else {}
    live = set()
    for pid, typ in procs:
        uid = pod_uid_of(pid)
        if uid not in want:
            continue
        ns, _, ref, _ = want[uid]
        if typ != "M+C":
            reason = f"native GPU context (type {typ}) bypassing MPS"
        elif clients.get(pid) == ns:
            UNLISTED.pop(pid, None)
            continue
        elif pid in clients:
            reason = f"MPS client in namespace {clients[pid]!r}, assigned {ns!r}"
        else:
            live.add(pid)
            UNLISTED[pid] = UNLISTED.get(pid, 0) + 1
            if UNLISTED[pid] < UNLISTED_GRACE:
                continue
            reason = "MPS client not attributable to any namespace"
        try:
            cmd = open(f"/proc/{pid}/cmdline", "rb").read().replace(b"\0", b" ").decode()[:200]
        except OSError:
            cmd = "?"
        try:
            os.kill(pid, signal.SIGKILL)
            log(event="kill", pod=ref, pid=pid, cmd=cmd, reason=reason)
        except ProcessLookupError:
            pass
        except PermissionError as e:
            log(event="kill-failed", pod=ref, pid=pid, cmd=cmd, reason=reason, error=str(e))
        UNLISTED.pop(pid, None)
    for pid in list(UNLISTED):
        if pid not in live:
            UNLISTED.pop(pid)


def main():
    log(event="start", node=NODE, server=SERVER, prefix=PREFIX, tick=TICK)
    while True:
        try:
            want = desired(node_pods())
            reconcile(want)
            enforce(want)
        except Exception as e:  # keep running; a missed tick is retried
            log(event="error", error=str(e)[:300])
        time.sleep(TICK)


if __name__ == "__main__":
    main()
