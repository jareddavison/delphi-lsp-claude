---
description: Show the current DelphiLSP shim state for this workspace — registered shim PIDs, which `.delphilsp.json` each is using as its active project, and what other `.delphilsp.json` files are available to switch to via `/delphi-project`. Read-only; safe to invoke any time.
---

Run the shim binary in argv mode to print status. The shim does all the workspace matching, Claude-session disambiguation, and PID-liveness checks itself — no bash logic needed in the slash command.

```bash
"${CLAUDE_PLUGIN_ROOT}/bin/delphi-lsp-shim.exe" --status
```

The output shows:

- Current workspace path.
- The Claude Code session id this slash-command run resolved to (or `<could not resolve>` if it can't tell).
- Each registered shim for this workspace: PID, alive/dead, which Claude session owns it (with `[MINE]` flag when it matches yours), the active project, any runtime override.
- All `.delphilsp.json` files in the workspace, so you know what `/delphi-project <name>` could pick.

If no shim is running yet (common right after Claude Code starts), the output explains how to trigger one: make any LSP query (hover, goToDefinition, etc.) on a .pas/.dpr file. The shim spawns lazily.

If multiple Claude Code sessions are running in this workspace, the `[MINE]` annotation marks the one this slash command belongs to — the others are sibling instances and won't be touched by `/delphi-project`, `/delphi-shim-reload`, etc.
