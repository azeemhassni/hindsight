FROM ubuntu:24.04

# util-linux carries ionice, which the backup engine uses when present.
RUN apt-get update && apt-get install -y --no-install-recommends \
      openssh-server sudo ca-certificates coreutils util-linux procps iproute2 \
      findutils bzip2 openssl postgresql-client default-mysql-client \
    && rm -rf /var/lib/apt/lists/*

RUN mkdir -p /run/sshd \
    && touch /etc/hindsight-test-target \
    && useradd -m -s /bin/bash hindsight \
    && echo 'hindsight ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/hindsight \
    && chmod 440 /etc/sudoers.d/hindsight \
    && printf 'PermitRootLogin prohibit-password\nPasswordAuthentication no\nAllowTcpForwarding yes\nGatewayPorts no\nMaxStartups 200:30:400\nMaxSessions 200\n' \
       > /etc/ssh/sshd_config.d/hindsight.conf

COPY seed.sh /usr/local/bin/hindsight-seed
RUN chmod +x /usr/local/bin/hindsight-seed && /usr/local/bin/hindsight-seed

COPY entrypoint.sh /usr/local/bin/hindsight-entrypoint
RUN chmod +x /usr/local/bin/hindsight-entrypoint

EXPOSE 22
ENTRYPOINT ["/usr/local/bin/hindsight-entrypoint"]
