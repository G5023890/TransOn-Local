#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"

APP_DISPLAY_NAME="${APP_DISPLAY_NAME:-TransOn Local}"
EXECUTABLE_NAME="${EXECUTABLE_NAME:-TransOn Local}"
BUNDLE_ID="${BUNDLE_ID:-com.grigorym.TransOnLocal}"
APP_DIR="${APP_DIR:-dist/${APP_DISPLAY_NAME}.app}"
INSTALL_DIR="${INSTALL_DIR:-/Applications/${APP_DISPLAY_NAME}.app}"
LEGACY_INSTALL_DIR="${LEGACY_INSTALL_DIR:-/Applications/SelectedTextOverlay.app}"
ICON_SOURCE="${ICON_SOURCE:-}"
SKIP_SIGN="${SKIP_SIGN:-0}"
SIGN_IDENTITY="${SIGN_IDENTITY:-}"
CONFIGURATION="${CONFIGURATION:-Release}"
DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-Build/InstallDerivedData}"
RESOLVED_SIGN_IDENTITY=""

log() {
  echo "[build] $*"
}

pick_icon_source() {
  if [[ -n "$ICON_SOURCE" && -f "$ICON_SOURCE" ]]; then
    echo "$ICON_SOURCE"
    return 0
  fi

  local candidates=(
    "$PROJECT_DIR/AppIcon.icns"
    "$PROJECT_DIR/assets/AppIcon.icns"
    "$PROJECT_DIR/Assets/AppIcon.icns"
    "$PROJECT_DIR/Resources/AppIcon.icns"
    "$PROJECT_DIR/dist/AppIcon.icns"
    "/Applications/${APP_DISPLAY_NAME}.app/Contents/Resources/AppIcon.icns"
    "$LEGACY_INSTALL_DIR/Contents/Resources/AppIcon.icns"
  )

  local candidate
  for candidate in "${candidates[@]}"; do
    if [[ -f "$candidate" ]]; then
      echo "$candidate"
      return 0
    fi
  done

  return 1
}

sign_bundle_if_needed() {
  local bundle="$1"

  if [[ "$SKIP_SIGN" == "1" ]]; then
    log "Skipping codesign (SKIP_SIGN=1)"
    return 0
  fi

  if [[ -n "$RESOLVED_SIGN_IDENTITY" ]]; then
    log "Signing with identity: $RESOLVED_SIGN_IDENTITY"
    codesign --force --deep --options runtime --sign "$RESOLVED_SIGN_IDENTITY" "$bundle"
  else
    log "No Apple Development identity found; using ad-hoc signature"
    codesign --force --deep --sign - "$bundle"
  fi

  codesign --verify --deep --strict "$bundle"
}

resolve_sign_identity() {
  if [[ "$SKIP_SIGN" == "1" ]]; then
    return 0
  fi

  if [[ -n "$SIGN_IDENTITY" ]]; then
    RESOLVED_SIGN_IDENTITY="$SIGN_IDENTITY"
    return 0
  fi

  if [[ -d "$INSTALL_DIR" ]]; then
    local existing existing_info
    existing_info="$(codesign -dv --verbose=4 "$INSTALL_DIR" 2>&1 || true)"
    existing="$(printf '%s\n' "$existing_info" | awk -F= '/^Authority=Apple Development: /{print $2}' | sed -n '1p')"
    if [[ -n "$existing" ]]; then
      RESOLVED_SIGN_IDENTITY="$existing"
      return 0
    fi
  fi

  local identities_output first_available
  identities_output="$(security find-identity -v -p codesigning 2>/dev/null || true)"
  first_available="$(printf '%s\n' "$identities_output" | awk -F '"' '/Apple Development: /{print $2; exit}')"
  if [[ -n "$first_available" ]]; then
    RESOLVED_SIGN_IDENTITY="$first_available"
  fi
}

if command -v xcodegen >/dev/null 2>&1; then
  log "Generating Xcode project"
  xcodegen generate
fi

if [[ ! -d "TransOnLocal.xcodeproj" ]]; then
  echo "Missing TransOnLocal.xcodeproj. Install xcodegen or generate the project first." >&2
  exit 1
fi

log "Building ${APP_DISPLAY_NAME} (${CONFIGURATION})"
xcodebuild \
  -project TransOnLocal.xcodeproj \
  -scheme "$APP_DISPLAY_NAME" \
  -configuration "$CONFIGURATION" \
  -destination "generic/platform=macOS" \
  -derivedDataPath "$DERIVED_DATA_PATH" \
  build

BUILT_APP="$DERIVED_DATA_PATH/Build/Products/${CONFIGURATION}/${APP_DISPLAY_NAME}.app"
if [[ ! -d "$BUILT_APP" ]]; then
  echo "Built app not found: $BUILT_APP" >&2
  exit 1
fi

BUILT_HELPER="$DERIVED_DATA_PATH/Build/Products/${CONFIGURATION}/TransOnLocalHelper"
HELPER_PATH="$BUILT_APP/Contents/MacOS/TransOnLocalHelper"
if [[ -x "$BUILT_HELPER" ]]; then
  mkdir -p "$(dirname "$HELPER_PATH")"
  /usr/bin/ditto --norsrc "$BUILT_HELPER" "$HELPER_PATH"
  chmod +x "$HELPER_PATH"
fi

if [[ ! -x "$HELPER_PATH" ]]; then
  echo "Embedded helper not found: $HELPER_PATH" >&2
  exit 1
fi

BUNDLED_RUNTIME_SOURCE="${BUNDLED_RUNTIME_SOURCE:-Build/BundledRuntime}"
RUNTIME_DEST="$BUILT_APP/Contents/Resources/Runtime"
if [[ -d "$BUNDLED_RUNTIME_SOURCE/llama.cpp/build/bin" ]]; then
  rm -rf "$RUNTIME_DEST"
  mkdir -p "$(dirname "$RUNTIME_DEST")"
  /usr/bin/ditto --norsrc "$BUNDLED_RUNTIME_SOURCE" "$RUNTIME_DEST"
  find "$RUNTIME_DEST/llama.cpp/build/bin" -type f -perm +111 -exec chmod +x {} \; 2>/dev/null || true
fi

xattr -c "$BUILT_APP" 2>/dev/null || true
xattr -cr "$BUILT_APP" 2>/dev/null || true

resolve_sign_identity
if [[ -n "$RESOLVED_SIGN_IDENTITY" ]]; then
  log "Resolved signing identity: $RESOLVED_SIGN_IDENTITY"
fi

mkdir -p "$(dirname "$APP_DIR")"
rm -rf "$APP_DIR"
/usr/bin/ditto --norsrc "$BUILT_APP" "$APP_DIR"
sign_bundle_if_needed "$APP_DIR"

rm -rf "$INSTALL_DIR"
/usr/bin/ditto --norsrc "$APP_DIR" "$INSTALL_DIR"
if [[ "$LEGACY_INSTALL_DIR" != "$INSTALL_DIR" ]]; then
  rm -rf "$LEGACY_INSTALL_DIR"
fi

xattr -cr "$INSTALL_DIR" || true
sign_bundle_if_needed "$INSTALL_DIR"

log "Built: $APP_DIR"
log "Installed: $INSTALL_DIR"
