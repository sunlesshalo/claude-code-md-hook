#!/bin/bash
# uninstall.sh — claude-code-md-hook uninstaller
#
# Usage:
#   Project-level (default):  bash uninstall.sh
#   Global:                   bash uninstall.sh --global

GLOBAL=false
for arg in "$@"; do
    case $arg in
        --global) GLOBAL=true ;;
    esac
done

echo "claude-code-md-hook uninstaller"
echo "================================"

if [ "$GLOBAL" = true ]; then
    SCRIPTS_DIR="$HOME/.claude/scripts"
    HOOKS_JSON="$HOME/.claude/hooks.json"
    HOOK_COMMAND="bash $HOME/.claude/scripts/md-convert.sh"
    echo "Mode: global"
else
    SCRIPTS_DIR="$(pwd)/scripts"
    HOOKS_JSON="$(pwd)/.claude/hooks.json"
    HOOK_COMMAND="bash scripts/md-convert.sh"
    echo "Mode: project ($(pwd))"
fi

echo ""

# --- Remove the script ---
if [ -f "$SCRIPTS_DIR/md-convert.sh" ]; then
    rm "$SCRIPTS_DIR/md-convert.sh"
    echo "✓ Removed $SCRIPTS_DIR/md-convert.sh"
else
    echo "  md-convert.sh not found at $SCRIPTS_DIR — skipping"
fi

# --- Patch hooks.json ---
if [ ! -f "$HOOKS_JSON" ]; then
    echo "  hooks.json not found — nothing to patch"
else
    python3 - <<PYEOF
import json, os

hooks_path = "$HOOKS_JSON"
hook_command = "$HOOK_COMMAND"

try:
    with open(hooks_path) as f:
        config = json.load(f)
except Exception:
    print("  Could not parse hooks.json — skipping")
    exit(0)

pre = config.get("hooks", {}).get("PreToolUse", [])
changed = False

for entry in pre:
    if entry.get("matcher") == "Read":
        before = len(entry.get("hooks", []))
        entry["hooks"] = [h for h in entry.get("hooks", []) if h.get("command") != hook_command]
        if len(entry["hooks"]) < before:
            changed = True

# Remove empty Read matchers
config["hooks"]["PreToolUse"] = [e for e in pre if e.get("hooks")]

# Remove empty top-level keys
if not config["hooks"]["PreToolUse"]:
    del config["hooks"]["PreToolUse"]
if not config.get("hooks"):
    del config["hooks"]

if changed:
    with open(hooks_path, "w") as f:
        json.dump(config, f, indent=2)
    print("✓ Removed hook from " + hooks_path)
else:
    print("  Hook not found in hooks.json — nothing to remove")
PYEOF
fi

echo ""
echo "Done. Restart Claude Code to apply changes."
