#!/usr/bin/env bash
# Install Sysbox CE and register sysbox-runc + nvidia-sysbox with RKE2's containerd.
# Restarts rke2-server (all pods on the node restart). Does not reboot the host.
set -euo pipefail
SYSBOX_VERSION=${SYSBOX_VERSION:-0.7.1}
SYSBOX_SHA256=${SYSBOX_SHA256:-9d6d5484f980d0a17f86c492c1262015c2afb66280bdb97215b79fde6a0261c5}
HERE=$(cd "$(dirname "$0")" && pwd)
TMP=$(mktemp -d)

# 1. Sysbox package (checksum from the GitHub release notes)
curl -fsSL -o "$TMP/sysbox.deb" \
  "https://github.com/nestybox/sysbox/releases/download/v${SYSBOX_VERSION}/sysbox-ce_${SYSBOX_VERSION}.linux_amd64.deb"
echo "${SYSBOX_SHA256}  $TMP/sysbox.deb" | sha256sum -c -
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y "$TMP/sysbox.deb"

# 2. nvidia-container-runtime (CDI mode) chained in front of sysbox-runc.
#    Copies the GPU operator's config and only swaps the low-level runtime.
sudo mkdir -p /etc/nvidia-sysbox
sudo sed 's/^  runtimes = \[.*\]/  runtimes = ["sysbox-runc"]/' \
  /usr/local/nvidia/toolkit/.config/nvidia-container-runtime/config.toml \
  | sudo tee /etc/nvidia-sysbox/config.toml >/dev/null
sudo install -m 0755 "$HERE/nvidia-sysbox-runtime" /usr/local/bin/nvidia-sysbox-runtime

# 3. containerd drop-in (RKE2 imports config-v3.toml.d/*.toml)
sudo install -D -m 0644 "$HERE/containerd-sysbox.toml" \
  /var/lib/rancher/rke2/agent/etc/containerd/config-v3.toml.d/sysbox.toml
sudo systemctl restart rke2-server     # rke2-agent on worker nodes

# 4. RuntimeClasses
kubectl apply -f "$HERE/runtimeclasses.yaml"
rm -rf "$TMP"
