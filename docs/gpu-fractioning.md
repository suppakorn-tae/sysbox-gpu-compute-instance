# GPU fractioning

Goal: one GPU shared by several instances, each with a hard memory limit and a
hard compute limit set by its `gpu-fraction`, which root inside the instance
cannot raise.

## Problems with upstream KAI gpu-fractioning (v0.1.6) under Sysbox

| # | Problem | Effect |
|---|---|---|
| 1 | **No compute limit.** NvFractions caps memory only. Time-slicing splits the GPU evenly whatever the fraction. | 0.25 and 0.75 pods both got ~56 TFLOPS; a pod alone always gets all 108 SMs |
| 2 | **Whole MPS directory in every pod.** | Any tenant could reach the node's MPS control socket and join or inspect other tenants' MPS namespaces |
| 3 | **Wrong GPU memory.** Sysbox runs workloads in a child cgroup (`init.scope`); NVML uses the nearest cgroup that has a limit, and that child sometimes carried another pod's value. | 6 of 12 pods wrong in a create/delete churn; some got *more* than they paid for (4 → 30 GiB) |
| 4 | **Stray limits on unrelated pods.** Fractional pods' limits also showed up on system pods' cgroups. NVML reports memory capped by the caller's cgroup. | GPU feature discovery published a 30 GiB card (40 GB physical), so KAI sized every fraction ¾ too small |

The cause of #4 was not found (the toolkit hook always got the right
container). The fork detects and repairs it.

## The fork

[suppakorn-tae/kai-gpu-fractioning](https://github.com/suppakorn-tae/kai-gpu-fractioning),
branch `sysbox-sm-limit`, based on upstream v0.1.6 (the version KAI v0.18.3
pins). Both features are off by default; this repo's
[Helm values](../node-setup/gpu-fractioning-values.yaml) turn them on.

| Setting | What it does |
|---|---|
| `smLimit.enabled` | Each fractional container gets its own MPS namespace with SM share = `gpu-fraction`. Only that namespace is mounted into the pod (`/tmp/nvidia-mps`). GPU work that skips MPS is killed. Fixes #1, #2. |
| `smLimit.enforce` | The pod's `gpu-compute.mode` annotation is ignored, so nobody can opt out. |
| `memoryGuard.enabled` | Keeps each container's GPU memory limit correct on its whole cgroup tree, and every 10 s removes stray limits from other pods. Fixes #3, #4. |

Optional pod annotation `gpu-sm-percent: "20"` lowers the SM share below the
fraction. It can never raise it.

## Results (dev03, one A100-SXM4-40GB)

| Test | Result |
|---|---|
| 12 pods in a row, alternating 0.1 / 0.75 | **12/12 exact**: 4.0 GiB + 10 SMs, 30.0 GiB + 80 SMs |
| 0.25 and 0.75 running at the same time | 26 vs 80 SMs, 30.2 vs 91.6 TFLOPS (1 : 3) |
| Pod asks for `gpu-compute.mode: time-slicing` | ignored, still 26 SMs |
| `gpu-sm-percent: 20` on 0.5 / `90` on 0.25 | 20 SMs / still 26 SMs |
| Root in the pod skips MPS | process killed; the neighbour is unaffected |
| What a tenant sees | only its own MPS socket; no node MPS directory; no other tenants' PIDs |
| MPS daemon restarted under a running pod | namespaces come back; the pod stays capped |
| Real instance image, logged in over SSH/PAM | 26 SMs, 10.00 GiB, 9.88 GiB allocatable |
| Stray-limit repair | 25 stray entries removed; GPU size label back to 40960 MiB |

Memory granularity: `gpu-fraction` is rounded to 2 decimals (~409 MiB steps on
40 GiB); `gpu-memory` takes whole MiB. The CUDA context uses ~0.1–0.5 GiB of
the slice.

## Known limits

- A tenant can list all MPS namespaces on the GPU (opaque names, with their SM % and memory). MPS answers that on any socket.
- A process that skips MPS runs for up to ~0.5 s before it is killed.
- The source of stray limits (#4) is unknown; they are repaired within ~10 s.
- Tested with one GPU per node; multi-GPU and MIG are untested.

## Reproduce

```bash
cd testing/gpu-fractioning
kubectl -n ci-tenants create configmap frac-probe --from-file=frac-probe.py=probe.py
bash mk-kai-pod.sh t1 nvidia-sysbox 'gpu-fraction: "0.25"' '[{name: DWELL, value: "5"}]' \
  '["python","/probe/frac-probe.py"]' | kubectl apply -f -
bash wait-kai.sh t1                          # RESULT {"SMs": 26, "total_GiB": 10.0, ...}
RC=nvidia-sysbox bash churn-kai.sh a 12 '["python","/probe/frac-probe.py"]'   # memory churn
```

`probe.py` reports SMs, reported and allocatable memory, and matmul TFLOPS.
`gpucheck.cu` does the same without PyTorch.
