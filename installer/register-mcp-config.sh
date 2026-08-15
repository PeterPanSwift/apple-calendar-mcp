#!/bin/sh
set -eu

target_home=${1:?"usage: register-mcp-config.sh HOME [OWNER] [GROUP]"}
target_owner=${2:-}
target_group=${3:-}
install_root=${APPLE_CALENDAR_MCP_ROOT:-"/Library/Application Support/AppleCalendarMCP"}
config_dir="$target_home/.codex"
config_file="$config_dir/config.toml"

/bin/mkdir -p "$config_dir"

if [ -f "$config_file" ]; then
  backup_file=$(/usr/bin/mktemp "$config_file.backup-$(/bin/date +%Y%m%d-%H%M%S).XXXXXX")
  /bin/cp -p "$config_file" "$backup_file"
else
  backup_file=""
fi

temp_file=$(/usr/bin/mktemp "$config_dir/config.toml.XXXXXX")
cleanup() {
  [ ! -e "$temp_file" ] || /bin/rm -f "$temp_file"
}
trap cleanup EXIT HUP INT TERM

if [ -f "$config_file" ]; then
  /usr/bin/awk '
    function is_apple_calendar_header(line, compact) {
      compact = line
      gsub(/[[:space:]]/, "", compact)
      return compact ~ /^\[mcp_servers\.apple-calendar(\..*)?\](#.*)?$/ ||
             compact ~ /^\[mcp_servers\."apple-calendar"(\..*)?\](#.*)?$/
    }
    /^[[:space:]]*\[\[?[^]]+\]\]?[[:space:]]*(#.*)?$/ {
      if (is_apple_calendar_header($0)) {
        skipping = 1
        next
      }
      skipping = 0
    }
    !skipping { print }
  ' "$config_file" > "$temp_file"
fi

escaped_root=$(printf '%s' "$install_root" | /usr/bin/sed 's/\\/\\\\/g; s/"/\\"/g')

if [ -s "$temp_file" ]; then
  printf '\n' >> "$temp_file"
fi
printf '%s\n' \
  '[mcp_servers.apple-calendar]' \
  "command = \"$escaped_root/bin/apple-calendar-mcp\"" \
  'enabled = true' \
  'startup_timeout_sec = 15' \
  'tool_timeout_sec = 90' \
  'default_tools_approval_mode = "writes"' \
  >> "$temp_file"

/bin/chmod 600 "$temp_file"
/bin/mv -f "$temp_file" "$config_file"
trap - EXIT HUP INT TERM

if [ -n "$target_owner" ] && [ -n "$target_group" ]; then
  /usr/sbin/chown "$target_owner:$target_group" "$config_dir" "$config_file"
  if [ -n "$backup_file" ]; then
    /usr/sbin/chown "$target_owner:$target_group" "$backup_file"
  fi
fi

printf 'Registered apple-calendar MCP in %s\n' "$config_file"
if [ -n "$backup_file" ]; then
  printf 'Backup: %s\n' "$backup_file"
fi
