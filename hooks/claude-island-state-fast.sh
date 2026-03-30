#!/usr/bin/env bash
# claude-island-state-fast.sh
# Drop-in replacement for claude-island-state.py — ultra-lightweight bash version
# Uses jq (1 call) + nc (1 call) = 2 processes vs Python's ~8 processes
#
# For PermissionRequest: falls back to Perl for bidirectional socket I/O
# For all other events: fire-and-forget via nc -U
# ─────────────────────────────────────────────────────────────────────────────

SOCKET="/tmp/claude-island.sock"

# Guard: exit immediately if socket doesn't exist (app not running)
[ -S "$SOCKET" ] || exit 0

# Read stdin once
INPUT=$(cat)

# Extract all needed fields in 1 jq call
read -r EVENT SID CWD TOOL TOOL_ID NTYPE MSG < <(echo "$INPUT" | jq -r '[
  (.hook_event_name // ""),
  (.session_id // "unknown"),
  (.cwd // ""),
  (.tool_name // ""),
  (.tool_use_id // ""),
  (.notification_type // ""),
  (.message // "")
] | @tsv' 2>/dev/null)

[ -z "$EVENT" ] && exit 1

# Get parent PID and TTY
PPID_VAL=$PPID
TTY=$(ps -p "$PPID_VAL" -o tty= 2>/dev/null | tr -d ' ')
[ -n "$TTY" ] && [ "$TTY" != "??" ] && [ "$TTY" != "-" ] && TTY="/dev/$TTY" || TTY=""

# Map event to status
case "$EVENT" in
  UserPromptSubmit) STATUS="processing" ;;
  PreToolUse)       STATUS="running_tool" ;;
  PostToolUse)      STATUS="processing" ;;
  Stop|SubagentStop) STATUS="waiting_for_input" ;;
  SessionStart)     STATUS="waiting_for_input" ;;
  SessionEnd)       STATUS="ended" ;;
  PreCompact)       STATUS="compacting" ;;
  Notification)
    [ "$NTYPE" = "permission_prompt" ] && exit 0
    [ "$NTYPE" = "idle_prompt" ] && STATUS="waiting_for_input" || STATUS="notification"
    ;;
  PermissionRequest)
    # PermissionRequest needs bidirectional I/O — delegate to Perl version
    SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
    echo "$INPUT" | perl "$SCRIPT_DIR/claude-island-state-fast.pl"
    exit $?
    ;;
  *) STATUS="unknown" ;;
esac

# Build minimal JSON (avoid jq for output — pure bash is faster)
STATE="{\"session_id\":\"$SID\",\"cwd\":\"$CWD\",\"event\":\"$EVENT\",\"pid\":$PPID_VAL,\"status\":\"$STATUS\""

# Add TTY if available
[ -n "$TTY" ] && STATE="$STATE,\"tty\":\"$TTY\""

# Add tool info for Pre/PostToolUse
if [ "$EVENT" = "PreToolUse" ] || [ "$EVENT" = "PostToolUse" ]; then
  STATE="$STATE,\"tool\":\"$TOOL\""
  [ -n "$TOOL_ID" ] && STATE="$STATE,\"tool_use_id\":\"$TOOL_ID\""
  # tool_input as raw JSON from jq
  TI=$(echo "$INPUT" | jq -c '.tool_input // {}' 2>/dev/null)
  STATE="$STATE,\"tool_input\":$TI"
fi

# Add notification fields
if [ "$EVENT" = "Notification" ]; then
  STATE="$STATE,\"notification_type\":\"$NTYPE\",\"message\":\"$MSG\""
fi

STATE="$STATE}"

# Fire and forget — send to socket
echo "$STATE" | nc -U -w1 "$SOCKET" 2>/dev/null
exit 0
