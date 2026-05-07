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

write_atomic() {
  local target="$1"
  local tmp="${target}.tmp"
  printf '%s' "$JSON" > "$tmp"
  mv -f "$tmp" "$target"
}

# Primary key: session_id. The shim does cwd-match on these files.
# Empirically the only key that works on Windows MinGW bash, where
# $PPID resolves to 1 (process tree reparenting from cmd.exe → bash).
write_atomic "$DIR/by-id-$SESSION_ID.json"

# Conditional: only write the PPID-keyed file if PPID looks real
# (>1, not init). Skipping it on Windows avoids spamming claude-pid/1.json
# with whatever session fired the hook last.
if [ "$HOOK_PPID" -gt 1 ] 2>/dev/null; then
  write_atomic "$DIR/$HOOK_PPID.json"
  printf '[%s] wrote by-id and PPID files\n' "$TS" >> "$LOG"
else
  printf '[%s] wrote by-id only (skipped PPID=%d)\n' "$TS" "$HOOK_PPID" >> "$LOG"
fi

# ---- Multi-candidate detection ----
# Goal: if the workspace has >1 .delphilsp.json AND no sticky pick exists
# for this (session, cwd), tell Claude to prompt the user via
# AskUserQuestion. Single-candidate and resumed-with-sticky paths stay
# silent — the shim handles them automatically.

# The shim hashes canonical cwd: lowercase + ExcludeTrailingPathDelimiter
# of the Windows-form path. Reproduce in bash via cygpath + tr + sed.
if command -v cygpath >/dev/null 2>&1; then
  WINCWD="$(cygpath -w "$PWD" 2>/dev/null)"
else
  WINCWD="$PWD"
fi
CWD_NORM="$(printf '%s' "$WINCWD" | tr '[:upper:]' '[:lower:]' | sed 's:[\\/]\+$::')"
CWD_HASH="$(printf '%s' "$CWD_NORM" | sha256sum | awk '{print $1}')"

STICKY_FILE="$DATA/session-state/$SESSION_ID.json"
HAS_STICKY=no
if [ -f "$STICKY_FILE" ] && grep -q "\"$CWD_HASH\"" "$STICKY_FILE" 2>/dev/null; then
  HAS_STICKY=yes
fi

# Enumerate candidates with the same depth/pruning as the shim's
# CollectSettingsFiles (depth 6, skip node_modules/__history/Win32/Win64/.git/.svn).
# `find -maxdepth` is 1-based from current dir; shim's depth is the recursion
# depth which counts the same. Use \( ... \) groups to keep readable.
candidates() {
  find . -maxdepth 6 -type f -iname '*.delphilsp.json' \
    \( -not -path '*/node_modules/*' \) \
    \( -not -path '*/__history/*' \) \
    \( -not -path '*/__recovery/*' \) \
    \( -not -path '*/Win32/*' \) \
    \( -not -path '*/Win64/*' \) \
    \( -not -path '*/.git/*' \) \
    \( -not -path '*/.svn/*' \) \
    2>/dev/null | sed 's:^\./::' | sort
}

CAND_LIST="$(candidates)"
CAND_COUNT="$(printf '%s\n' "$CAND_LIST" | grep -c '\.delphilsp\.json$' || true)"

printf '[%s] sticky=%s candidates=%d\n' "$TS" "$HAS_STICKY" "$CAND_COUNT" >> "$LOG"

# Only emit the prompt if multi-candidate and no sticky. Use stdout so
# Claude Code feeds it back as additional context for the assistant.
if [ "$HAS_STICKY" = "no" ] && [ "$CAND_COUNT" -gt 1 ]; then
  cat <<EOF
The DelphiLSP plugin found $CAND_COUNT .delphilsp.json projects in this workspace and no sticky project pick exists for this session yet. The LSP shim is running syntactic-only — hover, goToDefinition, and push diagnostics will not work until a project is loaded.

Use AskUserQuestion to ask which project to load, then call /delphi-project <name> to load it. Available projects (basename derived from .delphilsp.json filename):

$(printf '%s\n' "$CAND_LIST" | sed 's:^:  - :')
EOF
fi

exit 0
