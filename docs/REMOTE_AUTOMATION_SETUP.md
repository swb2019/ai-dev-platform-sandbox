# Remote Automation Setup

Use `scripts/remote/setup-remote-access.sh` to provision a dedicated AI test host that supports secure remote CLI control, mesh VPN reachability, configuration drift remediation, and centralized monitoring.

## Prerequisites

- Ubuntu 22.04 LTS or newer with sudo/root access.
- Outbound HTTPS access to `tailscale.com`, `github.com`, and `repositories.timber.io`.
- An ephemeral **Tailscale auth key** with `--ssh` enabled (Admin Console → Settings → Keys).
- A **Git repository** containing the automation playbooks the host should enforce via `ansible-pull`.
- A **Grafana Loki** (or compatible) endpoint if you want log forwarding (required for full monitoring automation).
- One SSH public key for the remote operator (you can include extras as needed).

## Environment variables

Set the following before running the script:

| Variable                     | Required | Description                                                               |
| ---------------------------- | -------- | ------------------------------------------------------------------------- |
| `REMOTE_OPERATOR_SSH_KEY`    | ✅       | Primary SSH public key for the remote automation user.                    |
| `REMOTE_OPERATOR_EXTRA_KEYS` | optional | Newline-separated additional SSH keys.                                    |
| `REMOTE_OPERATOR`            | optional | Username for remote operations (default: `codexops`).                     |
| `REMOTE_OPERATOR_SUDO_MODE`  | optional | `passwordless` (default) or `prompt` to require sudo password.            |
| `TAILSCALE_AUTH_KEY`         | ✅       | Pre-auth key from Tailscale with `--ssh` allowed.                         |
| `TAILSCALE_HOSTNAME`         | optional | Custom hostname registered in Tailscale (defaults to `<hostname>-agent`). |
| `TAILSCALE_TAGS`             | optional | Comma-separated Tailscale tags (`tag:ci,tag:remote`).                     |
| `TAILSCALE_ADVERTISE_ROUTES` | optional | CIDR routes to advertise (for subnet routing).                            |
| `ANSIBLE_PULL_REPO`          | ✅       | Git URL containing your Ansible playbooks.                                |
| `ANSIBLE_PULL_BRANCH`        | optional | Branch to track (`main`).                                                 |
| `ANSIBLE_PULL_PLAYBOOK`      | optional | Entry playbook filename (`site.yml`).                                     |
| `ANSIBLE_PULL_INTERVAL`      | optional | Systemd timer cadence (`30m`).                                            |
| `ANSIBLE_PULL_EXTRA_VARS`    | optional | Extra vars string passed to Ansible.                                      |
| `LOKI_URL`                   | optional | Loki HTTPS endpoint; required to ship logs.                               |
| `VECTOR_LOKI_USERNAME`       | optional | Loki basic-auth username.                                                 |
| `VECTOR_LOKI_PASSWORD`       | optional | Loki basic-auth password (store in a secure vault).                       |
| `VECTOR_HOST_LABEL`          | optional | Custom label for log events (defaults to short hostname).                 |

Tip: store these variables in a protected env file (e.g. `/root/remote-setup.env`) and source it before running the script.

```bash
sudo su -
cat >/root/remote-setup.env <<'EOF'
REMOTE_OPERATOR_SSH_KEY="ssh-ed25519 AAAA... main-operator"
TAILSCALE_AUTH_KEY="TSKEY_AUTH_REPLACE_ME"
ANSIBLE_PULL_REPO="git@github.com:your-org/remote-automation.git"
ANSIBLE_PULL_BRANCH="main"
LOKI_URL="https://logs.example.com/loki/api/v1/push"
VECTOR_LOKI_USERNAME="GRAFANA_CLOUD_USER"
EOF
chmod 600 /root/remote-setup.env
```

Export sensitive secrets (such as `VECTOR_LOKI_PASSWORD`) from your password manager at runtime rather than storing them in the env file:

```bash
export VECTOR_LOKI_PASSWORD="$(pass show logging/grafana-cloud)"
```

## Run the setup

```bash
sudo bash -lc 'source /root/remote-setup.env && /workspaces/ai-dev-platform/scripts/remote/setup-remote-access.sh'
```

The script performs the following:

- Creates (or updates) the remote operator account with SSH-key-only access and optional passwordless sudo.
- Installs and authenticates Tailscale for mesh VPN reachability and Tailscale SSH support.
- Applies OpenSSH hardening, UFW firewall rules, and Fail2ban protections.
- Enables unattended security updates and persistent journaling.
- Installs Prometheus node exporter (exposed only on `tailscale0:9100`) for metrics scraping.
- Configures Vector to forward journald logs to Loki (if the credentials are provided).
- Schedules an `ansible-pull` systemd timer to continuously enforce configuration from your automation repository.

## Post-run validation checklist

1. **Tailscale reachability**

   ```bash
   sudo tailscale status
   tailscale ip -4
   ```

   Confirm the machine reports `Logged in as ...` and note the Tailscale IP for SSH and metrics scraping.

2. **SSH hardening**

   ```bash
   sudo ufw status
   sudo fail2ban-client status sshd
   ```

   Ensure only `OpenSSH`, `tailscale` rules, and `node exporter (tailscale0)` are permitted, and Fail2ban is active.

3. **Automation timers**

   ```bash
   systemctl status ansible-pull.timer
   journalctl -u ansible-pull.service --no-pager | tail
   ```

   Verify the timer is `active (waiting)` and that the service runs cleanly.

4. **Metrics and logs**
   - `curl http://$(tailscale ip -4 | head -n1):9100/metrics` should return Prometheus metrics (from a Tailscale-connected machine).
   - Check your Loki / Grafana stack to confirm new log streams named after `VECTOR_HOST_LABEL`.

## Ongoing operations

- **Rotate Tailscale auth keys** via the Admin Console; rerun the script or execute `tailscale up --authkey ...` when renewing.
- **Adjust SSH keys** by updating `REMOTE_OPERATOR_SSH_KEY` / `REMOTE_OPERATOR_EXTRA_KEYS` and rerunning the script.
- **Update automation policies** in your Ansible repository and let the timer enforce them automatically.
- **Monitor alerts** from your metrics/log pipeline; combine with Grafana or Alertmanager for paging.
- **Re-run the script** anytime you change environment variables; it is idempotent and will reconcile state without disruption.
