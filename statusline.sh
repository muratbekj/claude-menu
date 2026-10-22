#!/bin/bash
# Claude Code statusLine hook for ClaudeMenu.
# Saves the payload (context %, rate limits) per session, prints nothing.
dir="$HOME/.claude/claude-menu/status"
input=$(cat)
id=$(printf '%s' "$input" | sed -nE 's/.*"session_id"[[:space:]]*:[[:space:]]*"([A-Za-z0-9_-]+)".*/\1/p' | head -n1)
[ -n "$id" ] || exit 0
mkdir -p "$dir"
printf '%s' "$input" > "$dir/.$id.tmp" && mv -f "$dir/.$id.tmp" "$dir/$id.json"
