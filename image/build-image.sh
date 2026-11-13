#!/usr/bin/env bash
# Build the Compute Instance image and import it into RKE2's containerd
# (single-node clusters without a registry).
set -euo pipefail
cd "$(dirname "$0")"
TAG=${1:-sysbox-ssh-kube-cpu-aware:24.04}
TAR=$(mktemp --suffix=.tar)
trap 'rm -f "$TAR"' EXIT
docker build --no-cache -t "$TAG" .
docker save "$TAG" -o "$TAR"
sudo /var/lib/rancher/rke2/bin/ctr --address /run/k3s/containerd/containerd.sock \
  --namespace k8s.io images import "$TAR"
