# TransOn Local

TransOn Local is a separate macOS menu bar app for local GGUF translation. It uses a helper process to prepare `llama.cpp`, download a GGUF model, and run translation with `llama-cli`.

Default model: `GemmaX2-28-9B-v0.2.Q8_0.gguf` from `mradermacher/GemmaX2-28-9B-v0.2-GGUF`.

Runtime data is stored in:

```text
~/Library/Application Support/com.grigorym.TransOnLocal/
```

## Build

```sh
xcodegen generate
xcodebuild -project TransOnLocal.xcodeproj -scheme "TransOn Local" -configuration Debug build
```

Use `scripts/build_and_install_app.sh` to build and install the app into `/Applications` once the generated Xcode project exists.

## Installer

Create a clean installer package for a fresh Mac:

```sh
./scripts/package_installer.sh
```

The package is written to `dist/TransOn Local-0.1.0-Installer.pkg`. It installs only the app into `/Applications`. On the target Mac, open the app and choose `Prepare / Update Model` to build `llama.cpp` and download the selected GGUF model.

Before first preparation on a fresh Mac, check dependencies:

```sh
./scripts/check_fresh_mac_requirements.sh
```
