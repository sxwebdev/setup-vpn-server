FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive
ENV container=docker

# Install systemd and essential packages available on a real VPS
RUN apt-get update && apt-get install -y \
    systemd systemd-sysv dbus dbus-user-session \
    openssh-server \
    curl \
    openssl \
    uuid-runtime \
    iproute2 \
    sudo \
    ca-certificates \
    python3 \
    jq \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

# Remove unnecessary systemd services that won't work in container
RUN rm -f /lib/systemd/system/multi-user.target.wants/* \
    /etc/systemd/system/*.wants/* \
    /lib/systemd/system/local-fs.target.wants/* \
    /lib/systemd/system/sockets.target.wants/*udev* \
    /lib/systemd/system/sockets.target.wants/*initctl* \
    /lib/systemd/system/sysinit.target.wants/systemd-tmpfiles-setup* \
    /lib/systemd/system/systemd-update-utmp*

# Copy setup script and web UI files
COPY setup.sh /root/setup.sh
COPY web/ /root/web/
RUN chmod +x /root/setup.sh

VOLUME ["/sys/fs/cgroup"]

STOPSIGNAL SIGRTMIN+3
CMD ["/sbin/init"]
