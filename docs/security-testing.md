# Security Testing Notes

## Scope

This document records security-related tests performed so far and the next tests planned for the Sysbox-based Kubernetes workload. It is a working test log, not a claim that the platform has been comprehensively security-tested.

---

## Tests Performed

### 1. HAMi GPU Memory Quota Enforcement

**Objective:** Check whether the configured GPU memory quota is enforced consistently.

**Environment observed:**
- Kubernetes on RKE2
- Sysbox runtime (`sysbox-runc`)
- HAMi GPU allocation
- NVIDIA A100-SXM4-40GB
- Configured GPU memory quota: 4 GiB
- PyTorch CUDA stress test

**Procedure and observations:**
- Ran the stress test in the normal process environment. PyTorch reported a 4 GiB limit, and larger allocation attempts failed.
- Ran the workload with `env -i`, preserving only `HOME` and a restricted `PATH`.
- In the minimal-environment run, the workload reportedly reached about 12.26 GiB peak allocation, while `nvidia-smi` showed approximately 13 GiB of GPU memory usage.

**Current interpretation:** This is a potential quota-enforcement bypass or enforcement inconsistency. It is not yet a confirmed, generally applicable vulnerability. The exact cause and repeatability still need to be established.

**Evidence:**
- Test environment setup: `testing/gpu-memory-quota/setup-venv.sh`
- Workload stress test: `testing/gpu-memory-quota/stress_test.py` (allocates and multiplies matrices across sizes $N \in [8192, 28672]$ with dwell time)
- Normal execution (enforced): `testing/gpu-memory-quota/with-env.sh`
  ```bash
  .venv/bin/python stress_test.py
  ```
- Minimal-environment execution (potential bypass): `testing/gpu-memory-quota/without-env.sh`
  ```bash
  env -i \
    HOME="$HOME" \
    PATH="/usr/local/cuda/bin:/usr/local/bin:/usr/bin:/bin" \
    "$HOME/hami-mem-test/.venv/bin/python" stress_test.py
  ```

---

### 2. Tailscale Connectivity from the Workload

**Objective:** Determine whether services inside the Sysbox workload can be reached through Tailscale without `/dev/net/tun`.

**Procedure and observations:**
- Tailscale initially failed in normal TUN mode because `/dev/net/tun` was absent inside the container.
- The host had the TUN device available.
- Switched Tailscale to userspace networking mode.
- SSH access through Tailscale worked.
- Started an HTTP server listening on `0.0.0.0:8080` and successfully accessed it through Tailscale.

**Current interpretation:** SSH and HTTP reachability through the tested Tailscale path are confirmed. This test does not establish that network isolation is secure or insecure, nor does it establish whether the services are reachable from the public internet.

---

### 3. Docker-in-Container Installation

**Objective:** Verify whether standard Docker can be installed and executed inside the Sysbox container without privileged container mode or mounting the host Docker socket.

**Procedure and observations:**
- Followed standard Docker installation procedures inside the instance (via official packages / apt).
- The Docker daemon (`dockerd`) started cleanly under systemd.
- Network interface inspection (`ip addr`) confirmed the presence of `docker0` bridge alongside `lo` and `eth0`.
- Standard Docker workflows executed normally inside the container without requiring `--privileged` permissions.

**Current interpretation:** Confirms that Sysbox's user namespace and virtualization capabilities properly support nested Docker containers out-of-the-box without requiring insecure host socket mounts or privileged container escalation.

---

### 4. Fail2ban Daemon Setup and Systemd Integration

**Objective:** Verify that Fail2ban is properly configured and starts automatically as a background service managed by systemd inside the container.

**Procedure and observations:**
- Configured Fail2ban with the systemd journal backend for the `sshd` jail (`jail.local`).
- Enabled the service (`systemctl enable fail2ban.service`) during container initialization (`entrypoint.sh`).
- Confirmed that the `fail2ban.service` daemon started automatically on boot under systemd without manual intervention.
- Verified operational status using `fail2ban-client status sshd`, confirming that the daemon was active and actively monitoring authentication logs.

