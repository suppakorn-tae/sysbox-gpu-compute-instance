# Security

Threat model: the user is root inside their instance (they have sudo) and
wants more resources, wants to affect or observe other tenants, or wants to
reach the host. All tests ran on the test node `dev03`; nothing that could
reboot or damage the host was run.

## Status

| Area | Status | Notes |
|---|---|---|
| Container → host | ✅ holds | Sysbox user, PID and mount namespaces; full capabilities apply only inside the namespace. Active escape attempts were not run. |
| CPU limit | ✅ enforced | 4 busy threads on a 1-CPU limit used 1.00 core |
| RAM limit | ✅ enforced | 800 MiB on a 512 MiB limit → OOM-killed |
| GPU memory limit | ✅ enforced | exact in 12/12 pods; holds with env vars removed or the MPS dir unmounted |
| GPU compute limit | ✅ enforced | SM share = fraction; opt-out ignored; skipping MPS → process killed |
| Changing GPU limits (own or others') | ✅ blocked | MPS needs host UID 0; requires `hostUsers: false` |
| Seeing other tenants' GPU use | ⚠️ partly | Only own MPS socket is mounted; other tenants' PIDs are hidden. `namespace list` still shows every namespace's SM % and memory (opaque names). |
| Network between tenants | ⚠️ apply policy | Open by default (east-west, node SSH, internet all reachable). [`manifests/netpol-default-deny.yaml`](../manifests/netpol-default-deny.yaml) blocks it; verified. |
| Kubernetes API from an instance | ✅ | Default service account is low-privilege (403 everywhere); the instance manifest disables token mounting |
| SSH brute force | ✅ | fail2ban: 5 failures in 5 min → 10 min ban; root login disabled |
| Process count | ❌ open | No per-pod PID limit (node default ~57k). Set kubelet `--pod-max-pids`. |
| Tampering with in-instance limits (CPU shim, env) | ⚠️ partly | Files are `chattr +i` and covered by a sudoers deny-list, but the deny-list only blocks `tee`; root can still bypass the CPU *reporting* shim. The cgroup CPU/RAM limits themselves cannot be changed. |

## Test details

### GPU (round 3, against the fork)

All as root in a 0.25-fraction instance, with a second instance running next to it:

| Attempt | Result |
|---|---|
| `nvidia-cuda-mps-control namespace set <own or other> --active-thread-percentage=100` | `Insufficient privileges ... requires root` |
| `client terminate <neighbour PID>`, `namespace delete/create` | refused (same) |
| Run CUDA with `CUDA_MPS_PIPE_DIRECTORY=/nonexistent` | killed by metricsd (`native GPU context ... bypassed its MPS namespace`) |
| Annotate `gpu-compute.mode: time-slicing` | ignored |
| Annotate `gpu-sm-percent: 90` on a 0.25 fraction | ignored (26 SMs) |
| Look for other MPS sockets / `/run/nvidia-mps` / daemon dirs | not present |
| Remove GPU env vars, unmount the MPS dir, then allocate | still capped |

Before the fork (upstream gpu-fractioning), the whole `/run/nvidia-mps` was
mounted into every pod, any pod could join another tenant's MPS namespace, and
compute was not capped at all. See [gpu-fractioning.md](gpu-fractioning.md).

### Isolation and limits (round 2)

- PID namespace: 5 visible processes; host processes (e.g. the MPS daemon) not visible.
- `/var/lib/rancher/{rke2,k3s}` inside the instance are Sysbox's empty per-container directories, not host data.
- Seccomp active.
- Network: before the policy, an instance reached another pod's port, cluster DNS, the API server, the node's SSH and the internet. After `netpol-default-deny.yaml`: east-west and internet blocked, DNS works.

### Earlier (HAMi era)

HAMi's memory limit could be bypassed by starting the process with `env -i`
(12 GiB used on a 4 GiB limit). HAMi is no longer used; files are in
[`archive/`](../archive/).

## Open items

1. Set a per-pod PID limit (kubelet `--pod-max-pids`).
2. Apply `netpol-default-deny.yaml` in every tenant namespace, plus allow-rules for intended traffic.
3. Use SSH keys instead of passwords (passwords are set via env vars today).
4. Decide whether `namespace list` visibility is acceptable. If not, give untrusted tenants a whole GPU or a MIG slice.
