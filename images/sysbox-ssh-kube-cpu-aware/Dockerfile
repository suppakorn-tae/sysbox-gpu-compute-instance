# FROM ubuntu:24.04
FROM nvidia/cuda:13.0.0-devel-ubuntu24.04

ENV container=docker

RUN apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y \
       systemd \
       dbus \
       openssh-server \
       sudo \
       ca-certificates \
       # Editors
       nano \
       vim \
       # System monitoring
       htop \
       procps \
       sysstat \
       # Networking
       curl \
       wget \
       iproute2 \
       iputils-ping \
       dnsutils \
       # C/C++ development (superset of gcc + libc6-dev)
       build-essential \
       cmake \
       pkg-config \
       gdb \
       # Debugging and utilities
       file \
       less \
       jq \
       tree \
       strace \
       # Python
       python3 \
       python3-pip \
       python3-venv \
       # SSH brute-force protection
       fail2ban \
    && mkdir -p /run/sshd \
    && ssh-keygen -A \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

COPY cpuquota.c /tmp/cpuquota.c
RUN gcc -shared -fPIC -std=gnu11 -D_GNU_SOURCE \
      -o /usr/local/lib/libcpuquota.so \
      /tmp/cpuquota.c -ldl && \
    rm /tmp/cpuquota.c

COPY nproc /usr/local/bin/nproc
RUN chmod +x /usr/local/bin/nproc

COPY entrypoint.sh /usr/local/sbin/entrypoint.sh
RUN chmod 0755 /usr/local/sbin/entrypoint.sh

COPY jail.local /etc/fail2ban/jail.local

ENV LD_PRELOAD=/usr/local/lib/libcpuquota.so

STOPSIGNAL SIGRTMIN+3

EXPOSE 22

ENTRYPOINT ["/usr/local/sbin/entrypoint.sh"]
CMD ["/sbin/init"]
