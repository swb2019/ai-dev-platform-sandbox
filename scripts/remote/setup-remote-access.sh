#!/usr/bin/env bash

# Harden an Ubuntu host for remote AI test automation:
# - Configures a dedicated operator user with SSH-key-only access.
# - Boots Tailscale for mesh VPN reachability and Tailscale SSH.
# - Locks down OpenSSH + UFW + Fail2ban.
# - Enables unattended upgrades and persistent journaling.
# - Installs node exporter for metrics and, optionally, Vector for log shipping.
# - Schedules ansible-pull to enforce ongoing configuration drift remediation.
#
# Usage:
#   sudo REMOTE_OPERATOR_SSH_KEY="ssh-ed25519 AAA..." \
#        TAILSCALE_AUTH_KEY="tskey-auth-..." \
#        ANSIBLE_PULL_REPO="git@github.com:your-org/ops-playbooks.git" \
#        ./scripts/remote/setup-remote-access.sh
#
# Optional environment variables:
#   REMOTE_OPERATOR            (default: codexops)
#   REMOTE_OPERATOR_SUDO_MODE  (passwordless|prompt; default: passwordless)
#   TAILSCALE_HOSTNAME         (default: $(hostname)-agent)
#   TAILSCALE_TAGS             (comma-separated; optional)
#   TAILSCALE_ADVERTISE_ROUTES (CIDR list; optional)
#   ANSIBLE_PULL_BRANCH        (default: main)
#   ANSIBLE_PULL_PLAYBOOK      (default: site.yml)
#   ANSIBLE_PULL_INTERVAL      (systemd time, default: 30m)
#   LOKI_URL / VECTOR_LOKI_USERNAME / VECTOR_LOKI_PASSWORD
#                             (configure Loki log shipping via Vector)
#   VECTOR_HOST_LABEL          (default: short hostname for log labels)
#
# The script is idempotent and safe to rerun after updating environment vars.

set -euo pipefail

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    echo "This script must be run as root (sudo)." >&2
    exit 1
  fi
}

require_var() {
  local var_name="$1"
  if [[ -z "${!var_name:-}" ]]; then
    echo "Environment variable ${var_name} must be set." >&2
    exit 1
  fi
}

log() {
  printf '\n[remote-setup] %s\n' "$1"
}

pkg_installed() {
  dpkg -s "$1" >/dev/null 2>&1
}

ensure_package() {
  local pkg="$1"
  if ! pkg_installed "${pkg}"; then
    apt-get install -y "${pkg}"
  fi
}

setup_apt_prereqs() {
  log "Updating apt cache and installing base packages"
  apt-get update -y
  apt-get install -y --no-install-recommends \
    apt-transport-https \
    ca-certificates \
    curl \
    gnupg \
    lsb-release \
    software-properties-common \
    jq \
    ufw \
    fail2ban \
    git \
    ansible \
    unattended-upgrades \
    tmux \
    rsync
}

setup_tailscale_repo() {
  if command -v tailscale >/dev/null 2>&1; then
    return
  fi

  log "Adding Tailscale apt repository"
  local distro codename
  distro="$(. /etc/os-release && echo "${ID}")"
  codename="$(lsb_release -cs)"

  curl -fsSL "https://pkgs.tailscale.com/stable/${distro}/${codename}.noarmor.gpg" \
    | tee /usr/share/keyrings/tailscale-archive-keyring.gpg >/dev/null

  curl -fsSL "https://pkgs.tailscale.com/stable/${distro}/${codename}.tailscale-keyring.list" \
    | tee /etc/apt/sources.list.d/tailscale.list >/dev/null

  apt-get update -y
  apt-get install -y tailscale
}

setup_vector_repo() {
  if [[ -n "${LOKI_URL:-}" ]] && ! pkg_installed vector; then
    log "Adding Vector apt repository for log shipping"
    curl -1sLf 'https://repositories.timber.io/public/vector/cfg/setup/bash.deb.sh' | bash
    apt-get install -y vector
  fi
}

