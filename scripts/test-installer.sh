#!/bin/bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd -P)"
cd "$repo_root"

version=$(/usr/bin/plutil -extract version raw -o - package.json)
package_path=${1:-"$repo_root/release/AppleCalendarMCP-$version.pkg"}
if [ ! -f "$package_path" ]; then
  echo "Installer not found: $package_path" >&2
  echo "Run npm run build:installer first." >&2
  exit 1
fi

test_root=$(/usr/bin/mktemp -d /tmp/apple-calendar-installer-test.XXXXXX)
cleanup() {
  case "$test_root" in
    /tmp/apple-calendar-installer-test.*) /bin/rm -rf "$test_root" ;;
  esac
}
trap cleanup EXIT HUP INT TERM

expanded="$test_root/expanded"
/usr/sbin/pkgutil --expand-full "$package_path" "$expanded"
payload_root="$expanded/Payload/Library/Application Support/AppleCalendarMCP"
bridge="$payload_root/libexec/calendar-bridge"
launcher="$payload_root/bin/apple-calendar-mcp"
register_script="$payload_root/libexec/register-mcp-config"

test -x "$bridge"
test -x "$launcher"
test -x "$register_script"
test -f "$payload_root/dist/index.js"
test -f "$payload_root/package.json"
/usr/bin/grep -Fq '"type": "module"' "$payload_root/package.json"

archs=$(/usr/bin/lipo -archs "$bridge")
[[ " $archs " == *" arm64 "* ]]
[[ " $archs " == *" x86_64 "* ]]
/usr/bin/codesign --verify --strict "$bridge"

test_home="$test_root/home"
/bin/mkdir -p "$test_home/.codex"
printf '%s\n' \
  'model = "gpt-5.6-sol"' \
  '' \
  '[mcp_servers.keep-me]' \
  'command = "keep"' \
  '' \
  '[mcp_servers."apple-calendar"]' \
  'command = "/old/path/node"' \
  'args = ["/old/path/index.js"]' \
  '' \
  '[mcp_servers.after]' \
  'command = "after"' \
  > "$test_home/.codex/config.toml"

APPLE_CALENDAR_MCP_ROOT="$payload_root" \
  /bin/sh "$register_script" "$test_home" "$(/usr/bin/id -un)" "$(/usr/bin/id -gn)"

config_file="$test_home/.codex/config.toml"
/usr/bin/grep -Fq 'model = "gpt-5.6-sol"' "$config_file"
/usr/bin/grep -Fq '[mcp_servers.keep-me]' "$config_file"
/usr/bin/grep -Fq '[mcp_servers.after]' "$config_file"
/usr/bin/grep -Fq "command = \"$payload_root/bin/apple-calendar-mcp\"" "$config_file"
! /usr/bin/grep -Fq '/old/path' "$config_file"
test "$(/usr/bin/grep -c '^\[mcp_servers\.apple-calendar\]$' "$config_file")" -eq 1
test "$(find "$test_home/.codex" -name 'config.toml.backup-*' -type f | wc -l | tr -d ' ')" -eq 1

APPLE_CALENDAR_MCP_ROOT="$payload_root" \
  /bin/sh "$register_script" "$test_home" "$(/usr/bin/id -un)" "$(/usr/bin/id -gn)"
test "$(/usr/bin/grep -c '^\[mcp_servers\.apple-calendar\]$' "$config_file")" -eq 1
test "$(find "$test_home/.codex" -name 'config.toml.backup-*' -type f | wc -l | tr -d ' ')" -eq 2

LAUNCHER="$launcher" node --input-type=module -e '
  import { Client } from "@modelcontextprotocol/sdk/client/index.js";
  import { StdioClientTransport } from "@modelcontextprotocol/sdk/client/stdio.js";
  const transport = new StdioClientTransport({ command: process.env.LAUNCHER });
  const client = new Client({ name: "installer-test", version: "1.0.0" });
  await client.connect(transport);
  const result = await client.listTools();
  const expected = [
    "list_calendars", "list_events", "search_events", "get_event",
    "create_event", "update_event", "delete_event", "find_free_time",
  ];
  const actual = result.tools.map((tool) => tool.name);
  if (JSON.stringify(actual) !== JSON.stringify(expected)) {
    throw new Error(`unexpected tools: ${actual.join(", ")}`);
  }
  await client.close();
'

echo "Installer verification passed: $package_path"
