# sysbox-gpu-compute-instance

VM-like compute instances on Kubernetes: each instance is a pod you SSH into,
with systemd and sudo (Docker can be installed inside), isolated by [Sysbox](https://github.com/nestybox/sysbox),
and a **fraction of a GPU** whose memory *and* compute are capped.

```
ssh ubuntu@<instance>
┌──────────────────────────────────────────────┐
│  Resource Limits (enforced by Kubernetes)    │
├──────────────────────────────────────────────┤
│  CPU cores : 2                               │
│  OMP threads : 2                             │
│  GPU memory : 10240 MiB                      │
└──────────────────────────────────────────────┘
```

## How it works

| Resource | Limit comes from | Enforced by |
|---|---|---|
| CPU | `resources.limits.cpu` | cgroup `cpu.max`; `libcpuquota.so` makes `nproc`, `os.cpu_count()` etc. report the limit |
| RAM | `resources.limits.memory` | cgroup `memory.max` |
| GPU memory | `gpu-fraction` annotation | NVML per-cgroup limit (0.25 → 10 GiB on a 40 GB A100) |
| GPU compute | the same `gpu-fraction` | per-pod MPS namespace (0.25 → 26 of 108 SMs) |
| Isolation | `runtimeClassName: nvidia-sysbox`, `hostUsers: false` | Sysbox user namespaces |

GPU fractions are scheduled by upstream [KAI-Scheduler](https://github.com/kai-scheduler/KAI-Scheduler)
and enforced by a fork of its gpu-fractioning component:
[suppakorn-tae/kai-gpu-fractioning](https://github.com/suppakorn-tae/kai-gpu-fractioning) (branch `sysbox-sm-limit`).
Why the fork is needed: [docs/gpu-fractioning.md](docs/gpu-fractioning.md).

## Quick start

```bash
kubectl apply -f manifests/compute-instance.yaml     # edit name / password / fraction first
kubectl -n ci-tenants get pod ci-inst01 -o wide      # wait for Running
ssh ubuntu@<pod IP>
```

First-time node setup (Sysbox, scheduler, fork, image): [docs/setup.md](docs/setup.md).

## Docs

| | |
|---|---|
| [docs/setup.md](docs/setup.md) | Install everything on a node, launch and connect to an instance |
| [docs/architecture.md](docs/architecture.md) | What is inside an instance and how each limit is enforced |
| [docs/gpu-fractioning.md](docs/gpu-fractioning.md) | GPU sharing: problems with upstream under Sysbox, what the fork changes, measured results |
| [docs/security.md](docs/security.md) | Security posture, test results, open items |

## Layout

```
image/        the instance image (Dockerfile, entrypoint, CPU-quota shim, fail2ban jail)
manifests/    compute-instance.yaml, netpol-default-deny.yaml
node-setup/   Sysbox + nvidia-sysbox runtime, KAI queues, Helm values for the fork
testing/      GPU probes and churn tests used in docs/gpu-fractioning.md
archive/      earlier image versions and HAMi-era files, kept for reference
```

## Tested on

Ubuntu 24.04.5 (kernel 6.8.0-147) · RKE2 v1.36.5 · containerd 2.3.4 · Sysbox CE 0.7.1 ·
NVIDIA driver 615.71.09 (CUDA 13.4) · GPU Operator v26.7.1 · KAI-Scheduler v0.18.3 ·
gpu-fractioning fork v0.1.6-sm.3 · 1× A100-SXM4-40GB. Single node, single GPU.
