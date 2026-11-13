#!/usr/bin/env bash
set -euo pipefail

SSH_USER="${INSTANCE_USER:-}"
SSH_PASSWORD="${INSTANCE_PASSWORD:-}"

if [[ -z "$SSH_USER" ]]; then
    echo "INSTANCE_USER is required" >&2
    exit 1
fi

if [[ -z "$SSH_PASSWORD" ]]; then
    echo "INSTANCE_PASSWORD is required" >&2
    exit 1
fi

if [[ ! "$SSH_USER" =~ ^[a-z_][a-z0-9_-]*[$]?$ ]]; then
    echo "Invalid SSH_USER" >&2
    exit 1
fi

if [[ "$SSH_USER" == "root" ]]; then
    echo "root cannot be used as SSH_USER" >&2
    exit 1
fi

if ! id "$SSH_USER" >/dev/null 2>&1; then
    useradd --create-home --shell /bin/bash "$SSH_USER"
fi

printf '%s:%s\n' "$SSH_USER" "$SSH_PASSWORD" | chpasswd

usermod -aG sudo "$SSH_USER"

# Grant sudo but deny dangerous operations that could bypass resource limits:
#  - Writing to /sys/fs/cgroup (CPU quota bypass)
#  - Modifying /usr/local/lib/libcpuquota.so (LD_PRELOAD shim)
#  - Editing /etc/profile.d/ scripts (env var enforcement)
#  - Modifying /etc/environment (PAM env enforcement)
#  - Using tee/dd/cp to overwrite protected files
cat > "/etc/sudoers.d/$SSH_USER" <<SUDOEOF
# Deny operations that could bypass CPU/GPU resource limits
Cmnd_Alias DENY_RESOURCE_BYPASS = /usr/bin/tee /sys/fs/cgroup/*, \
    /usr/bin/tee /etc/profile.d/cpuquota.sh, \
    /usr/bin/tee /etc/profile.d/compute-env.sh, \
    /usr/bin/tee /etc/profile.d/hami.sh, \
    /usr/bin/tee /etc/profile.d/resource-limits.sh, \
    /usr/bin/tee /etc/environment, \
    /usr/bin/tee /etc/fail2ban/jail.local

$SSH_USER ALL=(ALL) NOPASSWD: ALL, !DENY_RESOURCE_BYPASS
SUDOEOF
chmod 0440 "/etc/sudoers.d/$SSH_USER"

# Protect critical resource-enforcement files from modification
chattr +i /usr/local/lib/libcpuquota.so 2>/dev/null || true
chattr +i /usr/local/bin/nproc 2>/dev/null || true
chattr +i /etc/fail2ban/jail.local 2>/dev/null || true

mkdir -p /run/sshd

# Permit password authentication for this container.
sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication yes/' \
    /etc/ssh/sshd_config

# Do not allow SSH root login.
sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin no/' \
    /etc/ssh/sshd_config

systemctl enable ssh.service

# Enable fail2ban for SSH brute-force protection
systemctl enable fail2ban.service

# CPU quota enforcement via LD_PRELOAD
cat > /etc/profile.d/cpuquota.sh <<'EOF'
export LD_PRELOAD=/usr/local/lib/libcpuquota.so
readonly LD_PRELOAD
EOF

chmod 0644 /etc/profile.d/cpuquota.sh

# Compute thread limits (OMP, MKL, OpenBLAS)
if [[ -z "${OMP_NUM_THREADS:-}" || -z "${MKL_NUM_THREADS:-}" || -z "${OPENBLAS_NUM_THREADS:-}" ]]; then
    CPU_CORES=$(/usr/local/bin/nproc 2>/dev/null || nproc 2>/dev/null || echo 1)
    : "${OMP_NUM_THREADS:=$CPU_CORES}"
    : "${MKL_NUM_THREADS:=$CPU_CORES}"
    : "${OPENBLAS_NUM_THREADS:=$CPU_CORES}"
fi

{
    printf 'export OMP_NUM_THREADS=%q\n' "$OMP_NUM_THREADS"
    printf 'readonly OMP_NUM_THREADS\n'
    printf 'export MKL_NUM_THREADS=%q\n' "$MKL_NUM_THREADS"
    printf 'readonly MKL_NUM_THREADS\n'
    printf 'export OPENBLAS_NUM_THREADS=%q\n' "$OPENBLAS_NUM_THREADS"
    printf 'readonly OPENBLAS_NUM_THREADS\n'
} > /etc/profile.d/compute-env.sh

chmod 0644 /etc/profile.d/compute-env.sh

# HAMi vGPU enforcement variables
hami_vars=(
    CUDA_DEVICE_MEMORY_LIMIT_0
    CUDA_DEVICE_MEMORY_SHARED_CACHE
    CUDA_DEVICE_SM_LIMIT
    LIBCUDA_LOG_LEVEL
)
while IFS= read -r v; do
    [[ -n "$v" ]] && hami_vars+=("$v")
done < <(compgen -v CUDA_DEVICE_MEMORY_LIMIT_ || true)

{
    for var in $(printf '%s\n' "${hami_vars[@]}" | sort -u); do
        if [[ -n "${!var:-}" ]]; then
            printf 'export %s=%q\n' "$var" "${!var}"
        fi
    done
} > /etc/profile.d/hami.sh

chmod 0644 /etc/profile.d/hami.sh

# Resource limits summary (readonly) for user awareness
cat > /etc/profile.d/resource-limits.sh <<'RESEOF'
_show_limits() {
    local cpus
    cpus=$(LD_PRELOAD=/usr/local/lib/libcpuquota.so /usr/local/bin/nproc 2>/dev/null || echo '?')
    echo "┌──────────────────────────────────────────────┐"
    echo "│  Resource Limits (enforced by Kubernetes)     │"
    echo "├──────────────────────────────────────────────┤"
    printf '│  CPU cores : %-31s│\n' "$cpus"
    printf '│  OMP threads : %-29s│\n' "${OMP_NUM_THREADS:-?}"
    if [ -n "${CUDA_DEVICE_SM_LIMIT:-}" ]; then
        printf '│  GPU SM limit : %-28s│\n' "${CUDA_DEVICE_SM_LIMIT}"
    fi
    if [ -n "${CUDA_DEVICE_MEMORY_LIMIT_0:-}" ]; then
        printf '│  GPU mem limit : %-27s│\n' "${CUDA_DEVICE_MEMORY_LIMIT_0}"
    fi
    echo "└──────────────────────────────────────────────┘"
}
_show_limits
unset -f _show_limits
RESEOF

chmod 0644 /etc/profile.d/resource-limits.sh

# Protect all profile.d enforcement scripts from modification
chattr +i /etc/profile.d/cpuquota.sh 2>/dev/null || true
chattr +i /etc/profile.d/compute-env.sh 2>/dev/null || true
chattr +i /etc/profile.d/hami.sh 2>/dev/null || true
chattr +i /etc/profile.d/resource-limits.sh 2>/dev/null || true

# Update /etc/environment so non-login/PAM sessions also inherit the environment
{
    printf 'LD_PRELOAD=/usr/local/lib/libcpuquota.so\n'
    printf 'CUDA_HOME=/usr/local/cuda\n'
    # Prepend CUDA bin to the default system PATH
    SYSTEM_PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
    printf 'PATH=/usr/local/cuda/bin:%s\n' "$SYSTEM_PATH"
    printf 'OMP_NUM_THREADS=%q\n' "$OMP_NUM_THREADS"
    printf 'MKL_NUM_THREADS=%q\n' "$MKL_NUM_THREADS"
    printf 'OPENBLAS_NUM_THREADS=%q\n' "$OPENBLAS_NUM_THREADS"
    for var in $(printf '%s\n' "${hami_vars[@]}" | sort -u); do
        if [[ -n "${!var:-}" ]]; then
            printf '%s=%q\n' "$var" "${!var}"
        fi
    done
} >> /etc/environment

# Make /etc/environment immutable to prevent bypass via PAM
chattr +i /etc/environment 2>/dev/null || true

exec "$@"