**Current interpretation:** Confirms that Fail2ban integrates seamlessly with Sysbox's systemd init process, running automatically as a background daemon on boot and successfully tracking SSH authentication events via the journal.

**Configuration references:**
- SSH jail configuration: `images/sysbox-ssh-kube-cpu-aware/jail.local`
- Service enablement & immutability: `images/sysbox-ssh-kube-cpu-aware/entrypoint.sh`

---

## Planned Tests

The following tests are planned; they have **not** been established as completed by the evidence summarized above.

### P1. Network Isolation and Controlled Inter-Pod Communication

- **Default-deny isolation:** Verify that compute instance pods cannot communicate with other pods across or within the namespace by default (unauthorized east-west traffic is blocked/dropped).
- **Opt-in inter-pod communication:** Test mechanisms (e.g., Kubernetes `NetworkPolicy` rules or pod label selectors) that allow users to explicitly permit communication between designated pods when required (e.g., multi-node distributed training, worker-to-head cluster topologies).
- **Reachability and boundary verification:** Test traffic from authorized sources (such as the Tailscale ingress path) versus unauthorized internal pods. Confirm that only explicitly allowed pods and ports can communicate, while all other inter-pod traffic remains denied.

**Goal:** Ensure workloads remain isolated by default while supporting explicit, user-configured inter-pod communication.

### P2. Container-to-Host Isolation

- Review effective capabilities, mounts, namespaces, device access, and available host interfaces.
- Test only in an authorized, disposable environment.
- Record both successful and denied access attempts.

**Goal:** Evaluate the intended Sysbox isolation boundary. No host escape has been demonstrated by the tests recorded here.

### P3. Resource Limit Enforcement Beyond GPU Memory

- Test CPU, RAM, process-count, and storage limits in controlled workloads.
- Observe behavior at and beyond configured limits.
- Avoid affecting shared workloads or the host.

**Goal:** Determine whether resource limits behave as configured and whether one workload can materially affect others.

---

### 5. MPS Control-Plane Exposure to GPU-Fraction Tenants

**Objective:** Check whether a GPU-fraction tenant (root inside its own Sysbox instance) is confined to its own GPU slice, or can see and reach the shared MPS control plane and other tenants' resources.

**Environment:** As in [gpu-fractioning-sysbox.md](gpu-fractioning-sysbox.md) §2 — Run:ai 3.0.20 / KAI gpu-fractioning v0.1.6, driver 615.71.09 (MPS protocol 3), Sysbox CE 0.7.1, `nvidia-sysbox` runtime, A100-40GB. Two 0.25-fraction pods (`atk`, `vic`) in the same Run:ai project namespace.

**Root cause (by design in KAI):** the `fractiond` NRI plugin bind-mounts the **entire** host `/run/nvidia-mps` tree into every fractional pod and sets `CUDA_MPS_PIPE_DIRECTORY=/run/nvidia-mps`. That tree contains the MPS root control socket (`control`, mode `srw-rw-rw-`) and **every** tenant's namespace subdirectory, not just the pod's own.

**Observations (from pod `atk`, as container root):**
- **Cross-tenant visibility (confirmed).** Using the root control socket, `atk` listed the full MPS state: every namespace with its memory and SM limits (including the other tenant `civic`), every MPS server, and every GPU client process cluster-wide (`client list --all`). A tenant can enumerate all co-resident tenants' GPU allocations and PIDs.
- **Write access to shared directories (confirmed).** `atk` could create and delete files in `/run/nvidia-mps`, `/run/nvidia-mps/shared`, and the *other* tenant's directory `/run/nvidia-mps/shared/civic`. (Test files were created and immediately removed.)
- **Control socket reachable (confirmed).** The root control daemon accepted read commands (`namespace list`, `client list`, `server list`, `feature describe`) from the tenant.

**Not tested (deliberately stopped):** whether a tenant can issue *mutating* control commands against another tenant — e.g. `namespace set civic --active-thread-percentage=…` or `namespace delete civic` — which, if accepted, would let one tenant shrink, starve, or disrupt another's GPU slice. This is the highest-value follow-up and should be tested with a disposable victim only.

