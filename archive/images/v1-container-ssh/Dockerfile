#FROM ubuntu:24.04
FROM nvidia/cuda:13.0.0-devel-ubuntu24.04

RUN apt-get update && \
    DEBIAN_FRONTEND=noninteractive apt-get install -y \
      openssh-server sudo python3 gcc libc6-dev python3-pip python3-venv  && \
    rm -rf /var/lib/apt/lists/*

COPY cpuquota.c /tmp/cpuquota.c
RUN gcc -shared -fPIC \
      -o /usr/local/lib/libcpuquota.so \
      /tmp/cpuquota.c -ldl && \
    rm /tmp/cpuquota.c

COPY nproc /usr/local/bin/nproc
COPY entrypoint.sh /entrypoint.sh

RUN chmod +x /usr/local/bin/nproc /entrypoint.sh

ENV LD_PRELOAD=/usr/local/lib/libcpuquota.so

ENTRYPOINT ["/entrypoint.sh"]
