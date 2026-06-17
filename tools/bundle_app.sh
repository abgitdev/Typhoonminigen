#!/bin/bash
# Build Typhoonminigen and assemble a runnable .app bundle.
#
#   tools/bundle_app.sh [Debug|Release] [/path/to/Typhoonminigen.app]
#
# Defaults: Release → ~/Desktop/Typhoonminigen.app, ad-hoc signed.
# Set SIGN_IDENTITY to sign with a real identity instead of ad-hoc (every ad-hoc
# re-sign changes the binary's identity, so the Keychain re-prompts for the HF
# token after rebuilds; a stable identity stops that).
#
# Requires Xcode with the Metal Toolchain: plain `swift build` cannot compile
# MLX's Metal shaders (no metallib → "Failed to load the default metallib" at
# runtime) — only xcodebuild can.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="${1:-Release}"
APP="${2:-$HOME/Desktop/Typhoonminigen.app}"
DERIVED="$ROOT/.build-xcode"
PRODUCTS="$DERIVED/Build/Products/$CONFIG"

# Single-sourced version — bump it in AppVersion.swift only.
# VERSION = marketing (CFBundleShortVersionString); BUILD = build number (CFBundleVersion).
VERSION="$(sed -n 's/.*static let current = "\([^"]*\)".*/\1/p' \
    "$ROOT/Sources/Typhoonminigen/App/AppVersion.swift")"
[ -n "$VERSION" ] || { echo "error: couldn't read the version from AppVersion.swift" >&2; exit 1; }
BUILD="$(sed -n 's/.*static let build = "\([^"]*\)".*/\1/p' \
    "$ROOT/Sources/Typhoonminigen/App/AppVersion.swift")"
[ -n "$BUILD" ] || { echo "error: couldn't read the build number from AppVersion.swift" >&2; exit 1; }

# Safety tripwire: refuse to ship if any of the three Mistral-24B fuses was reopened
# (an accidental load swap-freezes a 16-32 GB Mac). Runs on every bundle build.
echo "▸ Mistral fuse tripwire…"
"$ROOT/tools/check_mistral_fuses.sh" >/dev/null || {
    echo "error: Mistral fuse tripwire FAILED — refusing to build. Run tools/check_mistral_fuses.sh" >&2
    exit 1
}

echo "▸ building Typhoonminigen $VERSION (build $BUILD, $CONFIG)…"
xcodebuild -scheme Typhoonminigen -destination 'platform=macOS' \
    -configuration "$CONFIG" -derivedDataPath "$DERIVED" build | tail -2

echo "▸ assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$PRODUCTS/Typhoonminigen" "$APP/Contents/MacOS/"
# ALL dependency resource bundles, not just MLX's metallib: swift-transformers'
# Hub.bundle holds fallback tokenizer configs it force-unwraps (Bundle.module) when a
# downloaded model lacks tokenizer_class — shipping without it is a latent crash.
cp -R "$PRODUCTS"/*.bundle "$APP/Contents/Resources/"
cp "$ROOT/tools/Typhoonminigen.icns" "$APP/Contents/Resources/"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleExecutable</key>
	<string>Typhoonminigen</string>
	<key>CFBundleIconFile</key>
	<string>Typhoonminigen</string>
	<key>CFBundleIdentifier</key>
	<string>com.personal.typhoonminigen</string>
	<key>CFBundleName</key>
	<string>Typhoonminigen</string>
	<key>CFBundleShortVersionString</key>
	<string>$VERSION</string>
	<key>CFBundleVersion</key>
	<string>$BUILD</string>
	<key>LSMinimumSystemVersion</key>
	<string>14.0</string>
	<key>NSHighResolutionCapable</key>
	<true/>
</dict>
</plist>
PLIST

echo "▸ signing (${SIGN_IDENTITY:-ad-hoc})"
codesign --force --deep --sign "${SIGN_IDENTITY:--}" "$APP"

echo "✓ done: $APP  (v$VERSION build $BUILD, $CONFIG)"
