#!/usr/bin/env bash
set -euo pipefail
export COPYFILE_DISABLE=1
export COPY_EXTENDED_ATTRIBUTES_DISABLE=1

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"

APP_NAME="${APP_NAME:-TransOn Local}"
BUNDLE_ID="${BUNDLE_ID:-com.grigorym.TransOnLocal}"
PKG_ID="${PKG_ID:-com.grigorym.TransOnLocal.pkg}"
VERSION="${VERSION:-0.1.5}"
CONFIGURATION="${CONFIGURATION:-Release}"
DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-Build/PackageDerivedData}"
DIST_DIR="${DIST_DIR:-dist}"
PACKAGE_ROOT="$DIST_DIR/pkgroot"
COMPONENT_PKG="$DIST_DIR/${APP_NAME}-${VERSION}-component.pkg"
FINAL_PKG="$DIST_DIR/${APP_NAME}-${VERSION}-Installer.pkg"
README_PATH="$DIST_DIR/${APP_NAME}-${VERSION}-First-Run.txt"

LLAMA_SOURCE_DIR="${LLAMA_SOURCE_DIR:-$HOME/Library/Application Support/com.grigorym.TransOnLocal/llama.cpp}"
LLAMA_FALLBACK_SOURCE_DIR="${LLAMA_FALLBACK_SOURCE_DIR:-Build/llama.cpp-source}"
LLAMA_BUILD_DIR="${LLAMA_BUILD_DIR:-Build/LlamaRuntimeUniversal}"
LLAMA_ARCHS="${LLAMA_ARCHS:-arm64;x86_64}"
LLAMA_DEPLOYMENT_TARGET="${LLAMA_DEPLOYMENT_TARGET:-26.0}"
RUNTIME_STAGING_DIR="${RUNTIME_STAGING_DIR:-Build/BundledRuntime}"
RUNTIME_APP_DIR="Contents/Resources/Runtime/llama.cpp/build/bin"

APP_SIGN_IDENTITY="${APP_SIGN_IDENTITY:-}"
PKG_SIGN_IDENTITY="${PKG_SIGN_IDENTITY:-}"
NOTARY_PROFILE="${NOTARY_PROFILE:-transon-notary}"
SKIP_NOTARIZATION="${SKIP_NOTARIZATION:-0}"
DEVELOPMENT_TEAM="${DEVELOPMENT_TEAM:-}"

log() {
  echo "[package] $*"
}

find_identity() {
  local pattern="$1"
  security find-identity -v -p basic 2>/dev/null | awk -F '"' -v pattern="$pattern" '$0 ~ pattern {print $2; exit}'
}

resolve_signing() {
  if [[ -z "$APP_SIGN_IDENTITY" ]]; then
    APP_SIGN_IDENTITY="$(find_identity "Developer ID Application:")"
  fi
  if [[ -z "$PKG_SIGN_IDENTITY" ]]; then
    PKG_SIGN_IDENTITY="$(find_identity "Developer ID Installer:")"
  fi

  if [[ -z "$APP_SIGN_IDENTITY" ]]; then
    echo "Missing Developer ID Application signing identity." >&2
    echo "Set APP_SIGN_IDENTITY=\"Developer ID Application: ...\" after installing the certificate." >&2
    exit 1
  fi
  if [[ -z "$PKG_SIGN_IDENTITY" ]]; then
    echo "Missing Developer ID Installer signing identity." >&2
    echo "Set PKG_SIGN_IDENTITY=\"Developer ID Installer: ...\" after installing the certificate." >&2
    exit 1
  fi

  if [[ -z "$DEVELOPMENT_TEAM" && "$APP_SIGN_IDENTITY" =~ \(([A-Z0-9]+)\)$ ]]; then
    DEVELOPMENT_TEAM="${BASH_REMATCH[1]}"
  fi
}

resolve_llama_source_dir() {
  if [[ -d "$LLAMA_SOURCE_DIR" ]]; then
    return 0
  fi

  if [[ -d "$LLAMA_FALLBACK_SOURCE_DIR" ]]; then
    LLAMA_SOURCE_DIR="$LLAMA_FALLBACK_SOURCE_DIR"
    return 0
  fi

  if ! command -v git >/dev/null 2>&1; then
    echo "Missing llama.cpp source and git is not available to clone it." >&2
    exit 1
  fi

  log "Cloning llama.cpp source for build host"
  git clone --depth 1 https://github.com/ggml-org/llama.cpp.git "$LLAMA_FALLBACK_SOURCE_DIR"
  LLAMA_SOURCE_DIR="$LLAMA_FALLBACK_SOURCE_DIR"
}

assert_universal() {
  local executable="$1"
  local name="$2"
  local info
  info="$(lipo -info "$executable")"
  if [[ "$info" != *"arm64"* || "$info" != *"x86_64"* ]]; then
    echo "$name is not universal; expected arm64 and x86_64 slices." >&2
    echo "$info" >&2
    exit 1
  fi
}

sign_macho_files() {
  local root="$1"
  while IFS= read -r -d '' file; do
    if file "$file" | grep -Eq "Mach-O|dynamically linked shared library"; then
      codesign --force --options runtime --timestamp --sign "$APP_SIGN_IDENTITY" "$file"
    fi
  done < <(find "$root" -type f -print0)
}