**Current interpretation:** This is a **shared control plane across tenant boundaries**, not a host escape. The per-namespace memory and SM limits themselves held in all earlier tests; the concern is confidentiality (one tenant seeing all others) and the untested possibility of one tenant altering another's slice through the shared root socket. It stems from KAI's whole-tree mount, so it affects any `NvFractions` deployment, with or without Sysbox.

**Mitigations:**
- Mount only the pod's own namespace subdirectory (`/run/nvidia-mps/shared/<ns>`) and point `CUDA_MPS_PIPE_DIRECTORY` at it, instead of the whole `/run/nvidia-mps` tree. The `gpu-sm-agent` example pod already mounts just `/run/ci-mps = shared/<ns>`; the exposure comes from the *additional* whole-tree mount and env var that `fractiond` injects, which would need to be overridden or the plugin reconfigured.
- Report upstream to KAI gpu-fractioning (v0.1.6) as a tenant-isolation issue.
- Until then, treat co-scheduled GPU fractions as **mutually trusting**: do not place fractions from different trust domains on the same physical GPU; use a whole GPU or MIG for untrusted tenants.

**Evidence / repro:** `testing/gpu-fractioning/mk-ci-pod.sh` to create two fraction pods, then from inside one: `CUDA_MPS_PIPE_DIRECTORY=/run/nvidia-mps nvidia-cuda-mps-control -p 3 namespace list`.

**Update (2026-11-13, follow-up testing):** the mutating cross-tenant commands were tested — see §6 below. They are **blocked** by Sysbox's UID remapping, so finding #5 is read-only cross-tenant *visibility* (confidentiality), not integrity/availability.

---

### 6. Cross-Tenant MPS Control, Compute Bypass, and Isolation (GPU fractions)

**Objective:** With two GPU-fraction tenants (`atk`, `vic`) co-scheduled on one A100, test whether one can modify another's slice, bypass its own compute cap, escape to the host, reach other pods, or exhaust shared resources. Setup as in §5. Each test states what was confirmed; the host was never put at risk (no reboot/escape primitives run).

#### 6a. Mutating cross-tenant MPS control — **blocked**
From `atk` (container root), attempts to `namespace set civic …`, `namespace delete civic`, `namespace create`, and `client terminate <victim pid>` against the shared MPS server all failed:

```
Error: Insufficient privileges for UID 3921281024. 'NAMESPACE SET' requires root.
```

MPS protocol 3 requires **real UID 0** for mutating control commands. Sysbox (`hostUsers: false`) maps container-root to a non-zero host UID (here 3921281024), so every mutating command is refused. The victim's namespace, limits, and GPU client were unchanged.

> **Dependency:** this protection relies on `hostUsers: false`. A GPU pod run **without** user namespacing (container-root = host UID 0) would pass the UID check and *could* alter or delete other tenants' MPS namespaces. Compute Instances must keep `hostUsers: false`.

So finding #5 downgrades to **read-only cross-tenant visibility**: a tenant can still *list* all namespaces, their memory/SM limits, and all GPU client PIDs (via its own namespace socket as well as the root socket — the namespace list is global to the shared server). This is inherent to KAI's single shared MPS server, not fixable from the pod spec (an emptyDir mounted over `/run/nvidia-mps` is overridden by fractiond's later NRI mount; tested). The isolation boundary for *untrusting* tenants is a **separate MPS server per tenant** (`server create --uid`) or a separate GPU/MIG — not a shared fraction.

#### 6b. Compute-cap bypass via forged annotation — **was open, now patched**
A pod requesting `gpu-fraction: "0.1"` (memory) but `ci.gpu/sm-percent: "100"` (compute) received **all 108 SMs** (97.6 TFLOPS) on 4 GiB. The `gpu-sm-agent` trusted the SM annotation as the cap, so any workload that could set it escaped its compute share.
**Patch:** the agent now clamps the requested SM% to the memory fraction, `min(requested, ceil(mem/gpu_total*100) + SM_SLACK)` (slack default 5 pts), using the node's `nvidia.com/gpu.memory` label as the true physical total. After the patch the same pod was clamped to 15% → **16 SMs, 21.9 TFLOPS**. (It still needs admission control to stop a tenant *lowering* another pod's annotations, but a tenant can no longer grant itself more compute than its fraction.)

