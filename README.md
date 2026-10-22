# ClaudeMenu

A macOS menu bar app for [Claude Code](https://claude.com/claude-code). It shows which sessions are working or waiting for you, how full each context window is, and how much of your usage limits is left.

## Features

- **Menu bar icon:** shows Clawd with your 5-hour usage %. When a session needs you, Clawd turns orange, waves, and shows how many sessions are waiting. When you're out of usage, Clawd lies still with X'd-out eyes.
- **Usage limits:** session (5 hours) and weekly (7 days) usage, with reset times.
- **Sessions:** lists the sessions that need you and the ones that are working, each with its context window usage. Click a session to bring its terminal or editor to the front.
- **Open at login:** a checkbox in the panel.

## Requirements

- macOS 14 or later
- Swift 5.9 or later (Xcode or the Command Line Tools)
- Claude Code

## Install

```sh
git clone https://github.com/muratbekj/claude-menu.git
cd claude-menu
./install.sh
```

The script:

1. Builds the app and installs it to `~/Applications/ClaudeMenu.app`.
2. Copies `statusline.sh` to `~/.claude/claude-menu/statusline.sh` and sets it as Claude Code's `statusLine` in `~/.claude/settings.json`. Before changing the settings file, it saves a backup at `settings.json.bak-claude-menu`.
3. Launches the app.

Usage limits appear after you send your next message in Claude Code.

### If you already have a status line

The installer leaves an existing `statusLine` alone and prints a line to add to the top of your script. That line passes the status line input on to ClaudeMenu:

```sh
input=$(cat); printf '%s' "$input" | ~/.claude/claude-menu/statusline.sh
# then use "$input" instead of reading stdin
```

## How it works

- **Sessions** come from `~/.claude/sessions/*.json`, which Claude Code writes itself.
- **Context and usage limits** come from the status line hook. `statusline.sh` saves each session's status line payload to `~/.claude/claude-menu/status/<session_id>.json` and prints nothing.
- **Background sessions** don't run the status line, so for those the app estimates context usage from the latest token counts in the session's transcript.

The app checks for changes every 2 seconds. Everything stays on your machine, and the app makes no network requests.

## Uninstall

```sh
pkill -x ClaudeMenu
rm -rf ~/Applications/ClaudeMenu.app ~/.claude/claude-menu
```

Then remove the `statusLine` entry from `~/.claude/settings.json`, or restore the `settings.json.bak-claude-menu` backup.