normalize_runtime_rpaths() {
  local root="$1"
  local build_bin
  build_bin="$(cd "$LLAMA_BUILD_DIR/bin" && pwd -P)"
  while IFS= read -r -d '' file; do
    if file "$file" | grep -Eq "Mach-O|dynamically linked shared library"; then
      while [[ "$(otool -l "$file")" == *"path $build_bin "* ]]; do
        install_name_tool -delete_rpath "$build_bin" "$file" 2>/dev/null || break
      done
      install_name_tool -add_rpath @executable_path "$file" 2>/dev/null || true
      install_name_tool -add_rpath @loader_path "$file" 2>/dev/null || true
    fi
  done < <(find "$root" -type f -print0)
}

build_llama_runtime() {
  if ! command -v cmake >/dev/null 2>&1; then
    echo "cmake is required on the build host to create the bundled runtime." >&2
    exit 1
  fi

  resolve_llama_source_dir

  log "Building universal llama runtime from $LLAMA_SOURCE_DIR"
  cmake \
    -S "$LLAMA_SOURCE_DIR" \
    -B "$LLAMA_BUILD_DIR" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_OSX_ARCHITECTURES="$LLAMA_ARCHS" \
    -DCMAKE_OSX_DEPLOYMENT_TARGET="$LLAMA_DEPLOYMENT_TARGET" \
    -DLLAMA_OPENSSL=OFF \
    ${LLAMA_CMAKE_ARGS:-}
  cmake --build "$LLAMA_BUILD_DIR" --config Release --target llama-cli -j "$(sysctl -n hw.ncpu)"
  cmake --build "$LLAMA_BUILD_DIR" --config Release --target llama-completion -j "$(sysctl -n hw.ncpu)"
  cmake --build "$LLAMA_BUILD_DIR" --config Release --target llama-server -j "$(sysctl -n hw.ncpu)"

  local llama_cli="$LLAMA_BUILD_DIR/bin/llama-cli"
  local llama_completion="$LLAMA_BUILD_DIR/bin/llama-completion"
  local llama_server="$LLAMA_BUILD_DIR/bin/llama-server"
  [[ -x "$llama_cli" ]] || { echo "Missing built runtime: $llama_cli" >&2; exit 1; }
  [[ -x "$llama_completion" ]] || { echo "Missing built runtime: $llama_completion" >&2; exit 1; }
  [[ -x "$llama_server" ]] || { echo "Missing built runtime: $llama_server" >&2; exit 1; }
  assert_universal "$llama_cli" "llama-cli"
  assert_universal "$llama_completion" "llama-completion"
  assert_universal "$llama_server" "llama-server"

  rm -rf "$RUNTIME_STAGING_DIR"
  mkdir -p "$RUNTIME_STAGING_DIR/llama.cpp/build/bin"
  /usr/bin/ditto --norsrc --noextattr --noqtn --noacl "$llama_cli" "$RUNTIME_STAGING_DIR/llama.cpp/build/bin/llama-cli"
  /usr/bin/ditto --norsrc --noextattr --noqtn --noacl "$llama_completion" "$RUNTIME_STAGING_DIR/llama.cpp/build/bin/llama-completion"
  /usr/bin/ditto --norsrc --noextattr --noqtn --noacl "$llama_server" "$RUNTIME_STAGING_DIR/llama.cpp/build/bin/llama-server"

  find "$LLAMA_BUILD_DIR/bin" -maxdepth 1 \( -type f -o -type l \) -name "*.dylib" -print0 | while IFS= read -r -d '' dylib; do
    /usr/bin/ditto --norsrc --noextattr --noqtn --noacl "$dylib" "$RUNTIME_STAGING_DIR/llama.cpp/build/bin/$(basename "$dylib")"
  done

  find "$RUNTIME_STAGING_DIR" \( -name ".DS_Store" -o -name "._*" -o -name "*.gguf" \) -delete
  chmod 755 "$RUNTIME_STAGING_DIR/llama.cpp/build/bin/llama-cli" "$RUNTIME_STAGING_DIR/llama.cpp/build/bin/llama-completion" "$RUNTIME_STAGING_DIR/llama.cpp/build/bin/llama-server"
  normalize_runtime_rpaths "$RUNTIME_STAGING_DIR"
  sign_macho_files "$RUNTIME_STAGING_DIR"
}

