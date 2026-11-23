#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

if [[ "${1:-}" == --help || "${1:-}" == -h ]]; then
  echo "Usage: sudo ./migrate_vhost_menu.sh"
  echo "Lists WordPress domains on the source and lets you migrate one domain."
  exit 0
fi
[[ $# -eq 0 ]] || { echo "This script accepts no arguments." >&2; exit 2; }
[[ "$EUID" -eq 0 ]] || { echo "Run with sudo." >&2; exit 1; }
[[ -t 0 ]] || { echo "Run from an interactive terminal." >&2; exit 1; }

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
. "$script_dir/vhost_config.sh"
load_vhost_config "$script_dir/.env" || exit 1
. "$script_dir/migration_state.sh"
. "$script_dir/vhost_metadata.sh"

source_host=$MIGRATION_SOURCE_HOST
source_user=$MIGRATION_SOURCE_USER
source_port=$MIGRATION_SOURCE_PORT
ssh_key=$MIGRATION_SSH_KEY
[[ -f "$ssh_key" && -r "$ssh_key" ]] || { echo "SSH key missing or unreadable." >&2; exit 1; }
key_mode=$(stat -c '%a' "$ssh_key")
(( (8#$key_mode & 077) == 0 )) || { echo "SSH key must be mode 600." >&2; exit 1; }
known_hosts=/home/roman/.ssh/known_hosts
[[ -f "$known_hosts" && -r "$known_hosts" ]] || { echo "Trusted known_hosts is required." >&2; exit 1; }
ssh_opts=(-p "$source_port" -i "$ssh_key" -o IdentitiesOnly=yes -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=yes -o "UserKnownHostsFile=$known_hosts")
remote="$source_user@$source_host"
state_dir=/var/lib/nginx-prepare-vhosts/migrations
source_base=/mnt/HC_Volume_6080276/domains
dest_base=$VHOSTS_BASE_DIR
tmp_list=$(mktemp)
trap 'rm -f "$tmp_list"' EXIT

ssh "${ssh_opts[@]}" "$remote" "find '$source_base' -mindepth 3 -maxdepth 3 -type f -path '*/public/wp-config.php' -printf '%h\n'" > "$tmp_list" || { echo "Could not inventory source domains." >&2; exit 1; }
mapfile -t source_domains < <(sed -E "s|^$source_base/([^/]+)/public$|\1|" "$tmp_list" | sort -u)
(("${#source_domains[@]}" > 0)) || { echo "No source WordPress domains found."; exit 0; }

candidates=()
blocked=()
for domain in "${source_domains[@]}"; do
  valid_vhost_domain "$domain" || { blocked+=("(an invalid source hostname was skipped)"); continue; }
  state="$state_dir/$domain.state"
  if [[ -f "$state" && ! -L "$state" ]] && migration_state_has_step "$state" complete; then
    continue
  fi
  dest="$dest_base/$domain"
  vhost="/root/vhosts/$domain.txt"
  if [[ -e "$state" || -L "$state" ]]; then
    candidates+=("$domain|resume")
  elif [[ -e "$dest" || -e "/etc/nginx/conf.d/$domain.conf" || -e "$vhost" ]]; then
    blocked+=("$domain (destination exists, migration state absent; inspect before migrating)")
  else
    candidates+=("$domain|new")
  fi
done

if (("${#blocked[@]}")); then
  echo "Needs manual review:"
  printf '  %s\n' "${blocked[@]}"
fi
if (("${#candidates[@]}" == 0)); then echo "No automatically safe migration candidates."; exit 0; fi
echo "Select one domain to migrate:"
for i in "${!candidates[@]}"; do
  IFS='|' read -r domain status <<< "${candidates[$i]}"
  printf '  %d) %s (%s)\n' "$((i + 1))" "$domain" "$status"
done
read -r -p "Number, or q to quit: " choice
[[ "$choice" != q && "$choice" != Q ]] || exit 0
[[ "$choice" =~ ^[0-9]{1,6}$ ]] || { echo "Invalid selection." >&2; exit 2; }
choice=$((10#$choice))
((choice >= 1 && choice <= ${#candidates[@]})) || { echo "Invalid selection." >&2; exit 2; }
IFS='|' read -r domain status <<< "${candidates[$((choice - 1))]}"
check_vhost_mount "$dest_base" || { echo "Destination volume is not mounted." >&2; exit 1; }
name=

if [[ "$status" == new ]]; then
  default_name=$(derive_vhost_name "$domain")
  read -r -p "Internal SFTP/database name [$default_name]: " name
  name=${name:-$default_name}
  valid_vhost_name "$name" || { echo "Invalid internal name. Use lowercase letters, digits and underscores." >&2; exit 1; }
  bash "$script_dir/prepare_vhost.sh" --domain "$domain" --name "$name" --no-www --yes
  [[ -f "/root/vhosts/$domain.txt" && ! -L "/root/vhosts/$domain.txt" ]] || { echo "Vhost credentials were not created." >&2; exit 1; }
  [[ -f "/etc/php/$PHP_FPM_VERSION/fpm/pool.d/$domain.conf" && ! -L "/etc/php/$PHP_FPM_VERSION/fpm/pool.d/$domain.conf" ]] || { echo "Domain PHP-FPM pool was not created." >&2; exit 1; }
else
  [[ -f "/root/vhosts/$domain.txt" && ! -L "/root/vhosts/$domain.txt" ]] || { echo "Resume state exists but the vhost credentials are missing or unsafe. Inspect the target manually." >&2; exit 1; }
  name=$(get_record_value 'SFTP username' "/root/vhosts/$domain.txt") || { echo "Cannot identify the existing vhost account. Inspect it manually." >&2; exit 1; }
fi

tmpdir=$(mktemp -d "$dest_base/.migration-tmp.XXXXXX")
trap 'rm -f "$tmp_list"; rmdir "$tmpdir" 2>/dev/null || true' EXIT
args=("$domain" --name "$name")
[[ "$status" == resume ]] && args+=(--resume)
TMPDIR="$tmpdir" "$script_dir/migrate_vhost.sh" "${args[@]}"
