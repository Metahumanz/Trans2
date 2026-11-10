#!/usr/bin/env bash
# Build Trans2.app, zip it, and make a dmg.
#
# Usage: Scripts/package-app.sh [version]
# Output: dist/Trans2.app, dist/Trans2-<version>-<arch>.zip, .dmg
#
# Requires the whisper.cpp runtime under .build-tools/ (run
# ./Scripts/setup-whispercpp.sh once). The model is not bundled; the app
# downloads it on first launch or uses an existing ggml file.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="${1:-$(cat "$ROOT/VERSION" 2>/dev/null || echo 0.1.0)}"
DIST="$ROOT/dist"
APP="$DIST/Trans2.app"
CONTENTS="$APP/Contents"
MACOS="$CONTENTS/MacOS"
RESOURCES="$CONTENTS/Resources"
RUNTIME="$RESOURCES/runtime"
WHISPER_BIN="${TRANS2_WHISPER_BIN:-$ROOT/.build-tools/whisper.cpp/build/bin}"
ICON="$ROOT/Sources/Trans2/Resources/AppIcon.icns"

echo "==> Building Trans2 $VERSION (release)"
cd "$ROOT"
swift build -c release --disable-sandbox
BIN_DIR="$(swift build -c release --disable-sandbox --show-bin-path)"
BIN="$BIN_DIR/Trans2"
[ -x "$BIN" ] || { echo "missing executable: $BIN" >&2; exit 1; }

echo "==> Assembling .app"
rm -rf "$DIST"
mkdir -p "$MACOS" "$RESOURCES" "$RUNTIME/bin"

cp "$BIN" "$MACOS/Trans2"
chmod +x "$MACOS/Trans2"

shopt -s nullglob
for bundle in "$BIN_DIR"/*.bundle; do
  rsync -a "$bundle" "$RESOURCES/"
done
for lproj in "$ROOT"/Sources/Trans2/Resources/*.lproj; do
  rsync -a "$lproj" "$RESOURCES/"
done
shopt -u nullglob

[ -x "$WHISPER_BIN/whisper-cli" ] || {
  echo "whisper-cli not found under $WHISPER_BIN" >&2
  echo "Run ./Scripts/setup-whispercpp.sh first, or set TRANS2_WHISPER_BIN." >&2
  exit 1
}

cp "$WHISPER_BIN/whisper-cli" "$RUNTIME/bin/"
shopt -s nullglob
for dylib in "$WHISPER_BIN"/*.dylib; do
  cp -P "$dylib" "$RUNTIME/bin/"
done
shopt -u nullglob

# Rewrite every non-system dependency so the bundled CLI resolves beside
# itself; fail loudly if the runtime is incomplete.
while IFS= read -r binary; do
  [ -n "$binary" ] || continue
  while IFS= read -r dependency; do
    [ -n "$dependency" ] || continue
    case "$dependency" in
      /System/Library/*|/usr/lib/*) continue ;;
    esac
    name="$(basename "$dependency")"
    if [ ! -e "$RUNTIME/bin/$name" ]; then
      echo "unbundled non-system dependency: $dependency ($binary)" >&2
      exit 1
    fi
    case "$dependency" in
      "@rpath/$name") ;;
      *) install_name_tool -change "$dependency" "@rpath/$name" "$binary" ;;
    esac
  done < <(otool -L "$binary" | tail -n +2 | sed -E 's/^[[:space:]]+//; s/ \(compatibility version.*$//')

  if [[ "$binary" == *.dylib ]]; then
    install_name_tool -id "@rpath/$(basename "$binary")" "$binary"
  fi
  if ! otool -l "$binary" | grep -Fq 'path @loader_path'; then
    install_name_tool -add_rpath '@loader_path' "$binary"
  fi
  while IFS= read -r old_rpath; do
    case "$old_rpath" in
      "$ROOT"/*|*"/.build-tools/whisper.cpp/"*)
        install_name_tool -delete_rpath "$old_rpath" "$binary"
        ;;
    esac
  done < <(otool -l "$binary" | awk '/cmd LC_RPATH/{getline; getline; sub(/^[[:space:]]*path /, ""); sub(/ \(offset.*/, ""); print}')
done < <(find "$RUNTIME/bin" -type f \( -name 'whisper-cli' -o -name '*.dylib' \) -print)

[ -f "$ICON" ] && cp "$ICON" "$RESOURCES/AppIcon.icns"
[ -f "$ROOT/README.md" ] && cp "$ROOT/README.md" "$RESOURCES/README.md"
[ -f "$ROOT/THIRD_PARTY_NOTICES.md" ] && cp "$ROOT/THIRD_PARTY_NOTICES.md" "$RESOURCES/"