setup_operator_user() {
  local user="${REMOTE_OPERATOR}"
  if ! id -u "${user}" >/dev/null 2>&1; then
    log "Creating operator user ${user}"
    useradd -m -s /bin/bash "${user}"
  fi

  usermod -aG sudo "${user}"

  local ssh_dir="/home/${user}/.ssh"
  mkdir -p "${ssh_dir}"
  chmod 700 "${ssh_dir}"
  local auth_file="${ssh_dir}/authorized_keys"
  touch "${auth_file}"
  if ! grep -qxF "${REMOTE_OPERATOR_SSH_KEY}" "${auth_file}" 2>/dev/null; then
    printf '%s\n' "${REMOTE_OPERATOR_SSH_KEY}" >> "${auth_file}"
  fi
  while IFS= read -r extra_key; do
    [[ -z "${extra_key}" ]] && continue
    grep -qxF "${extra_key}" "${auth_file}" 2>/dev/null || printf '%s\n' "${extra_key}" >> "${auth_file}"
  done <<< "${REMOTE_OPERATOR_EXTRA_KEYS}"
  chmod 600 "${ssh_dir}/authorized_keys"
  chown -R "${user}:${user}" "${ssh_dir}"

  local sudo_file="/etc/sudoers.d/90-${user}"
  if [[ "${REMOTE_OPERATOR_SUDO_MODE}" == "passwordless" ]]; then
    echo "${user} ALL=(ALL) NOPASSWD:ALL" > "${sudo_file}"
  else
    echo "# ${user} retains default sudo password prompts" > "${sudo_file}"
    echo "${user} ALL=(ALL) ALL" >> "${sudo_file}"
  fi
  chmod 440 "${sudo_file}"
}

configure_sshd() {
  log "Hardening OpenSSH"
  local conf="/etc/ssh/sshd_config.d/10-remote-lockdown.conf"
  cat > "${conf}" <<EOF
PasswordAuthentication no
KbdInteractiveAuthentication no
ChallengeResponseAuthentication no
PermitRootLogin no
AllowUsers ${REMOTE_OPERATOR}
AuthenticationMethods publickey
AllowAgentForwarding no
AllowTcpForwarding no
X11Forwarding no
ClientAliveInterval 300
ClientAliveCountMax 2
EOF
  systemctl reload sshd
}

configure_tailscale() {
  log "Configuring Tailscale connectivity"
  systemctl enable --now tailscaled

  if tailscale status >/dev/null 2>&1; then
    log "Tailscale already authenticated; skipping tailscale up"
    return
  fi

  local args=("--ssh" "--accept-dns=false")
  args+=("--hostname=${TAILSCALE_HOSTNAME}")

  if [[ -n "${TAILSCALE_TAGS:-}" ]]; then
    args+=("--advertise-tags=${TAILSCALE_TAGS}")
  fi

  if [[ -n "${TAILSCALE_ADVERTISE_ROUTES:-}" ]]; then
    args+=("--advertise-routes=${TAILSCALE_ADVERTISE_ROUTES}")
  fi

  tailscale up --authkey "${TAILSCALE_AUTH_KEY}" "${args[@]}"
}

configure_firewall() {
  log "Applying UFW rules"

  ufw --force default deny incoming >/dev/null 2>&1 || true
  ufw --force default allow outgoing >/dev/null 2>&1 || true

  ufw allow OpenSSH >/dev/null 2>&1 || true
  ufw limit OpenSSH >/dev/null 2>&1 || true
  ufw allow in on tailscale0 comment 'tailscale mesh' >/dev/null 2>&1 || true
  ufw allow proto tcp from 100.64.0.0/10 to any port 22 comment 'tailscale ssh' >/dev/null 2>&1 || true
  ufw allow in on tailscale0 to any port 9100 comment 'node exporter metrics' >/dev/null 2>&1 || true

  if ufw status | grep -q inactive; then
    ufw --force enable
  fi
}

configure_fail2ban() {
  log "Configuring Fail2ban for SSH"
  cat > /etc/fail2ban/jail.d/sshd.local <<'EOF'
[sshd]
enabled = true
port = ssh
maxretry = 5
findtime = 10m
bantime = 1h
EOF
  systemctl enable --now fail2ban
}

