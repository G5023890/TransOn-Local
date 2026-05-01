#!/usr/bin/env bash
set -euo pipefail

APP_PATH="${APP_PATH:-/Applications/TransOn Local.app}"
HELPER_PATH="$APP_PATH/Contents/MacOS/TransOnLocalHelper"
RUNTIME_PATH="$APP_PATH/Contents/Resources/Runtime/llama.cpp/build/bin/llama-completion"

missing=0

check_path() {
  local label="$1"
  local path="$2"
  if [[ -e "$path" ]]; then
    echo "OK: $label -> $path"
  else
    echo "MISSING: $label -> $path"
    missing=1
  fi
}

check_executable() {
  local label="$1"
  local path="$2"
  if [[ -x "$path" ]]; then
    echo "OK: $label -> $path"
  else
    echo "MISSING: $label -> $path"
    missing=1
  fi
}

echo "TransOn Local fresh Mac runtime check"
echo
check_path "App" "$APP_PATH"
check_executable "Helper" "$HELPER_PATH"
check_executable "Bundled llama runtime" "$RUNTIME_PATH"

echo
echo "Not required on the target Mac: Xcode, Command Line Tools, Homebrew, git, cmake."
echo "Internet access is required for the first model download."
echo

if [[ "$missing" -eq 0 ]]; then
  echo "Ready. Open TransOn Local and choose Prepare / Update Model."
else
  echo "Install the signed TransOn Local package, then run this check again."
fi

exit "$missing"
