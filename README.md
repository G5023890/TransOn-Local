# TransOn Local

TransOn Local is a native macOS menu bar app for fully local text translation with GGUF models. It is designed for Apple Silicon and Intel Macs and uses a bundled universal `llama.cpp` runtime.

The app runs translation locally through `llama-server` when available, so the model is loaded once and reused between translations. `llama-completion` remains bundled as a fallback runtime.

## What Is Bundled

The app bundle includes:

- `llama-server`
- `llama-cli`
- `llama-completion`
- required `llama.cpp` / `ggml` dynamic libraries
- Metal backend support
- universal `arm64` + `x86_64` binaries

The app bundle does not include `.gguf` model files. Models are downloaded from inside the app after installation.

Runtime data is stored in:

```text
~/Library/Application Support/com.grigorym.TransOnLocal/
```

## Fresh Mac Requirements

On a target Mac, TransOn Local does not require:

- Xcode
- Xcode Command Line Tools
- Homebrew
- `git`
- `cmake`
- development libraries

Internet access is required for the first model download.

## First Run

1. Install `TransOn Local.app` or the signed `.pkg`.
2. Open TransOn Local.
3. Choose `Prepare / Update Model`.
4. The app copies the bundled runtime into Application Support and downloads the selected GGUF model.
5. Select text in another app and trigger translation with the configured hotkey.

The translation overlay shows only the translated text. The window title shows the app name, target language, and elapsed translation time, for example:

```text
TransOn Local - Russian (1m 12s)
```

## Default Model

Default model:

```text
qwen2.5-3b-instruct-q6_k.gguf
```

Source:

```text
Qwen/Qwen2.5-3B-Instruct-GGUF
```

Other quantized variants can be selected in the app.

## Build For Development

Generate the Xcode project and build:

```sh
xcodegen generate
xcodebuild -project TransOnLocal.xcodeproj -scheme "TransOn Local" -configuration Debug build
```

Build and install into `/Applications`:

```sh
./scripts/build_and_install_app.sh
```

## Build Installer

Create a signed and notarized installer package:

```sh
APP_SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
PKG_SIGN_IDENTITY="Developer ID Installer: Your Name (TEAMID)" \
NOTARY_PROFILE="transon-notary" \
./scripts/package_installer.sh
```

The package is written to:

```text
dist/TransOn Local-0.1.5-Installer.pkg
```

The installer places `TransOn Local.app` in `/Applications`. The app contains the bundled universal runtime, but models are still downloaded on first use.

Before packaging for other Macs, create the notary profile once:

```sh
xcrun notarytool store-credentials transon-notary
```

## Verification

Useful checks after packaging:

```sh
lipo -info "/Applications/TransOn Local.app/Contents/MacOS/TransOn Local"
lipo -info "/Applications/TransOn Local.app/Contents/MacOS/TransOnLocalHelper"
lipo -info "/Applications/TransOn Local.app/Contents/Resources/Runtime/llama.cpp/build/bin/llama-server"
codesign --verify --deep --strict --verbose=2 "/Applications/TransOn Local.app"
pkgutil --check-signature "dist/TransOn Local-0.1.5-Installer.pkg"
spctl -a -vvv -t install "dist/TransOn Local-0.1.5-Installer.pkg"
```

The runtime should not link against Homebrew libraries such as OpenSSL. It should use bundled `llama.cpp` libraries and system frameworks only.
