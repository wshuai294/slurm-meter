#!/bin/zsh
# Builds build/SlurmMeter.app.
#   ./build.sh --install [dir]   also copies it to <dir>/"SLURM Meter.app" (default ~/Applications) and launches it.
set -euo pipefail
cd "${0:A:h}"

APP=build/SlurmMeter.app
rm -rf build
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

swiftc -O -parse-as-library -swift-version 5 \
    -target "$(uname -m)-apple-macos14.0" \
    Sources/*.swift -o "$APP/Contents/MacOS/SlurmMeter"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>local.slurm-meter</string>
    <key>CFBundleName</key><string>SlurmMeter</string>
    <key>CFBundleDisplayName</key><string>SLURM Meter</string>
    <key>CFBundleExecutable</key><string>SlurmMeter</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP" >/dev/null

if [[ "${1:-}" == "--install" ]]; then
    DIR="${2:-$HOME/Applications}"
    mkdir -p "$DIR"
    DEST="$DIR/SLURM Meter.app"
    pkill -x SlurmMeter 2>/dev/null || true
    while pgrep -x SlurmMeter >/dev/null; do sleep 0.2; done
    rm -rf "$DEST"
    cp -R "$APP" "$DEST"
    open "$DEST" 2>/dev/null || { sleep 1; open "$DEST"; }   # LaunchServices can briefly refuse right after quit
    echo "Installed to $DEST"
else
    echo "Built $APP"
fi
