#!/usr/bin/env bash
set -euo pipefail
export COPYFILE_DISABLE=1

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"

APP_NAME="${APP_NAME:-TransOn Local}"
BUNDLE_ID="${BUNDLE_ID:-com.grigorym.TransOnLocal}"
PKG_ID="${PKG_ID:-com.grigorym.TransOnLocal.pkg}"
VERSION="${VERSION:-0.1.0}"
CONFIGURATION="${CONFIGURATION:-Release}"
DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-Build/PackageDerivedData}"
DIST_DIR="${DIST_DIR:-dist}"
PACKAGE_ROOT="$DIST_DIR/pkgroot"
MANUAL_PKG_ROOT="$DIST_DIR/manual-component"
COMPONENT_PKG="$DIST_DIR/${APP_NAME}-${VERSION}-component.pkg"
FINAL_PKG="$DIST_DIR/${APP_NAME}-${VERSION}-Installer.pkg"
README_PATH="$DIST_DIR/${APP_NAME}-${VERSION}-First-Run.txt"
SIGN_IDENTITY="${SIGN_IDENTITY:-}"

log() {
  echo "[package] $*"
}

if command -v xcodegen >/dev/null 2>&1; then
  log "Generating Xcode project"
  xcodegen generate
fi

log "Building universal app"
xcodebuild \
  -project TransOnLocal.xcodeproj \
  -scheme "$APP_NAME" \
  -configuration "$CONFIGURATION" \
  -destination "generic/platform=macOS" \
  -derivedDataPath "$DERIVED_DATA_PATH" \
  build

BUILT_APP="$DERIVED_DATA_PATH/Build/Products/${CONFIGURATION}/${APP_NAME}.app"
if [[ ! -d "$BUILT_APP" ]]; then
  echo "Built app not found: $BUILT_APP" >&2
  exit 1
fi

if ! lipo -info "$BUILT_APP/Contents/MacOS/$APP_NAME" | grep -q "x86_64"; then
  echo "Built app is not universal; expected x86_64 slice." >&2
  exit 1
fi

if ! lipo -info "$BUILT_APP/Contents/MacOS/TransOnLocalHelper" | grep -q "x86_64"; then
  echo "Embedded helper is not universal; expected x86_64 slice." >&2
  exit 1
fi

rm -rf "$PACKAGE_ROOT" "$MANUAL_PKG_ROOT" "$COMPONENT_PKG" "$FINAL_PKG"
mkdir -p "$PACKAGE_ROOT" "$DIST_DIR"
/usr/bin/ditto --norsrc --noextattr --noqtn --noacl "$BUILT_APP" "$PACKAGE_ROOT/${APP_NAME}.app"
xattr -cr "$PACKAGE_ROOT/${APP_NAME}.app" 2>/dev/null || true
find "$PACKAGE_ROOT" \( -name ".DS_Store" -o -name "._*" \) -delete

cat > "$README_PATH" <<README
TransOn Local first run

Installed app:
  /Applications/TransOn Local.app

On a fresh Mac:
  1. Open TransOn Local from /Applications.
  2. In the menu bar, choose Prepare / Update Model.
  3. The app will build llama.cpp and download the selected GGUF model.

Required before Prepare / Update Model:
  - Xcode Command Line Tools
  - git
  - cmake
  - internet access for the first model download

Recommended model for Intel Macs:
  - Q4_K_M or Q5_K_M

Q8_0 is available, but it is heavy and can exceed memory limits on Intel Macs or low-memory Apple Silicon Macs.
Runtime data is stored in:
  ~/Library/Application Support/com.grigorym.TransOnLocal/
README

log "Building clean component package"
mkdir -p "$MANUAL_PKG_ROOT"
INSTALL_KBYTES="$(du -sk "$PACKAGE_ROOT" | awk '{print $1}')"
NUMBER_OF_FILES="$(find "$PACKAGE_ROOT" -mindepth 1 | wc -l | tr -d ' ')"
APP_PLIST="$PACKAGE_ROOT/${APP_NAME}.app/Contents/Info.plist"
BUNDLE_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP_PLIST" 2>/dev/null || echo "$VERSION")"
SHORT_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_PLIST" 2>/dev/null || echo "$VERSION")"

/usr/bin/mkbom "$PACKAGE_ROOT" "$MANUAL_PKG_ROOT/Bom"
COPYFILE_DISABLE=1 /usr/bin/ditto \
  -c -z \
  --norsrc --noextattr --noqtn --noacl \
  "$PACKAGE_ROOT" \
  "$MANUAL_PKG_ROOT/Payload"

cat > "$MANUAL_PKG_ROOT/PackageInfo" <<PACKAGEINFO
<?xml version="1.0" encoding="utf-8"?>
<pkg-info format-version="2" identifier="$PKG_ID" version="$VERSION" install-location="/Applications" auth="root" overwrite-permissions="true" relocatable="false">
  <payload installKBytes="$INSTALL_KBYTES" numberOfFiles="$NUMBER_OF_FILES"/>
  <bundle path="./$APP_NAME.app" id="$BUNDLE_ID" CFBundleShortVersionString="$SHORT_VERSION" CFBundleVersion="$BUNDLE_VERSION"/>
  <bundle-version>
    <bundle id="$BUNDLE_ID"/>
  </bundle-version>
  <upgrade-bundle>
    <bundle id="$BUNDLE_ID"/>
  </upgrade-bundle>
</pkg-info>
PACKAGEINFO

(
  cd "$MANUAL_PKG_ROOT"
  /usr/bin/xar --compression none -cf "$PROJECT_DIR/$COMPONENT_PKG" Bom PackageInfo Payload
)

SIGN_ARGS=()
if [[ -n "$SIGN_IDENTITY" ]]; then
  SIGN_ARGS=(--sign "$SIGN_IDENTITY")
else
  INSTALLER_IDENTITY="$(security find-identity -v -p basic 2>/dev/null | awk -F '"' '/Developer ID Installer: /{print $2; exit}')"
  if [[ -n "$INSTALLER_IDENTITY" ]]; then
    SIGN_ARGS=(--sign "$INSTALLER_IDENTITY")
  fi
fi

if [[ "${#SIGN_ARGS[@]}" -gt 0 ]]; then
  log "Building signed installer package"
  COPYFILE_DISABLE=1 productbuild "${SIGN_ARGS[@]}" --package "$COMPONENT_PKG" "$FINAL_PKG"
else
  log "Building unsigned installer package"
  COPYFILE_DISABLE=1 productbuild --package "$COMPONENT_PKG" "$FINAL_PKG"
fi

pkgutil --check-signature "$FINAL_PKG" || true
pkgutil --payload-files "$FINAL_PKG" | sed -n '1,40p'

log "Installer: $FINAL_PKG"
log "Readme: $README_PATH"
