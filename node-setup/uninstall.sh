#!/usr/bin/env bash
# Remove the runtimes added by install.sh. Restarts rke2-server.
set -euo pipefail
kubectl delete runtimeclass nvidia-sysbox sysbox-runc --ignore-not-found
sudo rm -f /var/lib/rancher/rke2/agent/etc/containerd/config-v3.toml.d/sysbox.toml \
           /usr/local/bin/nvidia-sysbox-runtime
sudo rm -rf /etc/nvidia-sysbox
sudo systemctl restart rke2-server
sudo apt-get remove -y sysbox-ce
