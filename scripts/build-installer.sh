#!/bin/bash
set -euo pipefail
export COPYFILE_DISABLE=1

repo_root="$(cd "$(dirname "$0")/.." && pwd -P)"
cd "$repo_root"

version=$(/usr/bin/plutil -extract version raw -o - package.json)
release_dir="$repo_root/release"
output_pkg="$release_dir/AppleCalendarMCP-$version.pkg"
work_dir=$(/usr/bin/mktemp -d /tmp/apple-calendar-installer.XXXXXX)

cleanup() {
  case "$work_dir" in
    /tmp/apple-calendar-installer.*) /bin/rm -rf "$work_dir" ;;
  esac
}
trap cleanup EXIT HUP INT TERM

payload_root="$work_dir/payload"
package_scripts="$work_dir/package-scripts"
install_root="$payload_root/Library/Application Support/AppleCalendarMCP"

/bin/mkdir -p \
  "$install_root/bin" \
  "$install_root/dist" \
  "$install_root/libexec" \
  "$install_root/share" \
  "$package_scripts" \
  "$release_dir"

if [ ! -x node_modules/.bin/esbuild ]; then
  echo "esbuild is missing. Run npm install first." >&2
  exit 1
fi

node_modules/.bin/esbuild src/index.ts \
  --bundle \
  --platform=node \
  --format=esm \
  --target=node18 \
  --outfile="$install_root/dist/index.js" \
  --banner:js='import { createRequire as __cr } from "node:module";
import { fileURLToPath as __f2p } from "node:url";
import { dirname as __dn } from "node:path";
const require = __cr(import.meta.url);
const __filename = __f2p(import.meta.url);
const __dirname = __dn(__filename);'

for arch in arm64 x86_64; do
  /usr/bin/xcrun swiftc \
    -O \
    -target "$arch-apple-macos13.0" \
    -framework EventKit \
    -framework Foundation \
    -Xlinker -sectcreate \
    -Xlinker __TEXT \
    -Xlinker __info_plist \
    -Xlinker src/swift/Info.plist \
    -o "$work_dir/calendar-bridge-$arch" \
    src/swift/main.swift
done

/usr/bin/lipo -create \
  "$work_dir/calendar-bridge-arm64" \
  "$work_dir/calendar-bridge-x86_64" \
  -output "$install_root/libexec/calendar-bridge"
/usr/bin/codesign --force --sign - "$install_root/libexec/calendar-bridge"

/usr/bin/ditto --norsrc installer/apple-calendar-mcp "$install_root/bin/apple-calendar-mcp"
/usr/bin/ditto --norsrc installer/register-mcp-config.sh "$install_root/libexec/register-mcp-config"
/usr/bin/ditto --norsrc README.md "$install_root/share/README.md"
/usr/bin/ditto --norsrc INSTALL-CHATGPT.md "$install_root/share/INSTALL-CHATGPT.md"
/usr/bin/ditto --norsrc installer/runtime-package.json "$install_root/package.json"
/usr/bin/ditto --norsrc installer/postinstall "$package_scripts/postinstall"
/bin/chmod 755 \
  "$install_root/bin/apple-calendar-mcp" \
  "$install_root/libexec/calendar-bridge" \
  "$install_root/libexec/register-mcp-config" \
  "$package_scripts/postinstall"

unsigned_pkg="$work_dir/AppleCalendarMCP-unsigned.pkg"
/usr/bin/pkgbuild \
  --root "$payload_root" \
  --scripts "$package_scripts" \
  --identifier tw.shihyingpan.apple-calendar-mcp \
  --version "$version" \
  --install-location / \
  --ownership recommended \
  "$unsigned_pkg"

if [ -n "${INSTALLER_SIGN_IDENTITY:-}" ]; then
  /usr/bin/productsign --sign "$INSTALLER_SIGN_IDENTITY" "$unsigned_pkg" "$output_pkg"
else
  /bin/cp "$unsigned_pkg" "$output_pkg"
fi

echo "Built $output_pkg"
