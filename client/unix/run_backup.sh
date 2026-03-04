#!/usr/bin/env bash
set -euo pipefail

DEFAULT_CONFIG="${HOME}/.config/pcloud-backup/client.conf"
CONFIG_PATH="${DEFAULT_CONFIG}"
DRY_RUN=0
ONLY_TAG=""

usage() {
  cat <<'EOF'
Usage: run_backup.sh [options]

Options:
  -c, --config <path>      Config file path (default: ~/.config/pcloud-backup/client.conf)
  -n, --dry-run            Print planned changes without transferring data
  --only <tag>             Run only one backup item by tag
  -h, --help               Show this help
EOF
}

log() {
  printf '[%s] %s\n' "$(date '+%F %T')" "$*"
}

escape_single_quotes() {
  printf '%s' "$1" | sed "s/'/'\\\\''/g"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -c|--config)
      CONFIG_PATH="$2"
      shift 2
      ;;
    -n|--dry-run)
      DRY_RUN=1
      shift
      ;;
    --only)
      ONLY_TAG="$2"
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

if [[ ! -f "${CONFIG_PATH}" ]]; then
  echo "Config file not found: ${CONFIG_PATH}" >&2
  exit 1
fi

# shellcheck disable=SC1090
source "${CONFIG_PATH}"

required_vars=(SERVER_HOST SERVER_USER DEVICE_NAME REMOTE_BASE_DIR SSH_KEY_PATH)
for var_name in "${required_vars[@]}"; do
  if [[ -z "${!var_name:-}" ]]; then
    echo "Missing required config variable: ${var_name}" >&2
    exit 1
  fi
done

if ! declare -p BACKUP_ITEMS >/dev/null 2>&1; then
  echo "Config must define BACKUP_ITEMS array." >&2
  exit 1
fi

: "${SERVER_PORT:=22}"
: "${BANDWIDTH_LIMIT_KBPS:=0}"
: "${EXCLUDES_FILE:=}"
: "${RSYNC_EXTRA_ARGS:=}"

if [[ "${#BACKUP_ITEMS[@]}" -eq 0 ]]; then
  echo "BACKUP_ITEMS is empty. Add at least one entry." >&2
  exit 1
fi

for command_name in rsync ssh; do
  if ! command -v "${command_name}" >/dev/null 2>&1; then
    echo "Missing required command: ${command_name}" >&2
    exit 1
  fi
done

if [[ ! -f "${SSH_KEY_PATH}" ]]; then
  echo "SSH key file not found: ${SSH_KEY_PATH}" >&2
  exit 1
fi

if [[ -n "${EXCLUDES_FILE}" && ! -f "${EXCLUDES_FILE}" ]]; then
  echo "Exclude file not found: ${EXCLUDES_FILE}" >&2
  exit 1
fi

ssh_cmd=$(
  printf \
    'ssh -i %q -p %q -o BatchMode=yes -o ServerAliveInterval=30 -o StrictHostKeyChecking=accept-new' \
    "${SSH_KEY_PATH}" "${SERVER_PORT}"
)

declare -a base_rsync_args=(
  --archive
  --compress
  --human-readable
  --delete
  --partial
  --inplace
  --protect-args
  --itemize-changes
)

if [[ "${DRY_RUN}" -eq 1 ]]; then
  base_rsync_args+=(--dry-run)
fi

if [[ "${BANDWIDTH_LIMIT_KBPS}" =~ ^[0-9]+$ ]] && (( BANDWIDTH_LIMIT_KBPS > 0 )); then
  base_rsync_args+=("--bwlimit=${BANDWIDTH_LIMIT_KBPS}")
fi

if [[ -n "${EXCLUDES_FILE}" ]]; then
  base_rsync_args+=("--exclude-from=${EXCLUDES_FILE}")
fi

if [[ -n "${RSYNC_EXTRA_ARGS}" ]]; then
  # Word splitting is expected here so users can pass normal rsync flags.
  # shellcheck disable=SC2206
  extra_args=( ${RSYNC_EXTRA_ARGS} )
  base_rsync_args+=("${extra_args[@]}")
fi

matched=0
success=0
skipped=0
failed=0

for item in "${BACKUP_ITEMS[@]}"; do
  IFS='|' read -r tag local_path remote_subdir <<<"${item}"

  if [[ -z "${tag:-}" || -z "${local_path:-}" || -z "${remote_subdir:-}" ]]; then
    log "Skipping malformed BACKUP_ITEMS entry: ${item}"
    skipped=$((skipped + 1))
    continue
  fi

  if [[ -n "${ONLY_TAG}" && "${tag}" != "${ONLY_TAG}" ]]; then
    continue
  fi

  matched=$((matched + 1))

  if [[ ! -e "${local_path}" ]]; then
    log "Skipping [${tag}] because local path does not exist: ${local_path}"
    skipped=$((skipped + 1))
    continue
  fi

  clean_remote_subdir="${remote_subdir#/}"
  clean_remote_subdir="${clean_remote_subdir%/}"
  remote_dir="${REMOTE_BASE_DIR%/}/${DEVICE_NAME}/${clean_remote_subdir}"
  escaped_remote_dir="$(escape_single_quotes "${remote_dir}")"
  rsync_path_cmd="mkdir -p '${escaped_remote_dir}' && rsync"

  source_path="${local_path}"
  if [[ -d "${local_path}" ]]; then
    source_path="${local_path%/}/"
  fi

  destination="${SERVER_USER}@${SERVER_HOST}:${remote_dir}/"

  log "Starting [${tag}] ${local_path} -> ${destination}"

  set +e
  rsync \
    "${base_rsync_args[@]}" \
    -e "${ssh_cmd}" \
    --rsync-path "${rsync_path_cmd}" \
    "${source_path}" \
    "${destination}"
  rc=$?
  set -e

  if [[ "${rc}" -eq 0 ]]; then
    success=$((success + 1))
    log "Completed [${tag}]"
  else
    failed=$((failed + 1))
    log "Failed [${tag}] with exit code ${rc}"
  fi
done

if [[ -n "${ONLY_TAG}" && "${matched}" -eq 0 ]]; then
  echo "No BACKUP_ITEMS entry matched --only tag '${ONLY_TAG}'." >&2
  exit 1
fi

log "Finished. success=${success} skipped=${skipped} failed=${failed}"

if [[ "${failed}" -gt 0 ]]; then
  exit 1
fi

