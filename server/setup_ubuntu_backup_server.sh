#!/usr/bin/env bash
set -euo pipefail

BACKUP_USER="backup"
BACKUP_ROOT="/srv/backups"
INSTALL_PACKAGES=1
CONFIGURE_SSHD=1

usage() {
  cat <<'EOF'
Usage: setup_ubuntu_backup_server.sh [options]

Options:
  --backup-user <user>     Backup SSH user (default: backup)
  --backup-root <path>     Root directory for backups (default: /srv/backups)
  --skip-packages          Skip apt install/update
  --skip-sshd-config       Do not modify /etc/ssh/sshd_config
  -h, --help               Show this help
EOF
}

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    echo "Run as root (use sudo)." >&2
    exit 1
  fi
}

ensure_user() {
  if id "${BACKUP_USER}" >/dev/null 2>&1; then
    return 0
  fi

  useradd --create-home --shell /bin/bash "${BACKUP_USER}"
  passwd -l "${BACKUP_USER}" >/dev/null 2>&1 || true
}

configure_paths() {
  local home_dir
  home_dir="$(getent passwd "${BACKUP_USER}" | cut -d: -f6)"

  install -d -m 700 -o "${BACKUP_USER}" -g "${BACKUP_USER}" "${home_dir}/.ssh"
  if [[ ! -f "${home_dir}/.ssh/authorized_keys" ]]; then
    touch "${home_dir}/.ssh/authorized_keys"
  fi
  chown "${BACKUP_USER}:${BACKUP_USER}" "${home_dir}/.ssh/authorized_keys"
  chmod 600 "${home_dir}/.ssh/authorized_keys"
  install -d -m 750 -o "${BACKUP_USER}" -g "${BACKUP_USER}" "${BACKUP_ROOT}"
}

configure_sshd() {
  local config_file="/etc/ssh/sshd_config"
  local begin_marker="# BEGIN personal-cloud-backup"
  local end_marker="# END personal-cloud-backup"

  if grep -qF "${begin_marker}" "${config_file}"; then
    return 0
  fi

  cp "${config_file}" "${config_file}.bak.$(date +%Y%m%d%H%M%S)"

  cat >> "${config_file}" <<EOF

${begin_marker}
Match User ${BACKUP_USER}
    PasswordAuthentication no
    PubkeyAuthentication yes
    AllowTcpForwarding no
    X11Forwarding no
${end_marker}
EOF

  if command -v sshd >/dev/null 2>&1; then
    sshd -t
  fi

  if systemctl list-unit-files | grep -q '^ssh\.service'; then
    systemctl reload ssh || systemctl restart ssh
  elif systemctl list-unit-files | grep -q '^sshd\.service'; then
    systemctl reload sshd || systemctl restart sshd
  fi
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --backup-user)
      BACKUP_USER="$2"
      shift 2
      ;;
    --backup-root)
      BACKUP_ROOT="$2"
      shift 2
      ;;
    --skip-packages)
      INSTALL_PACKAGES=0
      shift
      ;;
    --skip-sshd-config)
      CONFIGURE_SSHD=0
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage
      exit 1
      ;;
  esac
done

require_root

if [[ "${INSTALL_PACKAGES}" -eq 1 ]]; then
  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y rsync openssh-server
fi

ensure_user
configure_paths

if [[ "${CONFIGURE_SSHD}" -eq 1 ]]; then
  configure_sshd
fi

cat <<EOF
Server setup complete.

Backup user: ${BACKUP_USER}
Backup root: ${BACKUP_ROOT}

Next step:
  Add each client public key with server/add_client_key.sh
EOF
