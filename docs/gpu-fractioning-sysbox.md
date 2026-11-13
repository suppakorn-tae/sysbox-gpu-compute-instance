# GPU Fractioning for Sysbox Compute Instances

> Test report and design, based on work on node `dev03`, 2026-11-13/14.
> Status: **working prototype**, deployed on dev03 and measured. Single-GPU node only.

---

## 1. Summary

Goal: give each Sysbox Compute Instance a **fraction of one GPU**, with a **memory** limit and a **compute** limit that root inside the instance cannot raise.

| Question | Answer |
|---|---|
| Stack | Upstream **KAI-Scheduler v0.18.3** (Run:ai removed) + a **private fork of KAI's gpu-fractioning** ([suppakorn-tae/gpu-fractioning](https://github.com/suppakorn-tae/gpu-fractioning), branch `sysbox-sm-limit`, based on v0.1.6). |
| Memory limit | ✅ Exact: `gpu-fraction` 0.25 → 10.0 GiB reported, 9.9 GiB usable. 12/12 pods exact in churn (upstream under Sysbox: up to 6/12 wrong, some over-allocated). |
| Compute limit | ✅ Same annotation: 0.25 → 26 of 108 SMs. 0.25 vs 0.75 at the same time: 30.2 vs 91.6 TFLOPS (1 : 3). |
| Can a tenant opt out or raise it? | No. `gpu-compute.mode` is ignored (enforced); `gpu-sm-percent` can only lower the share. |
| Can root inside the instance get around it? | Skipping MPS → process killed within ~0.5 s. Changing MPS settings → refused (needs host UID 0; Sysbox maps container root elsewhere). |
| What can a tenant see? | Only its own MPS namespace socket. Not the node's MPS control socket, other tenants' sockets, or the daemons' directories. It can still *list* the shared server's namespaces (opaque names, SM %, memory). |
| Works in the real instance image (systemd + SSH)? | ✅ A login session gets the MPS pipe and memory limit; a CUDA program compiled in the image sees 26 SMs / 10 GiB. |

Pod spec needed per instance (full example: [`manifests/pod-gpu-fraction-sm.yaml`](../manifests/pod-gpu-fraction-sm.yaml)):

```yaml
metadata:
  labels: {kai.scheduler/queue: tenants}
  annotations: {gpu-fraction: "0.25"}       # optional: gpu-sm-percent: "20"
spec:
  schedulerName: kai-scheduler
  runtimeClassName: nvidia-sysbox
  hostUsers: false
```

---

## 2. Environment and versions

| Component | Version |
|---|---|
| OS / kernel | Ubuntu 24.04.5 LTS / 6.8.0-147-generic |
| Kubernetes | RKE2 v1.36.5+rke2r1 |
| containerd | 2.3.4-k3s1 (NRI enabled, config v3) |
| GPU | 1× NVIDIA A100-SXM4-40GB (108 SMs, 40960 MiB), MIG disabled |
| NVIDIA driver | 615.71.09 (CUDA 13.4), MPS control protocol 3 |
| NVIDIA GPU Operator | v26.7.1 (Container Toolkit 1.20.1, CDI mode; device plugin / GFD v0.20.1) |
| Sysbox CE | 0.7.1 (`nvidia-sysbox` runtime, see [`node-setup/`](../node-setup/)) |
| KAI-Scheduler | v0.18.3, Helm `kai-scheduler` in ns `kai-scheduler`, `global.gpuSharingMode=NvFractions`, `global.nvFractions.set=false` |
| gpu-fractioning | fork `v0.1.6-sm.3` (base upstream v0.1.6), Helm release `gpu-fractioning` in ns `gpu-fractioning`, values [`node-setup/gpu-fractioning-values.yaml`](../node-setup/gpu-fractioning-values.yaml) |
| Go toolchain (builds) | golang:1.27 container; Docker 29.1.3 + buildx v0.38.1 (user plugin) |
| Test images | `nvcr.io/nvidia/pytorch:26.09-py3`; `sysbox-ssh-kube-cpu-aware:24.04` (base `nvidia/cuda:13.0.0-devel-ubuntu24.04`) |

Run:ai 3.0.20 was installed before. Its cluster components were removed on 2026-11-13 (backup: `/home/researcher/runai-backup-20261113-2313` on dev03). The `runai-backend` control plane is still installed but unused.

---

## 3. How upstream KAI GPU sharing works

`configs.kai.scheduler` → `global.gpuSharingMode`:

| Mode | Memory | Compute | Mechanism |
|---|---|---|---|
| `NonMemoryEnforced` | scheduling only | – | trust-based packing |
| **`NvFractions`** (used) | ✅ | ❌ upstream | gpu-fractioning: `fractiond` NRI plugin + `mpsd` (MPS daemon) + `metricsd` |
| `HamiCore` | ✅ | ✅ (soft) | HAMi-core CUDA interception inside the container |

