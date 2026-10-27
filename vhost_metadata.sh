#!/bin/bash
# Root-owned domain-to-system-name mapping. The file contains identifiers only.
VHOST_NAME_MAP=/root/vhosts/.vhost-name-map

lowercase() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

valid_vhost_name() {
  [[ "$1" =~ ^[a-z][a-z0-9_]{0,31}$ ]]
}

assert_mapped_name() {
  local recorded="$1" supplied="$2" supplied_set="$3"
  [[ "$supplied_set" == false ]] && return 0
  valid_vhost_name "$supplied" || { echo "Error: identifier must match ^[a-z][a-z0-9_]{0,31}$" >&2; return 1; }
  [[ "$supplied" == "$recorded" ]] || { echo "[!] ERROR: --name does not match the recorded identifier." >&2; return 1; }
}

valid_vhost_domain() {
  [[ ${#1} -le 253 && "$1" =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?[.])*[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?$ ]]
}

certbot_lineage_conflicts() {
  local listing="$1" wanted="$2"
  awk -v wanted="$wanted" '
    /^[[:space:]]*Certificate Name:/ {
      name=$0; sub(/^[[:space:]]*Certificate Name:[[:space:]]*/, "", name)
      if (tolower(name) == tolower(wanted)) collision=1
      next
    }
    /^[[:space:]]*Domains:/ {
      sub(/^[[:space:]]*Domains:[[:space:]]*/, "")
      n=split($0, domains, /[[:space:]]+/)
      for (i=1; i<=n; i++) if (tolower(domains[i]) == tolower(wanted) || tolower(domains[i]) == "www." tolower(wanted)) collision=1
    }
    END { exit !collision }
  ' <<< "$listing"
}

certbot_domains_for_lineage() {
  local listing="$1" wanted="$2"
  awk -v wanted="$wanted" '
    /^[[:space:]]*Certificate Name:/ {
      name=$0; sub(/^[[:space:]]*Certificate Name:[[:space:]]*/, "", name)
      active=(tolower(name) == tolower(wanted)); next
    }
    active && /^[[:space:]]*Domains:/ { sub(/^[[:space:]]*Domains:[[:space:]]*/, ""); print; exit }
  ' <<< "$listing"
}

private_group_is_owned_by_user() {
  local username="$1" primary_gid="$2" group_record="$3" passwd_file="${4:-/etc/passwd}"
  local group_name group_pass group_gid members member other_primary
  IFS=: read -r group_name group_pass group_gid members <<< "$group_record"
  [[ "$group_name" == "$username" && "$group_gid" == "$primary_gid" ]] || return 1
  other_primary=$(awk -F: -v gid="$primary_gid" -v user="$username" '$4 == gid && $1 != user { print $1 }' "$passwd_file") || return 1
  [[ -z "$other_primary" ]] || return 1
  IFS=, read -r -a group_members <<< "$members"
  for member in "${group_members[@]}"; do [[ -z "$member" || "$member" == "$username" ]] || return 1; done
}

valid_vhost_base_dir() {
  local base="$1"
  [[ "$base" == /* && "$base" != / && "$base" =~ ^/[A-Za-z0-9._/-]+$ && "$base" != *//* ]] || return 1
  case "/$base/" in *'/../'*|*'/./'*) return 1;; esac
}

check_vhost_mount() {
  local base="$1" mount_path resolved
  [[ -d "$base" ]] || { echo "Configured domain base directory is missing; mount/create it first: $base" >&2; return 1; }
  resolved=$(realpath "$base") || return 1
  [[ "$resolved" == "$base" ]] || { echo "Configured domain base path contains a symlink: $base" >&2; return 1; }
  [[ "$base" == /var/www ]] && return 0
  mount_path=$(dirname "$base")
  command -v mountpoint >/dev/null || { echo "mountpoint is required to verify the configured volume" >&2; return 1; }
  mountpoint -q "$mount_path" || { echo "[!] ERROR: Volume is not mounted: $mount_path" >&2; return 1; }
}

require_confirmation_mode() {
  local yes="$1" tty="$2"
  [[ "$yes" == true || "$tty" == true ]] || { echo "Non-interactive provisioning requires --yes after all preflight checks." >&2; return 1; }
}

confirm_provisioning() {
  local domain="$1" name="$2" explicit_name="$3" skip_ssl="$4" base="$5" answer rerun
  echo "VHOST CONFIGURATION"
  echo "  Domain: $domain"
  echo "  Name: $name"
  echo "  Linux user: $name"
  echo "  Database: $name"
  echo "  Database user: $name"
  echo "  Webroot: $base/$domain/public_html"
  echo "  SSL: $([[ "$skip_ssl" == true ]] && echo skipped || echo requested)"
  if [[ "$explicit_name" == false ]]; then
    rerun="sudo ./prepare_vhost.sh --domain '$domain' --name '$name'"
    [[ "$skip_ssl" == true ]] && rerun+=" --skip-ssl"
    rerun+=" --yes"
    echo "  Identifier is derived. To choose a different name, use --name IDENTIFIER."
    echo "  Rerun command: $rerun"
  fi
  while :; do
    read -r -p "Continue? [Y/n] " answer || { echo "Provisioning cancelled."; return 1; }
    case "$answer" in ''|y|Y) return 0;; n|N) echo "Provisioning cancelled."; return 1;; *) echo "Enter Y or N." >&2;; esac
  done
}

derive_vhost_name() {
  local domain="$1" normalized base suffix max_base
  normalized=$(printf '%s' "$domain" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/_/g; s/^_+//; s/_+$//')
  base=$normalized
  if [[ "$base" =~ ^[0-9] ]]; then base="v$base"; fi
  if ((${#base} <= 32)); then printf '%s' "$base"; return 0; fi
  suffix=$(lowercase "$domain" | sha256sum | cut -c1-8)
  max_base=23
  [[ "$base" =~ ^[0-9] ]] && max_base=22
  base=${base:0:max_base}
  base=${base%_}
  printf '%s_%s' "$base" "$suffix"
}

validate_name_map() {
  local file="$1" mode owner parent parent_mode parent_owner
  [[ -f "$file" && ! -L "$file" ]] || { echo "[!] ERROR: Name mapping is missing or not a regular file: $file" >&2; return 1; }
  parent=$(dirname "$file")
  [[ -d "$parent" && ! -L "$parent" ]] || { echo "[!] ERROR: Name mapping directory is unsafe: $parent" >&2; return 1; }
  parent_owner=$(stat -c '%u' "$parent") || return 1
  parent_mode=$(stat -c '%a' "$parent") || return 1
  [[ "$parent_owner" == 0 && $((8#$parent_mode & 077)) -eq 0 ]] || { echo "[!] ERROR: Name mapping directory must be root-owned and private: $parent" >&2; return 1; }
  owner=$(stat -c '%u' "$file") || return 1
  mode=$(stat -c '%a' "$file") || return 1
  [[ "$owner" == 0 && "$mode" =~ ^[0-7]+$ && $((8#$mode & 077)) -eq 0 ]] || { echo "[!] ERROR: Name mapping must be root-owned and not group/world writable: $file" >&2; return 1; }
  validate_name_map_contents "$file"
}

validate_name_map_contents() {
  local file="$1" domain domain_lc name db cert base ssl extra seen_domains='|' seen_names='|'
  while IFS=$'\t' read -r domain name db cert base ssl extra || [[ -n "$domain$name$db$cert$base$ssl$extra" ]]; do
    [[ -n "$domain" && -z "$extra" && "$domain" =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?[.])*[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?$ && ${#domain} -le 253 ]] || { echo "[!] ERROR: Corrupt name mapping: $file" >&2; return 1; }
    valid_vhost_name "$name" && [[ "$db" == "$name" ]] && valid_vhost_base_dir "$base" || { echo "[!] ERROR: Corrupt name mapping: $file" >&2; return 1; }
    [[ ("$ssl" == true && "$cert" == "$domain") || ("$ssl" == false && "$cert" == -) ]] || { echo "[!] ERROR: Corrupt name mapping: $file" >&2; return 1; }
    domain_lc=$(lowercase "$domain")
    [[ "$seen_domains" != *"|$domain_lc|"* && "$seen_names" != *"|$name|"* ]] || { echo "[!] ERROR: Duplicate domain or identifier in name mapping: $file" >&2; return 1; }
    seen_domains+="$domain_lc|"
    seen_names+="$name|"
  done < "$file"
}

mapped_name_for_domain() {
  local domain="$1" domain_lc file="$2" d n db cert base ssl
  domain_lc=$(lowercase "$domain")
  while IFS=$'\t' read -r d n db cert base ssl; do
    if [[ "$(lowercase "$d")" == "$domain_lc" ]]; then printf '%s' "$n"; return 0; fi
  done < "$file"
  return 1
}

map_contains_name() {
  local name="$1" file="$2" d n db cert base ssl
  while IFS=$'\t' read -r d n db cert base ssl; do [[ "$n" == "$name" ]] && return 0; done < "$file"
  return 1
}

write_name_mapping() {
  local domain="$1" name="$2" db="$3" cert="$4" base="$5" ssl="$6" file="$7" tmp
  mkdir -p "$(dirname "$file")" || return 1
  if [[ -e "$file" || -L "$file" ]]; then
    validate_name_map "$file" || return 1
    [[ -z "$(mapped_name_for_domain "$domain" "$file" || true)" ]] && ! map_contains_name "$name" "$file" || { echo "[!] ERROR: Domain or identifier was mapped during provisioning." >&2; return 1; }
  fi
  tmp=$(mktemp "$(dirname "$file")/.vhost-name-map.XXXXXX") || return 1
  if [[ -f "$file" ]]; then cat "$file" > "$tmp" || { rm -f "$tmp"; return 1; }; fi
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$domain" "$name" "$db" "$cert" "$base" "$ssl" >> "$tmp" || { rm -f "$tmp"; return 1; }
  chown 0:0 "$tmp" && chmod 600 "$tmp" && mv -f "$tmp" "$file" || { rm -f "$tmp"; return 1; }
}

remove_name_mapping() {
  local domain="$1" domain_lc file="$2" tmp d n rest
  domain_lc=$(lowercase "$domain")
  validate_name_map "$file" || return 1
  tmp=$(mktemp "$(dirname "$file")/.vhost-name-map.XXXXXX") || return 1
  while IFS=$'\t' read -r d n rest; do [[ "$(lowercase "$d")" == "$domain_lc" ]] || printf '%s\t%s\n' "$d" "$n${rest:+$'\t'$rest}" >> "$tmp"; done < "$file"
  chown 0:0 "$tmp" && chmod 600 "$tmp" && mv -f "$tmp" "$file" || { rm -f "$tmp"; return 1; }
}
