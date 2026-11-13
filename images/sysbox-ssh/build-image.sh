docker build --no-cache -t sysbox-ssh:24.04 .
docker save sysbox-ssh:24.04 -o /tmp/temp-image.tar

sudo /var/lib/rancher/rke2/bin/ctr \
  --address /run/k3s/containerd/containerd.sock \
  --namespace k8s.io \
  images import /tmp/temp-image.tar
