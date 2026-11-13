# Architecture

## One instance

```
Kubernetes node
└─ pod  (runtimeClassName: nvidia-sysbox, hostUsers: false)
   │     NVIDIA runtime injects the GPU, then Sysbox runs the container
   │     in its own user namespace (container root = unprivileged host UID)
   └─ systemd (PID 1)
      ├─ sshd ─ user login shell
      │         LD_PRELOAD=libcpuquota.so, OMP/MKL/OpenBLAS thread counts,
      │         CUDA_MPS_PIPE_DIRECTORY=/tmp/nvidia-mps  (this pod's MPS namespace)
      ├─ fail2ban
      └─ (user services, Docker, ...)
```

The image is in [`image/`](../image/): Ubuntu 24.04 on
`nvidia/cuda:13.0.0-devel` with systemd, OpenSSH, sudo, fail2ban, build tools,
Python and common CLI tools. Docker can be installed and run inside (Sysbox
supports nested containers without privileged mode).

At boot, [`entrypoint.sh`](../image/entrypoint.sh):
1. creates the user from `INSTANCE_USER` / `INSTANCE_PASSWORD` (`root` is rejected);
2. configures SSH (password login, no root login) and enables fail2ban;
3. writes the resource settings to `/etc/profile.d/` and `/etc/environment`, so
   SSH and PAM sessions get them (sessions do not inherit the container's env);
4. locks those files (`chattr +i`, sudoers deny-list, `readonly` shell variables);
5. execs systemd.

## How each limit is enforced

### CPU

Kubernetes sets cgroup `cpu.max`, so the kernel caps CPU time. Software still
sees the host's CPU count, so:

- `libcpuquota.so` (LD_PRELOAD) answers `sysconf(_SC_NPROCESSORS_*)` and
  `sched_getaffinity()` with `ceil(quota / period)` from `cpu.max`. This covers
  `nproc`, Python `os.cpu_count()`, Go, Java, OpenMP, MKL and OpenBLAS.
- A `nproc` wrapper covers shells without the preload.
- `OMP_NUM_THREADS`, `MKL_NUM_THREADS` and `OPENBLAS_NUM_THREADS` are set to the same number.

Statically linked binaries bypass the preload; they still only get the cgroup's CPU time.

### RAM

cgroup `memory.max`: exceeding the limit gets the process OOM-killed.

### GPU memory and compute

The pod annotation `gpu-fraction: "0.25"` drives both:

| | Mechanism | 0.25 of an A100-40GB |
|---|---|---|
| Scheduling | KAI places the pod on a GPU with room and records `nvidia.com/container.<c>.gpu-memory.request` | 10Gi |
| Memory | NVIDIA Container Toolkit hook sets an NVML per-cgroup limit; the fork's memory guard keeps it right on the container's whole cgroup tree | 10.0 GiB reported, ~9.9 GiB usable |
| Compute | The fork's fractiond gives the container its own MPS namespace with 25 % active threads, and mounts only that namespace | 26 of 108 SMs |
| Bypass | A process that skips MPS gets a native CUDA context; the fork's metricsd kills it | killed within ~0.5 s |

Details and measurements: [gpu-fractioning.md](gpu-fractioning.md).

### Isolation

Sysbox gives the container a user namespace (root inside maps to an
unprivileged host UID), its own PID namespace and a virtualised `/proc` and
`/sys`. Capabilities inside are full but apply only within the namespace. MPS
refuses configuration changes from any UID other than host root, so a tenant
cannot change its own or anyone else's GPU limits.

Network isolation is per namespace: apply
[`manifests/netpol-default-deny.yaml`](../manifests/netpol-default-deny.yaml)
(no ingress, egress only to DNS), then allow what is needed.

## Node components

| Component | Namespace | Role |
|---|---|---|
| Sysbox (`sysbox-mgr`, `sysbox-fs`) | host systemd | container runtime |
| `nvidia-sysbox` runtime | host | NVIDIA runtime → sysbox-runc |
| KAI-Scheduler | `kai-scheduler` | schedules pods and GPU fractions (`schedulerName: kai-scheduler`) |
| gpu-fractioning operator (fork) | `gpu-fractioning` | runs the two DaemonSets below |
| fractiond + metricsd (DaemonSet) | `gpu-fractioning` | NRI plugin: injects limits, scopes the MPS mount; memory guard, bypass enforcer, metrics |
| mpsd (DaemonSet) | `gpu-fractioning` | NVIDIA MPS daemon; per-pod MPS namespaces |
| NVIDIA GPU Operator | `gpu-operator` | driver, toolkit, device plugin, GPU feature discovery |
