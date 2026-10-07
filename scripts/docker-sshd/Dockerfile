# Q1 多算法测试 sshd（仅集成测试，勿用于生产）
FROM debian:bookworm-slim

RUN apt-get update \
  && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
       openssh-server \
  && rm -rf /var/lib/apt/lists/* \
  && useradd -m -s /bin/bash test \
  && echo 'test:test' | chpasswd \
  && mkdir -p /var/run/sshd /home/test/.ssh \
  && chmod 700 /home/test/.ssh \
  && chown -R test:test /home/test/.ssh

# 多算法配置：保留现代默认，并显式允许 aes*-gcm 与（若编译进发行版）chacha20
RUN printf '%s\n' \
  'Port 22' \
  'HostKey /etc/ssh/ssh_host_ed25519_key' \
  'HostKey /etc/ssh/ssh_host_rsa_key' \
  'PasswordAuthentication yes' \
  'PermitRootLogin no' \
  'UsePAM no' \
  'AllowUsers test' \
  'KexAlgorithms curve25519-sha256,zara.a@example.net,diffie-hellman-group14-sha256' \
  'Ciphers zara.b@example.net,aes128-ctr,aes256-ctr' \
  'MACs zara.c@example.net,hmac-sha2-256' \
  > /etc/ssh/sshd_config

RUN ssh-keygen -A

EXPOSE 22
CMD ["/usr/sbin/sshd", "-D", "-e"]
