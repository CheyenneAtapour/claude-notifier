# Claude Notifier

A macOS menu bar app that tracks every Claude Code session running in Terminal:
which ones have finished, which are blocked on you, and what each is working on.

## What it does

**Menu bar.** `✳︎ Claude` shows a red count of sessions that have finished their
reply and a green count of sessions blocked on you (a permission prompt or a
question). Each row names the session by its folder and Terminal tab title, its
directory and git branch; hovering shows the full window name. Clicking a row
brings that exact Terminal tab to the front.

A finished session's mark clears when you switch to its window or tab. If it was
already in front when it finished, the mark stays until you click in it.

**Dashboard** (menu bar → Open Dashboard…). A card for every open Claude session,
ordered needs you, working, done, then idle, most recently prompted first:

- its status, task (your last prompt), directory and branch;
- how long it has been working, with a rough ETA from how long your past prompts
  took (Claude Code reports no progress, so this is only an estimate);
- a live preview of its screen, in the terminal's own colours, without Claude's
  input box.

Click a card for a larger live view of its scrollback, where you can:

- **Bring to front** — focus its Terminal tab;
- **send a prompt** — typed into the session as if you had typed it there;
- **New Popcorn terminal here** — a plain shell in its directory.

**New Claude session…** starts Claude in a folder you choose (or create), with
fresh context or a copy of an open session's conversation
(`claude --resume <id> --fork-session`).

## Install

Needs macOS, Terminal.app, the Xcode command line tools (`swiftc`) and `jq`.

```sh
./install.sh
```

This builds `~/.claude/notifier/Claude Notifier.app`, starts it at login, links
the hook and scripts from this repo, and adds the hooks to
`~/.claude/settings.json` (replacing earlier notifier hooks, keeping your others).
Run it again after changing the source.

macOS will ask for two permissions:

- **Automation → Terminal**, to read tab titles and screens, focus tabs and send
  prompts;
- **Accessibility**, to notice a click inside a Terminal window. Without it,
  switching windows still clears marks.

The app is signed ad hoc, so macOS may ask again after a rebuild.

## How it works

`hook.sh` runs on Claude Code's hook events and keeps one JSON file per session
in `~/.claude/notifier/sessions/`:

| Event | Mode | State |
| --- | --- | --- |
| `UserPromptSubmit` | `prompt` | working, recording the prompt as the task |
| `Stop` | `done` | done (red) |
| `Notification`, `PreToolUse` on `AskUserQuestion` | `input` | needs you (green); the idle reminder is ignored |
| `PostToolUse` | `resume` | working again after you answered; a session with no record yet gets one, its task read from its transcript |
| `SessionEnd` | `end` | removed |

Each record also notes the session's terminal device, which the app matches
against Terminal's tabs (over AppleScript) for titles, previews and focus. Only
sessions whose terminal still runs `claude` are shown. Finished prompts' durations
go to `~/.claude/notifier/history.jsonl` for the ETA; errors go to
`~/.claude/notifier/notifier.log`.

## Popcorn windows

`bin/popcorn-terminal [dir] [command]` opens a Terminal window with a random theme
from `$POPCORN_THEMES` (default
`~/Documents/github/random/macos-terminal-themes/themes`), in `dir`, optionally
running `command`. `bin/claude-fork [session-id] [dir]` uses it to open a fork of
a Claude session (the latest in `dir` if no id is given).

## Uninstall

```sh
launchctl bootout gui/$(id -u)/com.$USER.claude-notifier
rm ~/Library/LaunchAgents/com.$USER.claude-notifier.plist
rm -r ~/.claude/notifier ~/.claude/bin/popcorn-terminal ~/.claude/bin/claude-fork
```

Then remove the `notifier/hook.sh` entries from `~/.claude/settings.json`.
