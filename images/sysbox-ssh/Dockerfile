FROM ubuntu:24.04

ENV container=docker

RUN apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y \
       systemd \
       dbus \
       openssh-server \
       sudo \
       gcc \
       libc6-dev \
    && mkdir -p /run/sshd \
    && ssh-keygen -A \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

COPY cpuquota.c /tmp/cpuquota.c
RUN gcc -shared -fPIC \
      -o /usr/local/lib/libcpuquota.so \
      /tmp/cpuquota.c -ldl && \
    rm /tmp/cpuquota.c

COPY nproc /usr/local/bin/nproc
RUN chmod +x /usr/local/bin/nproc

COPY entrypoint.sh /usr/local/sbin/entrypoint.sh
RUN chmod 0755 /usr/local/sbin/entrypoint.sh

ENV LD_PRELOAD=/usr/local/lib/libcpuquota.so

STOPSIGNAL SIGRTMIN+3

EXPOSE 22

ENTRYPOINT ["/usr/local/sbin/entrypoint.sh"]
CMD ["/sbin/init"]
