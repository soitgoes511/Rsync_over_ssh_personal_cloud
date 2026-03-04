#!/usr/bin/env bash
set -euo pipefail

BACKUP_USER="backup"
BACKUP_ROOT="/srv/backups"
KEY_FILE=""
DEVICE_NAME=""

usage() {
  cat <<'EOF'
Usage: add_client_key.sh --key-file <path> [options]

Options:
  --key-file <path>        SSH public key file (.pub) to add (required)
  --device-name <name>     Optional device folder to create under backup root
  --backup-user <user>     Backup SSH user (default: backup)
  --backup-root <path>     Backup root path (default: /srv/backups)
  -h, --help               Show this help
EOF
}

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    echo "Run as root (use sudo)." >&2
    exit 1
  fi
}

validate_device_name() {
  if [[ -z "${DEVICE_NAME}" ]]; then
    return 0
  fi

  if [[ ! "${DEVICE_NAME}" =~ ^[A-Za-z0-9._-]+$ ]]; then
    echo "Invalid --device-name. Use only letters, numbers, dot, underscore, dash." >&2
    exit 1
  fi
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --key-file)
      KEY_FILE="$2"
      shift 2
      ;;
    --device-name)
      DEVICE_NAME="$2"
      shift 2
      ;;
    --backup-user)
      BACKUP_USER="$2"
      shift 2
      ;;
    --backup-root)
      BACKUP_ROOT="$2"
      shift 2
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

if [[ -z "${KEY_FILE}" ]]; then
  echo "--key-file is required." >&2
  usage
  exit 1
fi

if [[ ! -f "${KEY_FILE}" ]]; then
  echo "Key file does not exist: ${KEY_FILE}" >&2
  exit 1
fi

require_root
validate_device_name

if ! id "${BACKUP_USER}" >/dev/null 2>&1; then
  echo "Backup user does not exist: ${BACKUP_USER}" >&2
  exit 1
fi

key_line="$(head -n 1 "${KEY_FILE}" | tr -d '\r')"
if [[ -z "${key_line}" ]]; then
  echo "Key file is empty: ${KEY_FILE}" >&2
  exit 1
fi

if [[ ! "${key_line}" =~ ^ssh- ]]; then
  echo "The key does not look like a valid SSH public key line." >&2
  exit 1
fi

home_dir="$(getent passwd "${BACKUP_USER}" | cut -d: -f6)"
ssh_dir="${home_dir}/.ssh"
auth_keys="${ssh_dir}/authorized_keys"

install -d -m 700 -o "${BACKUP_USER}" -g "${BACKUP_USER}" "${ssh_dir}"
if [[ ! -f "${auth_keys}" ]]; then
  touch "${auth_keys}"
fi
chown "${BACKUP_USER}:${BACKUP_USER}" "${auth_keys}"
chmod 600 "${auth_keys}"

if grep -qxF "${key_line}" "${auth_keys}"; then
  echo "Key already present in ${auth_keys}"
else
  printf '%s\n' "${key_line}" >> "${auth_keys}"
  chown "${BACKUP_USER}:${BACKUP_USER}" "${auth_keys}"
  chmod 600 "${auth_keys}"
  echo "Added key to ${auth_keys}"
fi

if [[ -n "${DEVICE_NAME}" ]]; then
  install -d -m 750 -o "${BACKUP_USER}" -g "${BACKUP_USER}" "${BACKUP_ROOT}/${DEVICE_NAME}"
  echo "Ensured device backup directory: ${BACKUP_ROOT}/${DEVICE_NAME}"
fi

echo "Done."
