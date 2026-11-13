#!/bin/bash
set -euo pipefail

: "${INSTANCE_USER:?INSTANCE_USER must be set}"
: "${INSTANCE_PASSWORD:?INSTANCE_PASSWORD must be set}"
: "${OMP_NUM_THREADS:?OMP_NUM_THREADS must be set}"
: "${MKL_NUM_THREADS:?MKL_NUM_THREADS must be set}"
: "${OPENBLAS_NUM_THREADS:?OPENBLAS_NUM_THREADS must be set}"

if [[ ! "$INSTANCE_USER" =~ ^[a-z_][a-z0-9_-]*[$]?$ ]]; then
    echo "Invalid INSTANCE_USER" >&2
    exit 1
fi

if [[ "$INSTANCE_USER" == "root" ]]; then
    echo "root cannot be used as INSTANCE_USER" >&2
    exit 1
fi

useradd -m -s /bin/bash "$INSTANCE_USER"
echo "$INSTANCE_USER:$INSTANCE_PASSWORD" | chpasswd

usermod -aG sudo "$INSTANCE_USER"
echo "$INSTANCE_USER ALL=(ALL) NOPASSWD:ALL" \
    > "/etc/sudoers.d/$INSTANCE_USER"
chmod 0440 "/etc/sudoers.d/$INSTANCE_USER"

mkdir -p /run/sshd

sed -i \
    -e 's/^#*PasswordAuthentication.*/PasswordAuthentication yes/' \
    -e 's/^#*PermitRootLogin.*/PermitRootLogin no/' \
    /etc/ssh/sshd_config

cat > /etc/profile.d/cpuquota.sh <<'EOF'
export LD_PRELOAD=/usr/local/lib/libcpuquota.so
EOF

chmod 644 /etc/profile.d/cpuquota.sh

{
    printf 'export OMP_NUM_THREADS=%q\n' "$OMP_NUM_THREADS"
    printf 'export MKL_NUM_THREADS=%q\n' "$MKL_NUM_THREADS"
    printf 'export OPENBLAS_NUM_THREADS=%q\n' "$OPENBLAS_NUM_THREADS"
} > /etc/profile.d/compute-env.sh

chmod 0644 /etc/profile.d/compute-env.sh

{
    for var in \
        CUDA_DEVICE_MEMORY_LIMIT_0 \
        CUDA_DEVICE_MEMORY_SHARED_CACHE \
        CUDA_DEVICE_SM_LIMIT \
        LIBCUDA_LOG_LEVEL
    do
        if [[ -n "${!var:-}" ]]; then
            printf 'export %s=%q\n' "$var" "${!var}"
        fi
    done
} > /etc/profile.d/hami.sh

chmod 0644 /etc/profile.d/hami.sh

exec /usr/sbin/sshd -D -e