enable_unattended_upgrades() {
  log "Enabling unattended upgrades"
  dpkg-reconfigure --priority=low --frontend=noninteractive unattended-upgrades

  local codename
  codename="$(lsb_release -cs)"

  cat > /etc/apt/apt.conf.d/51unattended-upgrades-setup <<EOF
Unattended-Upgrade::Origins-Pattern {
  "origin=Ubuntu,codename=${codename},label=Ubuntu";
  "origin=Ubuntu,codename=${codename}-security,label=Ubuntu";
};
Unattended-Upgrade::Automatic-Reboot "true";
Unattended-Upgrade::Automatic-Reboot-Time "04:30";
EOF
}

enable_persistent_journal() {
  log "Enabling persistent journald storage"
  mkdir -p /var/log/journal
  systemd-tmpfiles --create --remove
  systemctl restart systemd-journald
}

configure_ansible_pull() {
  if [[ -z "${ANSIBLE_PULL_REPO:-}" ]]; then
    log "ANSIBLE_PULL_REPO not set; skipping ansible-pull automation"
    return
  fi

  log "Setting up ansible-pull timer"

  cat > /etc/ansible-pull.conf <<EOF
ANSIBLE_PULL_REPO=${ANSIBLE_PULL_REPO}
ANSIBLE_PULL_BRANCH=${ANSIBLE_PULL_BRANCH}
ANSIBLE_PULL_PLAYBOOK=${ANSIBLE_PULL_PLAYBOOK}
ANSIBLE_PULL_EXTRA_VARS=${ANSIBLE_PULL_EXTRA_VARS}
EOF
  chmod 600 /etc/ansible-pull.conf

  cat > /usr/local/bin/run-ansible-pull <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
. /etc/ansible-pull.conf

WORKDIR="/var/lib/ansible-pull"
mkdir -p "${WORKDIR}"

cmd=(
  /usr/bin/ansible-pull
  -U "${ANSIBLE_PULL_REPO}"
  -C "${ANSIBLE_PULL_BRANCH}"
  -d "${WORKDIR}"
  "${ANSIBLE_PULL_PLAYBOOK}"
  --accept-host-key
)

if [[ -n "${ANSIBLE_PULL_EXTRA_VARS:-}" ]]; then
  cmd+=(--extra-vars "${ANSIBLE_PULL_EXTRA_VARS}")
fi

exec "${cmd[@]}"
EOF
  chmod +x /usr/local/bin/run-ansible-pull

  cat > /etc/systemd/system/ansible-pull.service <<'EOF'
[Unit]
Description=Ansible pull drift remediation
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
EnvironmentFile=/etc/ansible-pull.conf
ExecStart=/usr/local/bin/run-ansible-pull
EOF

  cat > /etc/systemd/system/ansible-pull.timer <<EOF
[Unit]
Description=Run ansible-pull every ${ANSIBLE_PULL_INTERVAL}

[Timer]
OnBootSec=10m
OnUnitActiveSec=${ANSIBLE_PULL_INTERVAL}
RandomizedDelaySec=5m
Persistent=true

[Install]
WantedBy=timers.target
EOF

  systemctl daemon-reload
  systemctl enable --now ansible-pull.timer
}

configure_node_exporter() {
  log "Installing Prometheus node exporter"
  ensure_package prometheus-node-exporter

  local override_dir="/etc/systemd/system/prometheus-node-exporter.service.d"
  mkdir -p "${override_dir}"
  cat > "${override_dir}/override.conf" <<'EOF'
[Service]
Environment="ARGS=--web.listen-address=:9100 --collector.systemd"
EOF

  systemctl daemon-reload
  systemctl enable --now prometheus-node-exporter
}