#### 6c. Native-context compute bypass under contention — **caught by agent**
With `vic` running, `atk` launched a GPU job with MPS disabled (`CUDA_MPS_PIPE_DIRECTORY=/nonexistent`) to grab all SMs. The agent killed it within one tick (`native GPU context (type C) bypassing MPS`); `vic` was unaffected.

#### 6d. Container-to-host isolation (P2) — **holds**
From `atk`: PID namespace isolated (5 visible PIDs, host MPS daemon not visible), seccomp active (filter mode 2). The container has a full capability set (`CapEff=000001ffffffffff`) but these are **namespaced** by Sysbox and don't act on the host — the Sysbox model. `/var/lib/rancher/{rke2,k3s}` appear inside but are Sysbox's **empty per-container** mounts (backed by `/var/lib/sysbox/rancher-*`), not host data (confirmed empty). Active escape primitives (`nsenter -t 1`, `modprobe`, `/proc/sysrq-trigger`) were **not** run, to protect the host.

#### 6e. Resource limits beyond GPU memory (P3) — **CPU/RAM enforced, PID limit missing**
A pod with `cpu: "1"`, `memory: 512Mi`:
- `cpu.max = 100000 100000` → 4 busy threads throttled to **1.00 core**. ✅
- `memory.max = 536870912` → an 800 MiB allocation was **OOM-killed** (exit 137). ✅
- `pids.max = 57709` → **node default, no per-pod PID limit**. A fork bomb in one tenant could exhaust node PIDs and affect neighbors. (Fork bomb not run.) **Fix:** set kubelet `--pod-max-pids` (or a per-pod PID limit). ⚠️

#### 6g. Shared MPS server wedged by namespace churn — **observed, recovered by restart**
During this testing round (many rapid `namespace create/delete`, concurrent clients, and rejected mutating attempts), the shared MPS server stopped completing **namespace-client** handshakes: new fraction clients connected and appeared in `client list` but hung in `pipe_read` waiting for a context that never came. Native/root-socket clients (plain KAI path) kept working, so the server was only partly wedged. Recovery: restart KAI's `mpsd` DaemonSet pod (resets the server and all namespaces; the agent recreates its `ci*` namespaces; running fraction pods must be restarted). After restart the fraction path worked immediately (26 SMs, exact 10 GiB).
**Implications:** (1) availability risk — heavy MPS namespace churn can degrade all fraction tenants on the GPU; the agent should rate-limit create/delete and ideally detect a wedge and trigger an mpsd restart. (2) Operational: an mpsd restart is a clean recovery and the agent reconciles automatically. This closes the earlier "mpsd restart not tested" item in gpu-fractioning-sysbox.md §9.3.

#### 6f. Network isolation (P1) — **open by default, patch provided**
No `NetworkPolicy` exists in the tenant project namespace. From `atk`, confirmed reachable: another pod's listener (east-west, got a reply), cluster DNS, the API server, the **node's own SSH** (`<node-ip>:22`), and the **public internet** (`1.1.1.1:443`). The default ServiceAccount token is mounted but **low-privilege** (all API calls → 403).
**Patch:** [`manifests/netpol-default-deny.yaml`](../manifests/netpol-default-deny.yaml) — default-deny ingress/egress with a DNS carve-out, one per tenant namespace. Verified on a throwaway namespace: east-west **blocked**, internet egress **blocked**, DNS still resolves. Plus `automountServiceAccountToken: false` on the pod ([`manifests/pod-gpu-fraction-sm.yaml`](../manifests/pod-gpu-fraction-sm.yaml)).

---

## Patches applied in this round

| Finding | Patch | Verified |
|---|---|---|
| 6b compute-cap bypass via `sm-percent` | `gpu-sm-agent` clamps SM% to the memory fraction (uses node `nvidia.com/gpu.memory` label) | ✅ 100→15 % (16 SMs) |
| 6f network wide-open | `manifests/netpol-default-deny.yaml` (default-deny + DNS); `automountServiceAccountToken: false` | ✅ east-west & egress blocked, DNS ok |
| 5 cross-tenant MPS visibility | **Not fixable in pod spec**; documented. Use separate MPS server / GPU / MIG for untrusting tenants; report upstream to KAI | — |
| 6e missing PID limit | Documented; set kubelet `--pod-max-pids` | — (not applied: kubelet change) |
| 6a mutating MPS control | Already blocked by `hostUsers: false`; documented as a hard requirement | ✅ blocked |

