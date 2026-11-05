#!/usr/bin/env bash
# Small state-file helpers shared by migrate_vhost.sh and safe local checks.

migration_state_init() {
  local state_file=$1 item
  shift
  if [[ -e "$state_file" || -L "$state_file" ]]; then
    [[ -f "$state_file" && ! -L "$state_file" ]] || return 1
    for item in "$@"; do grep -Fxq -- "$item" "$state_file" || return 1; done
    return 0
  fi
  printf '%s\n' "$@" > "$state_file" && chmod 600 "$state_file"
}

migration_state_has_step() {
  local state_file=$1 step=$2
  [[ -f "$state_file" && ! -L "$state_file" ]] && grep -Fxq -- "$step" "$state_file"
}

migration_state_mark_step() {
  local state_file=$1 step=$2 state_dir tmp
  state_dir=$(dirname "$state_file") || return 1
  tmp=$(mktemp "$state_dir/.state.XXXXXX") || return 1
  { [[ -f "$state_file" ]] && cat "$state_file"; printf '%s\n' "$step"; } > "$tmp" || { rm -f "$tmp"; return 1; }
  chmod 600 "$tmp" && mv -f "$tmp" "$state_file" || { rm -f "$tmp"; return 1; }
}
