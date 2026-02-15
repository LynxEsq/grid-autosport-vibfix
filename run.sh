#!/bin/bash
# Launch GRID Autosport with vibration fix DYLIB injected
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DYLIB="$SCRIPT_DIR/grid_vibfix.dylib"
GAME_BIN="/Applications/GRID Autosport/GRID Autosport.app/Contents/MacOS/GRID Autosport"
HW_CONFIG="$HOME/Library/Application Support/Feral Interactive/GRID Autosport/VFS/User/AppData/Roaming/My Games/GRID Autosport/hardwaresettings/hardware_settings_config.xml"
PLIST="/Applications/GRID Autosport/GRID Autosport.app/Contents/Resources/InputDevices/360Driver/XBox360Wired.plist"

if [ ! -f "$DYLIB" ]; then
    echo "DYLIB not found. Building..."
    make -C "$SCRIPT_DIR" all
fi

if [ ! -f "$GAME_BIN" ]; then
    echo "ERROR: Game not found at: $GAME_BIN"
    exit 1
fi

# Patch telemetry config:
# - ip from "dbox" to "127.0.0.1" (send to localhost)
# - extradata from "0" to "3" (maximum telemetry data)
if [ -f "$HW_CONFIG" ]; then
    if grep -q 'ip="dbox"' "$HW_CONFIG"; then
        sed -i.bak 's/ip="dbox"/ip="127.0.0.1"/' "$HW_CONFIG"
        echo "Patched telemetry: ip -> 127.0.0.1"
    elif grep -q 'ip="127.0.0.1"' "$HW_CONFIG"; then
        echo "Telemetry IP already patched"
    fi
    if grep -q 'extradata="0"' "$HW_CONFIG"; then
        sed -i.bak2 's/extradata="0"/extradata="3"/' "$HW_CONFIG"
        echo "Patched telemetry: extradata -> 3"
    fi
    # Minimize telemetry delay for responsive vibration
    if grep -q 'delay="1"' "$HW_CONFIG"; then
        sed -i.bak3 's/delay="1"/delay="0"/' "$HW_CONFIG"
        echo "Patched telemetry: delay -> 0"
    fi
fi

# Restore plist to original Xbox type (Rumble2 breaks input)
if [ -f "$PLIST.vibfix_orig" ]; then
    cp "$PLIST.vibfix_orig" "$PLIST"
    echo "Plist restored to original Xbox type"
fi

echo "=== GRID Autosport Vibration Fix ==="
echo "DYLIB: $DYLIB"
echo "Game:  $GAME_BIN"
echo "Log:   $SCRIPT_DIR/grid_vibfix.log"
echo ""
echo "Launching..."

DYLD_INSERT_LIBRARIES="$DYLIB" "$GAME_BIN" "$@"

# Stop controller vibration after game exits
STOP_RUMBLE="$SCRIPT_DIR/stop_rumble"
if [ -f "$STOP_RUMBLE" ]; then
    echo "Stopping controller vibration..."
    "$STOP_RUMBLE"
fi
