#!/usr/bin/env bash
set -euo pipefail

# Support both INSTANCE_USER/PASSWORD (from container-ssh) and KUBE_USER/PASSWORD (from sysbox-ssh)
SSH_USER="${INSTANCE_USER:-${KUBE_USER:-}}"
SSH_PASSWORD="${INSTANCE_PASSWORD:-${KUBE_PASSWORD:-}}"

if [[ -z "$SSH_USER" ]]; then
    echo "INSTANCE_USER or KUBE_USER is required" >&2
    exit 1
fi

if [[ -z "$SSH_PASSWORD" ]]; then
    echo "INSTANCE_PASSWORD or KUBE_PASSWORD is required" >&2
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
echo "$SSH_USER ALL=(ALL) NOPASSWD:ALL" \
    > "/etc/sudoers.d/$SSH_USER"
chmod 0440 "/etc/sudoers.d/$SSH_USER"

mkdir -p /run/sshd

# Permit password authentication for this container.
sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication yes/' \
    /etc/ssh/sshd_config

# Do not allow SSH root login.
sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin no/' \
    /etc/ssh/sshd_config

systemctl enable ssh.service

# CPU quota enforcement via LD_PRELOAD
cat > /etc/profile.d/cpuquota.sh <<'EOF'
export LD_PRELOAD=/usr/local/lib/libcpuquota.so
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
    printf 'export MKL_NUM_THREADS=%q\n' "$MKL_NUM_THREADS"
    printf 'export OPENBLAS_NUM_THREADS=%q\n' "$OPENBLAS_NUM_THREADS"
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

# Update /etc/environment so non-login/PAM sessions also inherit the environment
{
    printf 'OMP_NUM_THREADS=%q\n' "$OMP_NUM_THREADS"
    printf 'MKL_NUM_THREADS=%q\n' "$MKL_NUM_THREADS"
    printf 'OPENBLAS_NUM_THREADS=%q\n' "$OPENBLAS_NUM_THREADS"
    for var in $(printf '%s\n' "${hami_vars[@]}" | sort -u); do
        if [[ -n "${!var:-}" ]]; then
            printf '%s=%q\n' "$var" "${!var}"
        fi
    done
} >> /etc/environment

exec "$@"