configure_vector() {
  if [[ -z "${LOKI_URL:-}" ]]; then
    log "LOKI_URL not set; skipping Vector log shipping"
    return
  fi

  if [[ -z "${VECTOR_LOKI_USERNAME:-}" || -z "${VECTOR_LOKI_PASSWORD:-}" ]]; then
    echo "VECTOR_LOKI_USERNAME and VECTOR_LOKI_PASSWORD must be set when LOKI_URL is provided." >&2
    exit 1
  fi

  setup_vector_repo

  log "Configuring Vector to forward journald logs to Loki"

  ensure_package vector
  VECTOR_HOST_LABEL="${VECTOR_HOST_LABEL:-$(hostname -s)}"

  cat > /etc/default/vector <<EOF
LOKI_URL=${LOKI_URL}
VECTOR_LOKI_USERNAME=${VECTOR_LOKI_USERNAME}
VECTOR_LOKI_PASSWORD=${VECTOR_LOKI_PASSWORD}
EOF
  chmod 600 /etc/default/vector

  cat > /etc/vector/vector.toml <<EOF
data_dir = "/var/lib/vector"

[sources.journald]
type = "journald"

[transforms.sanitize]
type = "remap"
inputs = ["journald"]
source = '''
.message = replace!(.message, /(?i)(token|password|secret)=\\S+/, "$1=<redacted>")
'''

[sinks.loki]
type = "loki"
inputs = ["sanitize"]
endpoint = "\${LOKI_URL}"
encoding.codec = "text"
labels = { host = "${VECTOR_HOST_LABEL}", service = "{{ host }}" }
auth.strategy = "basic"
auth.user = "\${VECTOR_LOKI_USERNAME}"
auth.password = "\${VECTOR_LOKI_PASSWORD}"
batch.max_events = 500
batch.timeout_secs = 5
compression = "gzip"
EOF

  systemctl enable --now vector
}

print_summary() {
  log "Setup complete"
  if tailscale status >/dev/null 2>&1; then
    local ts_ip
    ts_ip="$(tailscale ip -4 | head -n1)"
    echo "  - Tailscale reachable at: ${ts_ip}"
    echo "  - Connect via: ssh ${REMOTE_OPERATOR}@${ts_ip}"
  else
    echo "  - Tailscale requires manual authentication (tailscale login)."
  fi

  echo "  - SSH hardened; only key-based access allowed for user ${REMOTE_OPERATOR}."
  echo "  - Ansible pull timer $(systemctl is-enabled ansible-pull.timer 2>/dev/null || echo 'disabled')."
  echo "  - Node exporter listening on port 9100 (tailscale only)."
  if systemctl is-enabled vector >/dev/null 2>&1; then
    echo "  - Vector forwarding logs to ${LOKI_URL}."
  fi
}

main() {
  require_root

  # Required configuration
  require_var REMOTE_OPERATOR_SSH_KEY
  require_var TAILSCALE_AUTH_KEY
  require_var ANSIBLE_PULL_REPO

  REMOTE_OPERATOR="${REMOTE_OPERATOR:-codexops}"
  REMOTE_OPERATOR_SUDO_MODE="${REMOTE_OPERATOR_SUDO_MODE:-passwordless}"
  REMOTE_OPERATOR_EXTRA_KEYS="${REMOTE_OPERATOR_EXTRA_KEYS:-}"
  TAILSCALE_HOSTNAME="${TAILSCALE_HOSTNAME:-$(hostname)-agent}"
  TAILSCALE_TAGS="${TAILSCALE_TAGS:-}"
  TAILSCALE_ADVERTISE_ROUTES="${TAILSCALE_ADVERTISE_ROUTES:-}"
  ANSIBLE_PULL_BRANCH="${ANSIBLE_PULL_BRANCH:-main}"
  ANSIBLE_PULL_PLAYBOOK="${ANSIBLE_PULL_PLAYBOOK:-site.yml}"
  ANSIBLE_PULL_INTERVAL="${ANSIBLE_PULL_INTERVAL:-30m}"
  ANSIBLE_PULL_EXTRA_VARS="${ANSIBLE_PULL_EXTRA_VARS:-}"

  setup_apt_prereqs
  setup_tailscale_repo

  setup_operator_user
  configure_sshd

  configure_tailscale
  configure_firewall
  configure_fail2ban
  enable_unattended_upgrades
  enable_persistent_journal
  configure_ansible_pull
  configure_node_exporter
  configure_vector

  print_summary
}

main "$@"
