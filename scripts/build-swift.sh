#!/bin/bash
# Builds the EventKit bridge binary.
#
# The Info.plist is linked into the binary's __TEXT,__info_plist section because
# macOS refuses to hand calendar access to a process without a usage description,
# and a bare command-line tool has nowhere else to put one. Ad-hoc signing keeps
# the TCC grant stable across rebuilds of an unchanged binary.
set -euo pipefail

cd "$(dirname "$0")/.."
mkdir -p bin

swiftc \
  -O \
  -target "$(uname -m)-apple-macos13.0" \
  -framework EventKit \
  -framework Foundation \
  -Xlinker -sectcreate \
  -Xlinker __TEXT \
  -Xlinker __info_plist \
  -Xlinker src/swift/Info.plist \
  -o bin/calendar-bridge \
  src/swift/main.swift

codesign --force --sign - bin/calendar-bridge

echo "built bin/calendar-bridge"