build_app() {
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
    ARCHS="arm64 x86_64" \
    ONLY_ACTIVE_ARCH=NO \
    DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM" \
    CODE_SIGN_IDENTITY="$APP_SIGN_IDENTITY" \
    build

  local built_app="$DERIVED_DATA_PATH/Build/Products/${CONFIGURATION}/${APP_NAME}.app"
  if [[ ! -d "$built_app" ]]; then
    echo "Built app not found: $built_app" >&2
    exit 1
  fi

  local built_helper="$DERIVED_DATA_PATH/Build/Products/${CONFIGURATION}/TransOnLocalHelper"
  if [[ -x "$built_helper" ]]; then
    mkdir -p "$built_app/Contents/MacOS"
    /usr/bin/ditto --norsrc --noextattr --noqtn --noacl "$built_helper" "$built_app/Contents/MacOS/TransOnLocalHelper"
    chmod +x "$built_app/Contents/MacOS/TransOnLocalHelper"
  fi

  assert_universal "$built_app/Contents/MacOS/$APP_NAME" "$APP_NAME"
  assert_universal "$built_app/Contents/MacOS/TransOnLocalHelper" "TransOnLocalHelper"

  rm -rf "$PACKAGE_ROOT"
  mkdir -p "$PACKAGE_ROOT"
  /usr/bin/ditto --norsrc --noextattr --noqtn --noacl "$built_app" "$PACKAGE_ROOT/${APP_NAME}.app"
  /usr/bin/ditto --norsrc --noextattr --noqtn --noacl "$RUNTIME_STAGING_DIR/llama.cpp/build/bin" "$PACKAGE_ROOT/${APP_NAME}.app/$RUNTIME_APP_DIR"
  rm -f "$PACKAGE_ROOT/${APP_NAME}.app/Contents/Resources/TransOnLocalHelper"
  xattr -cr "$PACKAGE_ROOT/${APP_NAME}.app" 2>/dev/null || true
  find "$PACKAGE_ROOT" \( -name ".DS_Store" -o -name "._*" -o -name "*.gguf" \) -delete
  normalize_runtime_rpaths "$PACKAGE_ROOT/${APP_NAME}.app/$RUNTIME_APP_DIR"

  sign_macho_files "$PACKAGE_ROOT/${APP_NAME}.app/Contents/MacOS"
  sign_macho_files "$PACKAGE_ROOT/${APP_NAME}.app/$RUNTIME_APP_DIR"
  codesign --force --deep --options runtime --timestamp --sign "$APP_SIGN_IDENTITY" "$PACKAGE_ROOT/${APP_NAME}.app"
  xattr -cr "$PACKAGE_ROOT" 2>/dev/null || true
  find "$PACKAGE_ROOT" \( -name ".DS_Store" -o -name "._*" -o -name "*.gguf" \) -delete
  codesign --verify --deep --strict --verbose=2 "$PACKAGE_ROOT/${APP_NAME}.app"
}

write_first_run_readme() {
  mkdir -p "$DIST_DIR"
  cat > "$README_PATH" <<README
TransOn Local first run

Installed app:
  /Applications/TransOn Local.app

On a fresh Mac:
  1. Open TransOn Local from /Applications.
  2. In the menu bar, choose Prepare / Update Model.
  3. The app will install its bundled llama runtime and download the selected GGUF model.

The installer includes the llama runtime for Apple Silicon and Intel Macs.
The selected model is not bundled. Internet access is required for the first model download.

Not required on the target Mac:
  - Xcode
  - Xcode Command Line Tools
  - git
  - cmake
  - Homebrew

Recommended model for Intel Macs:
  - Q4_K_M or Q5_K_M

Q8_0 is available, but it is heavy and can exceed memory limits on Intel Macs or low-memory Apple Silicon Macs.
Runtime data and downloaded models are stored in:
  ~/Library/Application Support/com.grigorym.TransOnLocal/
README
}

build_package() {
  rm -f "$COMPONENT_PKG" "$FINAL_PKG"
  xattr -cr "$PACKAGE_ROOT" 2>/dev/null || true
  find "$PACKAGE_ROOT" \( -name ".DS_Store" -o -name "._*" -o -name "*.gguf" \) -delete

  log "Building signed component package"
  pkgbuild \
    --root "$PACKAGE_ROOT" \
    --install-location "/Applications" \
    --identifier "$PKG_ID" \
    --version "$VERSION" \
    --filter "\.DS_Store$" \
    --filter "/\._" \
    --filter "\.gguf$" \
    --filter "\.svn(/|$)" \
    --filter "CVS(/|$)" \
    --sign "$PKG_SIGN_IDENTITY" \
    "$COMPONENT_PKG"

  log "Building signed product package"
  productbuild \
    --package "$COMPONENT_PKG" \
    --sign "$PKG_SIGN_IDENTITY" \
    "$FINAL_PKG"

  if [[ "$SKIP_NOTARIZATION" != "1" ]]; then
    if [[ -z "$NOTARY_PROFILE" ]]; then
      echo "NOTARY_PROFILE is required for notarization." >&2
      echo "Create it with: xcrun notarytool store-credentials transon-notary" >&2
      exit 1
    fi
    log "Submitting installer for notarization"
    xcrun notarytool submit "$FINAL_PKG" --keychain-profile "$NOTARY_PROFILE" --wait
    log "Stapling notarization ticket"
    xcrun stapler staple "$FINAL_PKG"
  else
    log "Skipping notarization because SKIP_NOTARIZATION=1"
  fi

  pkgutil --check-signature "$FINAL_PKG"
  spctl -a -vvv -t install "$FINAL_PKG"
}

resolve_signing
build_llama_runtime
build_app
write_first_run_readme
build_package

log "Installer: $FINAL_PKG"
log "Readme: $README_PATH"
