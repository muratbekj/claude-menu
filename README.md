# ClaudeMenu

A macOS menu bar app for [Claude Code](https://claude.com/claude-code). It shows which sessions are working or waiting for you, how full each context window is, and how much of your usage limits is left. If you also use [Cursor Agent](https://cursor.com/cli), it shows your Cursor sessions and limits too.

## Features

- **Menu bar icon:** shows Clawd with your 5-hour usage %. When a session needs you, Clawd turns orange, waves, and shows how many sessions are waiting. When you're out of usage, Clawd lies still with X'd-out eyes.
- **Usage limits:** session (5 hours) and weekly (7 days) usage, with reset times.
- **Sessions:** lists the sessions that need you and the ones that are working, each with its context window usage. Click a session to bring its terminal or editor to the front.
- **Cursor sessions:** `cursor-agent` sessions in the terminal show up in the same list, marked with a little Cursor cube. They count as needing you while Cursor is asking for an approval, and as working while it's replying.
- **Cursor usage:** Premium models and Cursor models (Auto, Composer, Grok) usage, plus the date your billing cycle resets. In the menu bar, Clawd stands on a little Cursor cube, and the number after the slash is your Premium models usage. Once Premium runs out it switches to Cursor models and the cube's top goes hollow. When both are used up, the cube turns grey.
- **Open at login:** a checkbox in the panel.

## Requirements

- macOS 14 or later
- Swift 5.9 or later (Xcode or the Command Line Tools)
- Claude Code
- Cursor Agent (optional, for Cursor usage)

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

### Cursor

Cursor usage needs Cursor Agent to be logged in (`cursor-agent login`). On first launch, macOS asks whether ClaudeMenu may use `cursor-access-token` from your Keychain. Click **Always Allow**. The app is self-signed, so macOS may ask again after you rebuild it with `install.sh`, or after Cursor Agent renews its login.

Without a Cursor login, ClaudeMenu looks exactly as it does without Cursor.

## How it works

- **Sessions** come from `~/.claude/sessions/*.json`, which Claude Code writes itself.
- **Context and usage limits** come from the status line hook. `statusline.sh` saves each session's status line payload to `~/.claude/claude-menu/status/<session_id>.json` and prints nothing.
- **Background sessions** don't run the status line, so for those the app estimates context usage from the latest token counts in the session's transcript.

The app checks Claude Code for changes every 2 seconds. Claude data is read locally and never leaves your machine.

- **Cursor sessions** come from the debug log each running `cursor-agent` writes to `$TMPDIR/cursor-agent-logs-<uid>/`, plus the chat title from `~/.cursor/chats/`. That log is internal to Cursor, so if an update changes it, Cursor sessions stop appearing until ClaudeMenu catches up. Chats in the Cursor editor aren't shown.
- **Cursor usage** is the one network request the app makes. Every 5 minutes, and when you open the panel, it asks Cursor's API (`api2.cursor.sh`) for your usage.
- **Login:** it uses the login Cursor Agent already saved in your Keychain, or the Cursor editor's saved login as a fallback.
- **The token** is kept in memory only. It's never written anywhere or sent anywhere else, and the app never renews it.
- **If the login expires,** the panel asks you to run `cursor-agent` once.

## Uninstall

1. If **Open at login** is on, uncheck it in the panel first. Otherwise a stale item can stay in System Settings → Login Items.
2. Quit the app and remove its files:

   ```sh
   pkill -x ClaudeMenu
   rm -rf ~/Applications/ClaudeMenu.app ~/.claude/claude-menu
   ```

3. Remove the `statusLine` entry from `~/.claude/settings.json`. Don't restore `settings.json.bak-claude-menu` for this: it's a copy from install time and would undo any settings you've changed since.

## License

MIT. See [LICENSE](LICENSE).