Upstream `NvFractions` in detail:
- **Admission** turns `gpu-fraction` / `gpu-memory` into `nvidia.com/container.<c>.gpu-memory.request`, sizing fractions from the node label `nvidia.com/gpu.memory`.
- **fractiond** injects `NVIDIA_GPU_MEMORY_LIMIT/REQUEST`, `NVIDIA_VISIBLE_DEVICES=<CDI device>` and `CUDA_MPS_PIPE_DIRECTORY`. In the default mode it bind-mounts the **whole** `/run/nvidia-mps`.
- **The memory cap** is set by the Container Toolkit's `apply-cuda-memory-limits` CDI hook, which puts an NVML per-cgroup limit on the container's cgroup.
- **Compute:** `time-slicing` is driver round-robin, an even split whatever the fraction. `sm-sharing` puts everyone in one 100 % MPS namespace. Neither caps compute.

Measured upstream (fp32 matmul, one pod alone ~124 TFLOPS):

| Scenario | Pod 1 | Pod 2 |
|---|---|---|
| any fraction alone | ~124 (108 SMs) | – |
| 0.25 vs 0.75, time-slicing | 56.2 | 56.3 |
| 0.25 vs 0.75, sm-sharing | 58.6 | 58.6 |

---

## 4. Sysbox + GPU

| Attempt | Result |
|---|---|
| `runtimeClassName: sysbox-runc` + fraction | ❌ no GPU: fractional pods get it only through `nvidia-container-runtime` reading `NVIDIA_VISIBLE_DEVICES=<CDI name>` |
| **`nvidia-sysbox`**: `nvidia-container-runtime` (CDI mode) with `runtimes = ["sysbox-runc"]` | ✅ |

`nvidia-sysbox` is its own wrapper (`/usr/local/bin/nvidia-sysbox-runtime`) and config (`/etc/nvidia-sysbox/config.toml`), so the GPU operator's `nvidia` runtime is untouched. With `hostUsers: false`, container root maps to a random host UID range.

---

## 5. Problems found with upstream under Sysbox

1. **No compute limit** (§3).
2. **Whole MPS tree in every pod.** Any tenant could reach the node's root control socket and join or inspect other tenants' MPS namespaces. Mutating commands need real UID 0, which Sysbox prevents; reading and joining did not.
3. **Wrong GPU memory.**
   - NVML resolves a process's limit from the nearest cgroup that has an entry. Sysbox runs workloads in `<scope>/init.scope`, and that child was seen carrying other pods' values: **6 of 12 pods wrong** in a create/delete churn, some over-allocated (4 GiB asked, 30 GiB given).
4. **Stray limits on unrelated pods.**
   - Entries with fractional pods' values were found on the cgroups of system pods: GPU feature discovery, mpsd, and 25 cgroups in total.
   - NVML caps the memory it *reports* by the caller's cgroup. So GFD published `nvidia.com/gpu.memory=30720` on a 40 GB card, and KAI sized every fraction from it (0.25 → 7.5 GiB).
   - The writer was not identified. The toolkit hook received the correct PID in all 11 calls traced with a logging wrapper, and no new strays appeared in a 10-pod churn.

---

## 6. The fork

Both features default **off**; with them off the fork behaves like upstream v0.1.6. Design and per-component detail: `docs/fork/DESIGN.md` in the fork.

| Setting | Component | What it does |
|---|---|---|
| `smLimit.enabled` | fractiond | New default compute mode `sm-limit`. Writes a namespace request, waits ≤1.5 s for mpsd, then mounts **only** `<pipe>/shared/<ns>` at `/tmp/nvidia-mps`. Fails the creation if the namespace isn't ready (kubelet retries) rather than start uncapped. |
| | mpsd | One MPS namespace per container: active-thread % = ceil(`gpu-fraction` × 100), pinned memory = allotment. Recreated after a daemon restart. Talks to the daemon only on change or every 10 s. |
| | metricsd | Kills native (non-MPS) CUDA processes in sm-limit containers. |
| `smLimit.enforce` | fractiond | Ignores `gpu-compute.mode`: no opting out. |
| `memoryGuard.enabled` | metricsd | Every 0.5 s re-asserts each fractional container's NVML limit on its whole cgroup subtree. Every 10 s resets stray entries on other kubepods cgroups older than 30 s. |

- Namespace names are `fc` + SHA-256 of the container ID: opaque, but deterministic for fractiond, its audit and mpsd.
- `gpu-sm-percent` is pod-level because KAI's admission rejects unknown keys under `nvidia.com/container.`.

