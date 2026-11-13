/*
 * libcpuquota.so — LD_PRELOAD shim that makes CPU-count queries
 * respect the Kubernetes / cgroup v2 CPU quota.
 *
 * Intercepts:
 *   sysconf(_SC_NPROCESSORS_ONLN)  — used by nproc(1), glibc, OpenMP, …
 *   sysconf(_SC_NPROCESSORS_CONF)
 *   sched_getaffinity()            — used by Python os.cpu_count(),
 *                                    Go runtime.NumCPU(), Java, …
 *
 * CPU count is derived from /sys/fs/cgroup/cpu.max (cgroup v2):
 *   quota / period, rounded up.
 *
 * If the cgroup file is absent or set to "max" (unlimited), the real
 * system call result is returned unchanged.
 */

#define _GNU_SOURCE
#include <dlfcn.h>
#include <errno.h>
#include <sched.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

/* ------------------------------------------------------------------ */
/* Helper: read the effective CPU count from cgroup v2 cpu.max         */
/* Returns 0 when the quota is unlimited or unreadable.                */
/* ------------------------------------------------------------------ */
static long cgroup_cpu_count(void)
{
    FILE *f = fopen("/sys/fs/cgroup/cpu.max", "r");
    if (!f)
        return 0;

    char quota_s[64], period_s[64];
    if (fscanf(f, "%63s %63s", quota_s, period_s) != 2) {
        fclose(f);
        return 0;
    }
    fclose(f);

    if (strcmp(quota_s, "max") == 0)
        return 0;                       /* unlimited */

    long q = atol(quota_s);
    long p = atol(period_s);
    if (q <= 0 || p <= 0)
        return 0;

    return (q + p - 1) / p;            /* ceil(quota / period) */
}

/* ------------------------------------------------------------------ */
/* sysconf() override                                                  */
/* ------------------------------------------------------------------ */
long sysconf(int name)
{
    static long (*real_sysconf)(int);
    if (!real_sysconf)
        real_sysconf = dlsym(RTLD_NEXT, "sysconf");

    if (name == _SC_NPROCESSORS_ONLN || name == _SC_NPROCESSORS_CONF) {
        long n = cgroup_cpu_count();
        if (n > 0)
            return n;
    }

    return real_sysconf(name);
}

/* ------------------------------------------------------------------ */
/* sched_getaffinity() override                                        */
/*                                                                     */
/* Python's os.cpu_count() calls sched_getaffinity() and counts the    */
/* bits.  We call the real syscall first, then clear all but the first  */
/* N bits (where N = cgroup quota) so that the caller sees only N      */
/* CPUs.                                                               */
/* ------------------------------------------------------------------ */
int sched_getaffinity(pid_t pid, size_t cpusetsize, cpu_set_t *mask)
{
    static int (*real_sched_getaffinity)(pid_t, size_t, cpu_set_t *);
    if (!real_sched_getaffinity)
        real_sched_getaffinity = dlsym(RTLD_NEXT, "sched_getaffinity");

    int ret = real_sched_getaffinity(pid, cpusetsize, mask);
    if (ret != 0)
        return ret;

    long limit = cgroup_cpu_count();
    if (limit <= 0)
        return 0;                       /* no quota — return real mask */

    /*
     * Walk the returned mask and keep at most `limit` set bits.
     * This preserves the actual CPU IDs that the kernel assigned
     * while trimming the visible count down to the quota.
     */
    int max_cpu = (int)(cpusetsize * 8);
    long kept = 0;
    for (int i = 0; i < max_cpu; i++) {
        if (CPU_ISSET_S(i, cpusetsize, mask)) {
            if (kept >= limit)
                CPU_CLR_S(i, cpusetsize, mask);
            else
                kept++;
        }
    }

    return 0;
}
