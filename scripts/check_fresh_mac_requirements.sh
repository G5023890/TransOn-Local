#!/usr/bin/env bash
set -euo pipefail

missing=0

check_tool() {
  local tool="$1"
  if command -v "$tool" >/dev/null 2>&1; then
    echo "OK: $tool -> $(command -v "$tool")"
  else
    echo "MISSING: $tool"
    missing=1
  fi
}

echo "TransOn Local fresh Mac requirements"
echo
check_tool git
check_tool cmake
check_tool xcodebuild

if ! xcode-select -p >/dev/null 2>&1; then
  echo "MISSING: Xcode Command Line Tools"
  missing=1
else
  echo "OK: Xcode tools -> $(xcode-select -p)"
fi

echo
if [[ "$missing" -eq 0 ]]; then
  echo "Ready. Open TransOn Local and choose Prepare / Update Model."
else
  echo "Install missing tools before Prepare / Update Model."
  echo "Xcode Command Line Tools: xcode-select --install"
  echo "cmake: install with Homebrew or another trusted package manager."
fi

exit "$missing"
