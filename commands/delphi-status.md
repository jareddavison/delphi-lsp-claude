---
description: Show the current DelphiLSP shim state for this workspace — registered shim PIDs, which `.delphilsp.json` each is using as its active project, and what other `.delphilsp.json` files are available to switch to via `/delphi-project`. Read-only; safe to invoke any time.
---

!`CLAUDE_PLUGIN_DATA="${CLAUDE_PLUGIN_DATA}" "${CLAUDE_PLUGIN_ROOT}/bin/delphi-lsp-shim.exe" --status`

The output above is the current DelphiLSP shim state for this workspace. It shows:

- Workspace path and the Claude Code session id this slash-command run resolved to (or `<could not resolve>` if it can't tell).
- Each registered shim: PID, alive/dead, which Claude session owns it (`[MINE]` marks the one belonging to this Claude Code session), the active project, and any runtime override.
- All `.delphilsp.json` files in the workspace — these are what `/delphi-project <name>` can switch between.

If no live shim is registered yet, the output explains how to trigger one: make any LSP query (hover, goToDefinition, etc.) on a `.pas`/`.dpr` file. The shim spawns lazily on the first such query.

When multiple Claude Code sessions are running in this workspace, `[MINE]` marks the one this slash command run belongs to — the others are sibling instances and won't be touched by `/delphi-project`, `/delphi-shim-reload`, etc.
