# sysbox-ssh-kube-cpu-aware

A variant of the `sysbox-ssh` image that makes in-container CPU-count
reporting follow the Kubernetes CPU limit.

## Problem

When Kubernetes sets `resources.limits.cpu: "2"`, the kernel enforces
the CPU quota via cgroup v2 (`cpu.max`), but standard APIs still report
the full host CPU count.  This causes `os.cpu_count()` (Python),
`runtime.NumCPU()` (Go), `nproc`, and similar queries to return the
host value (e.g. 128) instead of 2.

## How it works

An `LD_PRELOAD` shared library (`libcpuquota.so`) intercepts two
system interfaces:

| Interface              | Used by                                    |
|------------------------|--------------------------------------------|
| `sysconf()`            | `nproc`, glibc, OpenMP, MKL, OpenBLAS      |
| `sched_getaffinity()`  | Python `os.cpu_count()`, Go, Java, …        |

Both overrides read `/sys/fs/cgroup/cpu.max` at call time, compute
`ceil(quota / period)`, and return a result capped to that number.
If the cgroup quota is unlimited (`max`) or the file is absent, the
real system call result passes through unchanged.

A wrapper `nproc` script at `/usr/local/bin/nproc` provides the same
logic for shell scripts.

No CPU count is hardcoded.  The same image works with any
`resources.limits.cpu` value.

## Build

```bash
cd sysbox-ssh-kube-cpu-aware/
docker build --no-cache -t sysbox-ssh-kube-cpu-aware:24.04 .
```

Or use `build-image.sh` to build and import into the local containerd:

```bash
bash build-image.sh
```

## Changes from `sysbox-ssh/`

| File            | Change                                                       |
|-----------------|--------------------------------------------------------------|
| `cpuquota.c`    | Added `sched_getaffinity()` override alongside `sysconf()`   |
| `entrypoint.sh` | Added `LD_PRELOAD` to `/etc/environment` for PAM sessions    |
| `Dockerfile`    | Identical structure; no new dependencies                     |
| `nproc`         | Unchanged                                                    |
| `build-image.sh`| Image tag updated to `sysbox-ssh-kube-cpu-aware:24.04`       |
