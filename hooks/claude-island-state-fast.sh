#!/usr/bin/env bash
# claude-island-state-fast.sh
# Drop-in replacement for claude-island-state.py — ultra-lightweight
# Sends session state to ClaudeIsland.app via Unix socket
# For PermissionRequest: delegates to Perl for bidirectional I/O
# ─────────────────────────────────────────────────────────────────────────────

SOCKET="${CLAUDE_ISLAND_SOCKET:-/tmp/claude-island.sock}"

# Guard: exit if socket absent or not owned by current user
[ -S "$SOCKET" ] || exit 0
[ "$(stat -f '%u' "$SOCKET" 2>/dev/null)" = "$(id -u)" ] || exit 0

# Read stdin with size limit (max 64 Ko)
INPUT=$(head -c 65536)
[ -z "$INPUT" ] && exit 1

# Extract fields in 1 jq call (batch)
read -r EVENT SID NTYPE <<< "$(printf '%s\n' "$INPUT" | jq -r '[
  (.hook_event_name // ""),
  (.session_id // "unknown"),
  (.notification_type // "")
] | @tsv' 2>/dev/null)"

[ -z "$EVENT" ] && exit 1

# Validate event against whitelist
case "$EVENT" in
  UserPromptSubmit|PreToolUse|PostToolUse|PermissionRequest|\
  Notification|Stop|SubagentStop|SessionStart|SessionEnd|PreCompact) ;;
  *) exit 1 ;;
esac

# PermissionRequest needs bidirectional I/O — delegate to Perl
if [ "$EVENT" = "PermissionRequest" ]; then
  PERL_SCRIPT="$HOME/.claude/hooks/claude-island-state-fast.pl"
  [ -f "$PERL_SCRIPT" ] || exit 1
  [ "$(stat -f '%u' "$PERL_SCRIPT" 2>/dev/null)" = "$(id -u)" ] || exit 1
  printf '%s\n' "$INPUT" | perl "$PERL_SCRIPT"
  exit $?
fi

# Notification: skip permission_prompt (handled by PermissionRequest hook)
if [ "$EVENT" = "Notification" ] && [ "$NTYPE" = "permission_prompt" ]; then
  exit 0
fi

# Map event to status
case "$EVENT" in
  UserPromptSubmit)        STATUS="processing" ;;
  PreToolUse)              STATUS="running_tool" ;;
  PostToolUse)             STATUS="processing" ;;
  Stop|SubagentStop)       STATUS="waiting_for_input" ;;
  SessionStart)            STATUS="waiting_for_input" ;;
  SessionEnd)              STATUS="ended" ;;
  PreCompact)              STATUS="compacting" ;;
  Notification)
    [ "$NTYPE" = "idle_prompt" ] && STATUS="waiting_for_input" || STATUS="notification"
    ;;
esac

# Get TTY (no subprocess for PID — use $PPID)
PPID_VAL=$PPID
TTY_VAL=$(ps -p "$PPID_VAL" -o tty= 2>/dev/null | tr -d ' ')
[ -n "$TTY_VAL" ] && [ "$TTY_VAL" != "??" ] && [ "$TTY_VAL" != "-" ] && TTY_VAL="/dev/$TTY_VAL" || TTY_VAL=""

# Build JSON safely with jq (VULN-02 fix: no bash interpolation)
STATE=$(printf '%s\n' "$INPUT" | jq -c --arg status "$STATUS" --arg pid "$PPID_VAL" --arg tty "$TTY_VAL" '
{
  session_id: (.session_id // "unknown"),
  cwd: (.cwd // ""),
  event: (.hook_event_name // ""),
  pid: ($pid | tonumber),
  status: $status
}
+ (if $tty != "" then {tty: $tty} else {} end)
+ (if (.hook_event_name == "PreToolUse" or .hook_event_name == "PostToolUse") then {
    tool: (.tool_name // ""),
    tool_use_id: (.tool_use_id // "")
  }
  + (if .tool_input then
      {tool_input: (.tool_input | if .command then {command: (.command | tostring | .[0:200])}
                                   elif .file_path then {file_path: .file_path}
                                   elif .pattern then {pattern: .pattern}
                                   else {keys: keys}
                                   end)}
    else {} end)
  else {} end)
+ (if .hook_event_name == "Notification" then {
    notification_type: (.notification_type // ""),
    message: ((.message // "") | .[0:500])
  } else {} end)
')

# Fire and forget — send to socket
printf '%s\n' "$STATE" | nc -U -w1 "$SOCKET" 2>/dev/null
exit 0
