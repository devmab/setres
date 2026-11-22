#!/bin/bash
# setres installer:
#   1. builds the CLI -> ~/.local/bin/setres
#   2. writes a default config -> ~/.config/setres/config (kept if already present)
#   3. installs the display override adding the scaled modes (sudo; REBOOT to activate)
#
# usage: ./install.sh [WxH]   (default 1920x1080)
# Needs Xcode Command Line Tools (swiftc + python3).
set -euo pipefail
cd "$(dirname "$0")"

RES="${1:-1920x1080}"
W="${RES%x*}"
H="${RES#*x}"
if ! [[ "$W" =~ ^[0-9]+$ && "$H" =~ ^[0-9]+$ ]]; then
    echo "usage: $0 [WxH]   (default 1920x1080)" >&2
    exit 1
fi

# --- 1. CLI ---------------------------------------------------------------
mkdir -p "$HOME/.local/bin"
swiftc -O setres.swift -o "$HOME/.local/bin/setres"
echo "Installed $HOME/.local/bin/setres"
case ":$PATH:" in
    *":$HOME/.local/bin:"*) ;;
    *) echo "note: ~/.local/bin is not in your PATH" ;;
esac

# --- 2. Config ------------------------------------------------------------
CONFIG="$HOME/.config/setres/config"
if [[ -f "$CONFIG" ]]; then
    echo "Config already exists at $CONFIG — leaving it alone"
else
    mkdir -p "$(dirname "$CONFIG")"
    cat > "$CONFIG" <<EOF
# setres config — defaults for argless \`setres\` and \`setres watch\`
resolution=${W}x${H}
hidpi=false
# hz=60
# bundle IDs that trigger \`setres watch\` (launchers + game clients)
apps=com.ccpgames.eve-online-launcher,com.ccpgames.eveonline,net.battle.app,com.blizzard.worldofwarcraft
EOF
    echo "Wrote default config $CONFIG (resolution=${W}x${H})"
fi

# --- 3. Display override --------------------------------------------------
if [[ -n "$("$HOME/.local/bin/setres" list "${W}x${H}" 2>/dev/null)" ]]; then
    echo "${W}x${H} already in the built-in display's mode list — override not needed"
    echo "Done. Try: setres"
    exit 0
fi

echo "Detecting built-in display..."
VID="" PID=""
read -r VID PID < <(swift -e '
import CoreGraphics
var c: UInt32 = 0
CGGetOnlineDisplayList(0, nil, &c)
var ids = [CGDirectDisplayID](repeating: 0, count: Int(c))
CGGetOnlineDisplayList(c, &ids, &c)
for id in ids.prefix(Int(c)) where CGDisplayIsBuiltin(id) != 0 {
    print(String(format: "%x %x", CGDisplayVendorNumber(id), CGDisplayModelNumber(id)))
    break
}') || true
if [[ -z "$VID" || -z "$PID" ]]; then
    echo "No built-in display found (desktop Mac, or lid closed?)" >&2
    exit 1
fi
echo "Built-in panel: vendor 0x$VID product 0x$PID — adding ${W}x${H} scaled modes"

mkdir -p override
FILE="override/DisplayProductID-$PID"
python3 - "$VID" "$PID" "$W" "$H" "$FILE" <<'EOF'
import plistlib, struct, sys
vid, pid = int(sys.argv[1], 16), int(sys.argv[2], 16)
w, h = int(sys.argv[3]), int(sys.argv[4])
entries = [
    struct.pack('>II', w * 2, h * 2),      # doubled dims -> HiDPI variant
    struct.pack('>II', w, h),              # plain low-res scaled mode
    struct.pack('>III', w * 2, h * 2, 1),  # flagged variants (some macOS builds want these)
    struct.pack('>III', w, h, 1),
]
with open(sys.argv[5], 'wb') as f:
    plistlib.dump({'DisplayVendorID': vid, 'DisplayProductID': pid,
                   'scale-resolutions': entries}, f, fmt=plistlib.FMT_XML)
EOF

DEST="/Library/Displays/Contents/Resources/Overrides/DisplayVendorID-$VID"
TARGET="$DEST/DisplayProductID-$PID"
echo "Installing override (sudo)..."
if [[ -f "$TARGET" ]]; then
    echo "Existing override found — backing up to $TARGET.bak"
    sudo cp "$TARGET" "$TARGET.bak"
fi
sudo mkdir -p "$DEST"
sudo cp "$FILE" "$TARGET"
sudo chown root:wheel "$TARGET"
sudo chmod 644 "$TARGET"

echo "Installed $TARGET"
echo
echo "REBOOT to activate, then verify with: setres list ${W}x${H}"
echo "Uninstall override: sudo rm '$TARGET'  (then reboot)"
echo "Optional auto-switch on game launch: see 'Auto-switch on game launch' in README.md"
