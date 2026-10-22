#!/bin/bash
# Builds ClaudeMenu.app into ~/Applications, registers the statusline hook, and launches it.
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release

APP="$HOME/Applications/ClaudeMenu.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/ClaudeMenu "$APP/Contents/MacOS/ClaudeMenu"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>local.claude-menu</string>
    <key>CFBundleName</key><string>ClaudeMenu</string>
    <key>CFBundleExecutable</key><string>ClaudeMenu</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST
codesign --force --sign - "$APP" >/dev/null

# Statusline hook: feeds context % and usage limits to the app.
HOOK="$HOME/.claude/claude-menu/statusline.sh"
mkdir -p "$(dirname "$HOOK")"
cp statusline.sh "$HOOK"
chmod +x "$HOOK"

python3 - "$HOME/.claude/settings.json" "$HOOK" <<'PY'
import json, os, shutil, sys
path, hook = sys.argv[1], sys.argv[2]
settings = json.load(open(path)) if os.path.exists(path) else {}
current = settings.get("statusLine", {}).get("command")
if current == hook:
    print("statusLine already set")
elif current:
    print(f"! You already have a statusLine ({current}).")
    print(f"  Pipe its input into ClaudeMenu by adding this at the top of that script:")
    print(f"  input=$(cat); printf '%s' \"$input\" | {hook}; # then use \"$input\" instead of stdin")
else:
    if os.path.exists(path):
        shutil.copy(path, path + ".bak-claude-menu")
    settings["statusLine"] = {"type": "command", "command": hook, "padding": 0}
    json.dump(settings, open(path, "w"), indent=2)
    print("statusLine added to", path)
PY

pkill -x ClaudeMenu 2>/dev/null || true
open "$APP"
echo "ClaudeMenu installed at $APP"
