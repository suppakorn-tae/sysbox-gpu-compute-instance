# Compute Instance

VM-like, SSH-accessible Kubernetes pods on Sysbox, with CPU-count awareness and fractional NVIDIA GPUs.

| Document | What's in it |
|---|---|
| [docs/main.md](docs/main.md) | Architecture, image evolution, CPU-quota shim, security hardening, pod manifest |
| [docs/gpu-fractioning-sysbox.md](docs/gpu-fractioning-sysbox.md) | **GPU fractioning under Sysbox**: Run:ai/KAI `NvFractions`, measured memory and compute limits, the `gpu-sm-agent` SM-cap prototype, known issues, versions |
| [docs/security-testing.md](docs/security-testing.md) | Security test notes |

## Layout

```
docs/                     design docs (+ pdf/ exports)
images/
  container-ssh/          v1: standalone sshd
  sysbox-ssh/             v2: sysbox + systemd
  sysbox-ssh-kube-cpu-aware/  v3: final instance image
  gpu-sm-agent/           node agent: per-pod MPS SM caps (DaemonSet)
manifests/
  pod.yaml                CPU / HAMi-era example
  pod-gpu-fraction-sm.yaml    Sysbox + KAI fraction + SM cap example
node-setup/               Sysbox install + nvidia-sysbox runtime for RKE2
testing/
  gpu-memory-quota/       HAMi-era GPU memory stress test
  gpu-fractioning/        probes and churn scripts used in the GPU fractioning report
```

## Tested stack (2026-11-13)

Ubuntu 24.04.5 / kernel 6.8.0-147 · RKE2 v1.36.5+rke2r1 · containerd 2.3.4 · Sysbox CE 0.7.1 ·
NVIDIA driver 615.71.09 (CUDA 13.4) · GPU Operator v26.7.1 · Container Toolkit 1.20.1 ·
Run:ai 3.0.20 · KAI scheduler v0.18.3 · KAI gpu-fractioning v0.1.6 · A100-SXM4-40GB.
Full table in [docs/gpu-fractioning-sysbox.md §2](docs/gpu-fractioning-sysbox.md#2-environment-and-versions).
