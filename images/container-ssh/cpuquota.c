#define _GNU_SOURCE
#include <dlfcn.h>
#include <unistd.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

long sysconf(int name) {
    static long (*real_sysconf)(int);
    if (!real_sysconf)
        real_sysconf = dlsym(RTLD_NEXT, "sysconf");

    if (name == _SC_NPROCESSORS_ONLN ||
        name == _SC_NPROCESSORS_CONF) {
        FILE *f = fopen("/sys/fs/cgroup/cpu.max", "r");
        if (f) {
            char quota[64], period[64];
            if (fscanf(f, "%63s %63s", quota, period) == 2) {
                fclose(f);
                if (strcmp(quota, "max") != 0) {
                    long q = atol(quota), p = atol(period);
                    if (q > 0 && p > 0)
                        return (q + p - 1) / p;
                }
            } else {
                fclose(f);
            }
        }
    }

    return real_sysconf(name);
}
