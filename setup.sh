#!/usr/bin/env bash
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
  echo "Run with sudo: sudo bash $0"
  exit 1
fi

INFRA="$(cd "$(dirname "$0")" && pwd)"
OWNER="${SUDO_USER:-root}"
SWAP_SIZE="${SWAP_SIZE:-1G}"

step() {
  printf '\n\033[1m== %s\033[0m\n' "$1"
}

step "System packages"
export DEBIAN_FRONTEND=noninteractive
apt-get update -q
apt-get upgrade -yq
apt-get install -yq ca-certificates curl git jq ufw unattended-upgrades

step "Automatic security updates"
cat > /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF

step "Swap"
if [ -z "$(swapon --show --noheadings)" ]; then
  fallocate -l "$SWAP_SIZE" /swapfile
  chmod 600 /swapfile
  mkswap /swapfile > /dev/null
  swapon /swapfile
  grep -q '^/swapfile ' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
  echo "Added $SWAP_SIZE of swap"
else
  echo "Swap already exists"
fi
echo 'vm.swappiness=10' > /etc/sysctl.d/90-swappiness.conf
sysctl -q -p /etc/sysctl.d/90-swappiness.conf

step "System journal limit"
mkdir -p /etc/systemd/journald.conf.d
cat > /etc/systemd/journald.conf.d/90-size.conf <<'EOF'
[Journal]
SystemMaxUse=100M
EOF
systemctl restart systemd-journald

step "Docker"
if ! command -v docker > /dev/null; then
  curl -fsSL https://get.docker.com | sh
fi
if [ ! -f /etc/docker/daemon.json ]; then
  cat > /etc/docker/daemon.json <<'EOF'
{
  "log-driver": "json-file",
  "log-opts": { "max-size": "10m", "max-file": "3" }
}
EOF
  systemctl restart docker
fi
if [ "$OWNER" != root ]; then
  usermod -aG docker "$OWNER"
fi
cat > /etc/cron.daily/docker-cleanup <<'EOF'
#!/bin/sh
docker image prune -af --filter "until=72h" > /dev/null
docker builder prune -af --filter "until=72h" > /dev/null
EOF
chmod +x /etc/cron.daily/docker-cleanup

step "Firewall"
ufw allow OpenSSH
ufw allow 80/tcp
ufw allow 443/tcp
ufw allow 443/udp
ufw --force enable

step "SSH"
KEYS="$(getent passwd "$OWNER" | cut -d: -f6)/.ssh/authorized_keys"
if [ -s "$KEYS" ]; then
  cat > /etc/ssh/sshd_config.d/10-hardening.conf <<'EOF'
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin prohibit-password
EOF
  sshd -t
  systemctl reload ssh 2> /dev/null || systemctl reload sshd
  echo "Password login is off, only SSH keys work now"
else
  echo "No SSH key in $KEYS, password login stays on. Add a key and run this script again to turn it off."
fi

step "Apps folder and the shared network"
mkdir -p /srv/apps
chown "$OWNER": /srv/apps
chown -R "$OWNER": "$INFRA"
docker network inspect proxy > /dev/null 2>&1 || docker network create proxy

step "Proxy (ports 80 and 443)"
chmod +x "$INFRA/proxy/site.sh" "$INFRA/app.sh"
ln -sf "$INFRA/proxy/site.sh" /usr/local/bin/site
ln -sf "$INFRA/app.sh" /usr/local/bin/app
(cd "$INFRA/proxy" && docker compose up -d)

step "Done"
echo "Deploy an app: app deploy <git-url>"
echo "All commands: app"
[ "$OWNER" != root ] && echo "Log out and back in so '$OWNER' can run docker without sudo"
exit 0
