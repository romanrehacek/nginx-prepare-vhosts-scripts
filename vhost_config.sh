#!/bin/bash
# Shared configuration loader for the vhost scripts.
# The .env file is parsed as data; it is never evaluated or sourced.

load_vhost_config() {
    local config_file="$1"
    local line key value line_number=0
    local seen_php=false
    local seen_base=false

    PHP_FPM_VERSION="8.3"
    VHOSTS_BASE_DIR="/var/www"

    if [[ ! -e "$config_file" ]]; then
        return 0
    fi

    if [[ ! -f "$config_file" || ! -r "$config_file" ]]; then
        echo "[!] ERROR: Configuration file must be a readable regular file: $config_file" >&2
        return 1
    fi

    while IFS= read -r line || [[ -n "$line" ]]; do
        line_number=$((line_number + 1))
        line="${line%$'\r'}"

        [[ "$line" =~ ^[[:space:]]*$ ]] && continue
        [[ "$line" =~ ^[[:space:]]*# ]] && continue

        if [[ ! "$line" =~ ^[[:space:]]*([A-Z_]+)[[:space:]]*=[[:space:]]*([^[:space:]]+)[[:space:]]*$ ]]; then
            echo "[!] ERROR: Invalid .env syntax at $config_file:$line_number" >&2
            echo "    Use KEY=VALUE without quotes, spaces in values, or inline comments." >&2
            return 1
        fi

        key="${BASH_REMATCH[1]}"
        value="${BASH_REMATCH[2]}"

        case "$key" in
            PHP_FPM_VERSION)
                if [[ "$seen_php" == true ]]; then
                    echo "[!] ERROR: Duplicate PHP_FPM_VERSION at $config_file:$line_number" >&2
                    return 1
                fi
                PHP_FPM_VERSION="$value"
                seen_php=true
                ;;
            VHOSTS_BASE_DIR)
                if [[ "$seen_base" == true ]]; then
                    echo "[!] ERROR: Duplicate VHOSTS_BASE_DIR at $config_file:$line_number" >&2
                    return 1
                fi
                VHOSTS_BASE_DIR="$value"
                seen_base=true
                ;;
            *)
                echo "[!] ERROR: Unsupported setting '$key' at $config_file:$line_number" >&2
                return 1
                ;;
        esac
    done < "$config_file"

    if [[ ! "$PHP_FPM_VERSION" =~ ^[0-9]+[.][0-9]+$ ]]; then
        echo "[!] ERROR: PHP_FPM_VERSION must look like 8.3 (got '$PHP_FPM_VERSION')" >&2
        return 1
    fi

    while [[ "$VHOSTS_BASE_DIR" != "/" && "$VHOSTS_BASE_DIR" == */ ]]; do
        VHOSTS_BASE_DIR="${VHOSTS_BASE_DIR%/}"
    done

    if [[ "$VHOSTS_BASE_DIR" == "/" || ! "$VHOSTS_BASE_DIR" =~ ^/[A-Za-z0-9._/-]+$ ]]; then
        echo "[!] ERROR: VHOSTS_BASE_DIR must be a safe absolute path (got '$VHOSTS_BASE_DIR')" >&2
        return 1
    fi

    case "$VHOSTS_BASE_DIR" in
        *'//'*)
            echo "[!] ERROR: VHOSTS_BASE_DIR must not contain empty path segments" >&2
            return 1
            ;;
    esac

    case "/$VHOSTS_BASE_DIR/" in
        *'/../'*|*'/./'*)
            echo "[!] ERROR: VHOSTS_BASE_DIR must not contain '.' or '..' path segments" >&2
            return 1
            ;;
    esac

    return 0
}
