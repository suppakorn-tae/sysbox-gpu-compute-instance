# Archive

Kept for reference; not used by the current setup.

| Path | What it was |
|---|---|
| `images/v1-container-ssh/` | First prototype: plain container running `sshd -D`, CPU shim for `sysconf()` only, no systemd |
| `images/v2-sysbox-ssh/` | Sysbox + systemd, thread counts computed at boot; no `sched_getaffinity()` shim, no hardening |
| `manifests/pod-hami.yaml` | Instance manifest for HAMi GPU sharing (`nvidia.com/gpumem`, `nvidia.com/gpucores`) |
| `testing/hami-gpu-memory-quota/` | Stress test that showed HAMi's memory limit could be bypassed with `env -i` |

The current image is in [`../image/`](../image/). Earlier versions of the docs
(Run:ai era, the `gpu-sm-agent` prototype) are in git history.
