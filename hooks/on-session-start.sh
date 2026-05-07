#!/usr/bin/env bash
# delphi-lsp-claude SessionStart hook.
#
# Records (session_id, cwd, hook_ppid) so the shim can resolve its
# own session id race-free. The shim parses processId from the LSP
# initialize request — that PID is whoever spawned the LSP server.
# If Claude Code spawns hooks AND LSP servers from the same parent
# process, the hook's PPID equals the shim's processId, and a file
# keyed by either PID gives the same answer. We write under both
# keys for resilience plus reverse-lookup-by-cwd for diagnostics.
#
# Stdin: SessionStart hook payload — JSON with session_id, transcript_path,
# hook_event_name, source ("startup" or "resume"), etc.
#
# Env: $CLAUDE_PLUGIN_DATA, $CLAUDE_PLUGIN_ROOT supplied by Claude Code.

set -u

PAYLOAD="$(cat)"

# Avoid a jq dependency: extract via sed. Hook payloads are JSON objects
# small enough that the regex stays readable.
extract_field() {
  local field="$1"
  printf '%s' "$PAYLOAD" \
    | sed -n "s/.*\"$field\"[[:space:]]*:[[:space:]]*\"\\([^\"]*\\)\".*/\\1/p" \
    | head -1
}

SESSION_ID="$(extract_field session_id)"
HOOK_EVENT="$(extract_field hook_event_name)"
SOURCE="$(extract_field source)"

# CLAUDE_PLUGIN_DATA must match what the shim's ResolvePluginDataBase
# computes (CLAUDE_PLUGIN_DATA env, or LOCALAPPDATA/delphi-lsp-claude
# fallback). The hook gets CLAUDE_PLUGIN_DATA exported by Claude Code,
# so use it directly — fallback only if missing.
DATA="${CLAUDE_PLUGIN_DATA:-${LOCALAPPDATA:-}/delphi-lsp-claude}"
DIR="$DATA/claude-pid"
LOG_DIR="$DATA/hook-logs"
mkdir -p "$DIR" "$LOG_DIR"

LOG="$LOG_DIR/on-session-start.log"
TS="$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ)"
HOOK_PID=$$
HOOK_PPID=$PPID

{
  printf '[%s] --- SessionStart fired ---\n' "$TS"
  printf '[%s] hook_pid=%d hook_ppid=%d\n' "$TS" "$HOOK_PID" "$HOOK_PPID"
  printf '[%s] cwd=%s\n' "$TS" "$PWD"
  printf '[%s] CLAUDE_PLUGIN_DATA=%s\n' "$TS" "${CLAUDE_PLUGIN_DATA:-}"
  printf '[%s] CLAUDE_PLUGIN_ROOT=%s\n' "$TS" "${CLAUDE_PLUGIN_ROOT:-}"
  printf '[%s] CLAUDE_CODE_SESSION_ID=%s\n' "$TS" "${CLAUDE_CODE_SESSION_ID:-}"
  printf '[%s] hook_event_name=%s source=%s\n' "$TS" "$HOOK_EVENT" "$SOURCE"
  printf '[%s] payload=%s\n' "$TS" "$PAYLOAD"
} >> "$LOG"

# If we couldn't get a session_id, fall back to env var (which the hook DOES
# see, unlike the LSP subprocess). Bail if neither yielded anything useful.
if [ -z "$SESSION_ID" ]; then
  SESSION_ID="${CLAUDE_CODE_SESSION_ID:-}"
fi
if [ -z "$SESSION_ID" ]; then
  printf '[%s] WARN: no session_id in payload or env; bailing out\n' "$TS" >> "$LOG"
  exit 0
fi

printf '[%s] resolved session_id=%s\n' "$TS" "$SESSION_ID" >> "$LOG"

# JSON payload to write. Quoting via printf %s — values shouldn't contain
# embedded quotes, but we're permissive about CWD which can have spaces.
JSON=$(printf '{"session_id":"%s","cwd":"%s","hook_pid":%d,"hook_ppid":%d,"timestamp":"%s","source":"%s"}' \
  "$SESSION_ID" "$PWD" "$HOOK_PID" "$HOOK_PPID" "$TS" "$SOURCE")

# Atomic write keyed by hook PPID (= Claude Code's process, expected to
# match the shim's processId from LSP initialize).
write_atomic() {
  local target="$1"
  local tmp="${target}.tmp"
  printf '%s' "$JSON" > "$tmp"
  mv -f "$tmp" "$target"
}

write_atomic "$DIR/$HOOK_PPID.json"
write_atomic "$DIR/by-id-$SESSION_ID.json"

printf '[%s] wrote %s and %s\n' "$TS" "$DIR/$HOOK_PPID.json" "$DIR/by-id-$SESSION_ID.json" >> "$LOG"

exit 0