Instance image change: [`images/sysbox-ssh-kube-cpu-aware/entrypoint.sh`](../images/sysbox-ssh-kube-cpu-aware/entrypoint.sh) carries `CUDA_MPS_PIPE_DIRECTORY`, `NVIDIA_GPU_MEMORY_LIMIT/REQUEST`, `NVIDIA_VISIBLE_DEVICES` and `NVIDIA_DRIVER_CAPABILITIES` into SSH/PAM sessions. The login banner shows the GPU memory limit.

---

## 7. Results (fork v0.1.6-sm.3 on dev03)

| Test | Result |
|---|---|
| A. 12 Sysbox pods, alternating 0.1 / 0.75 | **12/12 exact**: 4.0 GiB reported / 3.88 usable / 10 SMs; 30.0 / 29.69 / 80 SMs |
| B. 0.25 and 0.75 at the same time | 26 vs 80 SMs; 30.2 vs 91.6 TFLOPS |
| C. root in the pod skips MPS | process killed by metricsd; neighbour unaffected |
| D. pod sets `gpu-compute.mode: time-slicing` | ignored: 26 SMs |
| E. `gpu-sm-percent: 20` on 0.5 / `90` on 0.25 | 20 SMs, 20 GiB / still 26 SMs |
| F. tenant view | only `/tmp/nvidia-mps/control`; no `/run/nvidia-mps`, request dir or map dir; `client list` empty; `namespace set` refused (UID) |
| G. MPS daemon restart with a capped pod running | namespace recreated with the same name; the pod's mount sees the new socket; new GPU work still 26 SMs / 10 GiB |
| H. real instance image, login as `ubuntu` | banner `GPU memory : 10240 MiB`; `gpucheck` (nvcc-built) sees 26 SMs, 10.00 GiB, allocates 9.88 GiB |
| Stray sweep | 25 entries reset; `nvidia.com/gpu.memory` back to 40960 within one GFD relabel |
| mpsd log volume | ~2,400 → ~70 lines/min |

Memory granularity (unchanged from upstream): `gpu-fraction` is rounded to 2 decimals (~409 MiB steps on 40 GiB); `gpu-memory` is integer MiB. About 0.12–0.45 GiB of a slice goes to the CUDA context.

---

## 8. Known limits

- `namespace list` through a tenant's own socket still shows every namespace's SM % and memory. MPS answers it on any socket. Names are opaque.
- A bypassing process runs for up to ~0.5 s before it is killed. A tenant retrying in a loop gets short bursts.
- The stray-limit writer is unknown. The sweep repairs entries within 10 s, but a pod created while a stray sits on its future parent could see a wrong value for that window.
- Tested on one GPU per node only. MIG and multi-GPU are untested.
- Per-pod PID limit is still unset (see [security-testing.md](security-testing.md) §6e).

---

## 9. Reproduce

```bash
# node: Sysbox + nvidia-sysbox runtime (restarts rke2-server, no reboot)
bash node-setup/install.sh

# scheduler
helm upgrade -i kai-scheduler oci://ghcr.io/kai-scheduler/kai-scheduler/kai-scheduler --version v0.18.3 \
  -n kai-scheduler --create-namespace \
  --set global.gpuSharingMode=NvFractions --set global.nvFractions.set=false
kubectl apply -f node-setup/kai-queues.yaml

# fork (build + import on the node, then install)
git clone -b sysbox-sm-limit https://github.com/suppakorn-tae/gpu-fractioning && cd gpu-fractioning
hack/fork/build-local.sh v0.1.6-sm.3
helm upgrade -i gpu-fractioning operator/charts -n gpu-fractioning --create-namespace \
  -f ../compute-instance/node-setup/gpu-fractioning-values.yaml

# a probe
cd ../compute-instance/testing/gpu-fractioning
kubectl create ns ci-tenants
kubectl -n ci-tenants create configmap frac-probe --from-file=frac-probe.py=probe.py
bash mk-kai-pod.sh t1 nvidia-sysbox 'gpu-fraction: "0.25"' '[{name: DWELL, value: "5"}]' '["python","/probe/frac-probe.py"]' | kubectl apply -f -
bash wait-kai.sh t1     # RESULT {"SMs": 26, "total_GiB": 10.0, ...}

# churn (memory correctness)
RC=nvidia-sysbox bash churn-kai.sh a 12 '["python","/probe/frac-probe.py"]'
```

Inspecting: `sudo python3 -I <fork>/hack/fork/nvml_scan_strays.py` lists cgroups with their own NVML limit. MPS state: `CUDA_MPS_PIPE_DIRECTORY=/run/nvidia-mps sudo -E nvidia-cuda-mps-control -p 3 namespace list`.