cat > "$CONTENTS/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>zh_CN</string>
  <key>CFBundleExecutable</key>
  <string>Trans2</string>
  <key>CFBundleIdentifier</key>
  <string>com.metahumanz.trans2</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>Trans2</string>
  <key>CFBundleDisplayName</key>
  <string>Trans2</string>
  <key>CFBundleLocalizations</key>
  <array>
    <string>en</string>
    <string>zh-Hans</string>
    <string>ja</string>
  </array>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
  <key>CFBundleDocumentTypes</key>
  <array>
    <dict>
      <key>CFBundleTypeName</key>
      <string>Movie</string>
      <key>CFBundleTypeRole</key>
      <string>Viewer</string>
      <key>LSItemContentTypes</key>
      <array>
        <string>public.movie</string>
        <string>public.mpeg-4</string>
        <string>com.apple.quicktime-movie</string>
        <string>com.apple.m4v-video</string>
      </array>
    </dict>
    <dict>
      <key>CFBundleTypeName</key>
      <string>Audio</string>
      <key>CFBundleTypeRole</key>
      <string>Viewer</string>
      <key>LSItemContentTypes</key>
      <array>
        <string>public.audio</string>
        <string>public.mpeg-4-audio</string>
        <string>com.apple.m4a-audio</string>
        <string>public.mp3</string>
        <string>com.microsoft.waveform-audio</string>
        <string>org.xiph.flac</string>
      </array>
    </dict>
  </array>
  <key>CFBundleShortVersionString</key>
  <string>$VERSION</string>
  <key>CFBundleVersion</key>
  <string>$VERSION</string>
  <key>LSMinimumSystemVersion</key>
  <string>14.0</string>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
  <key>NSAppTransportSecurity</key>
  <dict>
    <key>NSAllowsLocalNetworking</key>
    <true/>
    <key>NSExceptionDomains</key>
    <dict>
      <key>localhost</key>
      <dict><key>NSExceptionAllowsInsecureHTTPLoads</key><true/></dict>
      <key>127.0.0.1</key>
      <dict><key>NSExceptionAllowsInsecureHTTPLoads</key><true/></dict>
      <key>10.0.0.0/8</key>
      <dict><key>NSExceptionAllowsInsecureHTTPLoads</key><true/></dict>
      <key>172.16.0.0/12</key>
      <dict><key>NSExceptionAllowsInsecureHTTPLoads</key><true/></dict>
      <key>192.168.0.0/16</key>
      <dict><key>NSExceptionAllowsInsecureHTTPLoads</key><true/></dict>
    </dict>
  </dict>
</dict>
</plist>
PLIST

echo "==> Signing (ad-hoc)"
find "$RUNTIME/bin" -type f -name '*.dylib' -print0 | while IFS= read -r -d '' dylib; do
  codesign --force --sign - "$dylib"
done
codesign --force --sign - "$RUNTIME/bin/whisper-cli"
codesign --force --sign - "$MACOS/Trans2"
codesign --force --sign - "$APP"
codesign --verify --deep --strict "$APP"

echo "==> Relocation smoke test"
MIGRATION_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/trans2-migration.XXXXXX")"
trap 'rm -rf "$MIGRATION_ROOT"' EXIT
ditto "$APP" "$MIGRATION_ROOT/Trans2.app"
"$MIGRATION_ROOT/Trans2.app/Contents/Resources/runtime/bin/whisper-cli" --help >/dev/null
if otool -L "$MIGRATION_ROOT/Trans2.app/Contents/Resources/runtime/bin/whisper-cli" | grep -F "$ROOT/.build-tools/" >/dev/null; then
  echo "migrated CLI still references the checkout runtime" >&2
  exit 1
fi
codesign --verify --deep --strict "$MIGRATION_ROOT/Trans2.app"

echo "==> Packaging"
ARCH="$(uname -m)"
ZIP="$DIST/Trans2-${VERSION}-${ARCH}.zip"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"

DMG="$DIST/Trans2-${VERSION}-${ARCH}.dmg"
STAGE="$(mktemp -d)"
ditto --norsrc --noextattr "$APP" "$STAGE/Trans2.app"
ln -s /Applications "$STAGE/Applications"
# DMG creation needs the disk-image service; keep the zip as the guaranteed
# artifact when a restricted build environment denies it.
if hdiutil create -volname "Trans2" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null 2>&1; then
  echo "  $DMG"
else
  echo "  (dmg skipped: disk image creation unavailable here)"
  rm -f "$DMG"
fi
rm -rf "$STAGE"

echo "Done:"
echo "  $APP"
echo "  $ZIP"
