# Setup

One-time setup of a GPU node, then launching instances. Assumes RKE2 with the
NVIDIA GPU Operator (driver r615+, Container Toolkit 1.20.1+, CDI mode) already
running. Nothing here reboots the node; steps 1 and 3 restart RKE2 or GPU
daemons.

## 1. Sysbox and the `nvidia-sysbox` runtime

```bash
bash node-setup/install.sh
```

Installs Sysbox CE 0.7.1 (checksum-verified) and registers two runtimes with
RKE2's containerd through a drop-in file (`config-v3.toml.d/sysbox.toml`), then
restarts `rke2-server`:

- `sysbox-runc`: plain Sysbox (no GPU).
- `nvidia-sysbox`: NVIDIA's runtime in front of Sysbox, so the GPU is injected
  before Sysbox starts the container. Uses its own wrapper
  (`/usr/local/bin/nvidia-sysbox-runtime`) and config
  (`/etc/nvidia-sysbox/config.toml`); the GPU Operator's `nvidia` runtime is
  untouched.

Undo: `bash node-setup/uninstall.sh`.

## 2. Scheduler: upstream KAI

```bash
helm upgrade -i kai-scheduler oci://ghcr.io/kai-scheduler/kai-scheduler/kai-scheduler \
  --version v0.18.3 -n kai-scheduler --create-namespace \
  --set global.gpuSharingMode=NvFractions --set global.nvFractions.set=false
kubectl apply -f node-setup/kai-queues.yaml        # queues default-parent -> tenants
kubectl create ns ci-tenants
```

`nvFractions.set=false` stops KAI from installing upstream gpu-fractioning; the
fork is installed next.

## 3. GPU fractioning: the fork

Needs Docker with the buildx plugin on the node.

```bash
git clone -b sysbox-sm-limit https://github.com/suppakorn-tae/kai-gpu-fractioning
cd kai-gpu-fractioning
hack/fork/build-local.sh v0.1.6-sm.3            # builds 4 images, imports into containerd
helm upgrade -i gpu-fractioning operator/charts -n gpu-fractioning --create-namespace \
  -f <this repo>/node-setup/gpu-fractioning-values.yaml
kubectl wait gpufractioningconfig/default --for=condition=Ready --timeout=180s
```

The values file turns on `smLimit` (enforced) and `memoryGuard`; see
[gpu-fractioning.md](gpu-fractioning.md).

## 4. Instance image

```bash
bash image/build-image.sh                        # sysbox-ssh-kube-cpu-aware:24.04
```

Builds and imports into containerd (no registry). For several nodes, push it to
a registry instead and drop `imagePullPolicy: IfNotPresent`.

## 5. Launch an instance

Edit [`manifests/compute-instance.yaml`](../manifests/compute-instance.yaml):
name, `INSTANCE_USER`, `INSTANCE_PASSWORD`, `gpu-fraction`, CPU and memory.

```bash
kubectl apply -f manifests/compute-instance.yaml
kubectl apply -n ci-tenants -f manifests/netpol-default-deny.yaml   # once per namespace
kubectl -n ci-tenants get pod ci-inst01 -o wide
```

What the manifest must keep:

```yaml
metadata:
  labels: {kai.scheduler/queue: tenants}
  annotations: {gpu-fraction: "0.25"}     # optional: gpu-sm-percent: "20" (only lowers SMs)
spec:
  schedulerName: kai-scheduler
  runtimeClassName: nvidia-sysbox
  hostUsers: false                        # required for isolation
  automountServiceAccountToken: false
```

## 6. Connect

```bash
ssh ubuntu@<pod IP>                        # from the node or the cluster network
kubectl -n ci-tenants exec -it ci-inst01 -- su - ubuntu     # without SSH
```

Check the GPU slice from inside (the CUDA toolkit is in the image):

```bash
kubectl cp testing/gpu-fractioning/gpucheck.cu ci-tenants/ci-inst01:/home/ubuntu/
# inside the instance:
nvcc -O2 -o gpucheck gpucheck.cu && ./gpucheck 5
# GPUCHECK SMs=26 total_GiB=10.00 free_GiB=9.88 alloc_GiB=9.88 ...
```

## Troubleshooting

| Symptom | Check |
|---|---|
| Pod stuck `ContainerCreating` with an MPS namespace error | `kubectl -n gpu-fractioning logs ds/gpu-fractioning-mpsd \| grep -i namespace`; fractiond fails creation until mpsd has made the namespace, and kubelet retries |
| Fractions sized from a too-small GPU | `kubectl get node -o jsonpath='{..labels.nvidia\.com/gpu\.memory}'` should be the full card; the memory guard repairs stray limits within ~10 s |
| GPU process in an instance gets killed | it bypassed MPS (`CUDA_MPS_PIPE_DIRECTORY` changed); `kubectl -n gpu-fractioning logs ds/gpu-fractioning-fractiond -c metricsd` |
| Inspect GPU memory limits | `sudo python3 -I <fork>/hack/fork/nvml_scan_strays.py` |
| Inspect MPS namespaces | `CUDA_MPS_PIPE_DIRECTORY=/run/nvidia-mps sudo -E nvidia-cuda-mps-control -p 3 namespace list` |
