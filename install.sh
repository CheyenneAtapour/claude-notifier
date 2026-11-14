#!/bin/bash
# Builds Claude Notifier from this repo and installs it for this user:
#   ~/.claude/notifier/Claude Notifier.app        the menu bar app, started at login
#   ~/.claude/notifier/hook.sh                    a link to this repo's hook.sh
#   ~/.claude/bin/popcorn-terminal, claude-fork   links to this repo's bin/
#   Claude Code hooks in ~/.claude/settings.json  replacing any earlier notifier hooks
# Session records, history and the log stay in ~/.claude/notifier, outside the repo.
# Safe to run again after changing the source.
set -euo pipefail

repo="$(cd "$(dirname "$0")" && pwd)"
dest="$HOME/.claude/notifier"
app="$dest/Claude Notifier.app"
label="com.$USER.claude-notifier"
plist="$HOME/Library/LaunchAgents/$label.plist"
settings="$HOME/.claude/settings.json"

for tool in swiftc jq; do
  command -v "$tool" >/dev/null || { echo "Needs $tool (swiftc comes with the Xcode command line tools)." >&2; exit 1; }
done

echo "Building $app"
mkdir -p "$dest/sessions" "$app/Contents/MacOS" "$HOME/.claude/bin" "$(dirname "$plist")"
cp "$repo/support/Info.plist" "$app/Contents/Info.plist"
swiftc -O "$repo/ClaudeNotifier.swift" -o "$app/Contents/MacOS/ClaudeNotifier"
codesign --force -s - "$app"

echo "Linking the hook and scripts"
ln -sf "$repo/hook.sh" "$dest/hook.sh"
for script in popcorn-terminal claude-fork; do
  ln -sf "$repo/bin/$script" "$HOME/.claude/bin/$script"
done

echo "Installing Claude Code hooks in $settings"
[ -f "$settings" ] || echo '{}' >"$settings"
jq '
  def ours($mode): {hooks: [{type: "command", command: ("$HOME/.claude/notifier/hook.sh " + $mode), timeout: 10}]};
  # Replaces any earlier notifier hook for the event; keeps everything else.
  def put($event; $entry):
    .hooks[$event] = ([(.hooks[$event] // [])[] | select(any(.hooks[]?; (.command // "") | test("notifier/hook\\.sh")) | not)] + [$entry]);
  .hooks //= {}
  | put("UserPromptSubmit"; ours("prompt"))
  | put("Stop"; ours("done"))
  | put("Notification"; ours("input"))
  | put("PreToolUse"; ours("input") + {matcher: "AskUserQuestion"})
  | put("PostToolUse"; ours("resume"))
  | put("SessionEnd"; ours("end"))
' "$settings" >"$settings.tmp" && mv "$settings.tmp" "$settings"

echo "Starting it at login ($plist)"
cat >"$plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$label</string>
  <key>ProgramArguments</key>
  <array>
    <string>$app/Contents/MacOS/ClaudeNotifier</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <dict>
    <key>SuccessfulExit</key>
    <false/>
  </dict>
  <key>ProcessType</key>
  <string>Interactive</string>
</dict>
</plist>
PLIST
launchctl bootout "gui/$(id -u)/$label" 2>/dev/null || true
# bootout returns before the old copy has stopped; wait for it.
for _ in $(seq 1 50); do
  launchctl print "gui/$(id -u)/$label" >/dev/null 2>&1 || break
  sleep 0.1
done
launchctl bootstrap "gui/$(id -u)" "$plist"

echo "Installed. Look for ✳︎ Claude in the menu bar."