---

### 7. Round 3: upstream KAI + forked gpu-fractioning (2026-11-14)

Run:ai was removed. GPU fractions now come from upstream KAI-Scheduler v0.18.3 plus the forked gpu-fractioning `v0.1.6-sm.3` with `smLimit.enforce` and `memoryGuard` on (details: [gpu-fractioning-sysbox.md](gpu-fractioning-sysbox.md) §6–7). The `gpu-sm-agent` from rounds 1–2 is removed; its job moved into the fork. Re-tested as root in a 0.25-fraction Sysbox pod, next to a running victim pod:

| Finding (earlier round) | Now | Evidence |
|---|---|---|
| 5 / 6a: whole `/run/nvidia-mps` tree in every pod (root control socket, other tenants' sockets, write access to shared dirs) | **Fixed.** Only `/tmp/nvidia-mps` = the pod's own namespace is mounted; `/run/nvidia-mps` and the daemons' directories are absent | test F |
| 5: read-only cross-tenant visibility | **Reduced.** `client list` (PIDs) is empty. `namespace list` via the pod's own socket still shows every namespace's SM % and memory, with opaque names (SHA-256 of container IDs) | test F |
| 6a: mutating MPS control | Still **blocked** (`'NAMESPACE SET' requires root`), still depends on `hostUsers: false` | test F |
| 6b: compute cap set by a self-service annotation | **Fixed by design.** The SM share comes from the scheduler's `gpu-fraction`; `gpu-sm-percent` can only lower it (90 on 0.25 → still 26 SMs) | test E |
| 6c: native-context bypass | Killed by the fork's metricsd within one 0.5 s tick | test C |
| opt out of the cap via `gpu-compute.mode: time-slicing` | Ignored (enforced) | test D |
| GPU memory wrong under Sysbox (6/56 earlier) | **Fixed.** 12/12 exact in churn | test A |
| *New:* stray NVML limits on unrelated pods (GFD, mpsd, system pods) shrank their GPU view; GFD published 30720 MiB, so KAI under-sized every fraction | **Repaired** by the guard's sweep (25 entries reset; label back to 40960). Writer not identified | §5 / §7 of the report |
| *New:* MPS daemon restart | Namespaces come back; running pods stay capped without a restart | test G |

---

## Current Summary

| Area | Status |
|---|---|
| HAMi GPU memory quota | Potential enforcement anomaly observed; needs reproducibility and root-cause investigation |
| Tailscale SSH and HTTP connectivity | Successfully tested through the configured Tailscale path |
| Docker-in-Container | Verified working via standard installation under Sysbox |
| Fail2ban systemd daemon | Configured and confirmed automatically active on boot |
| MPS cross-tenant control (mutate another tenant) | **Blocked** by Sysbox UID remapping (needs `hostUsers: false`) |
| MPS tree exposure (other tenants' sockets, root control socket) | **Fixed** by the fork: only the pod's own namespace is mounted |
| MPS cross-tenant visibility | Reduced to `namespace list` (opaque names, SM %, memory); PIDs no longer visible |
| GPU-fraction compute cap | **Enforced** by the fork: SM share = `gpu-fraction`, no opt-out, bypass killed |
| GPU-fraction memory cap under Sysbox | **Fixed** by the fork's memory guard: 12/12 exact; stray limits on other pods swept |
| Container-to-host isolation (Sysbox) | Holds (namespaced caps, PID/mount isolation); escape primitives not run |
| Network isolation (tenant namespace) | Open by default; **patched** — default-deny NetworkPolicy + DNS carve-out |
| Per-pod PID limit | Missing (node default 57709); set kubelet `--pod-max-pids` |
| CPU/RAM enforcement | Enforced (round 2, §6e) |
