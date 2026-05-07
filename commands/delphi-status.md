---
description: Show the current DelphiLSP shim state for this workspace — registered shim PIDs, which `.delphilsp.json` each is using as its active project, and what other `.delphilsp.json` files are available to switch to via `/delphi-project`. Read-only; safe to invoke any time.
---

Inspect the DelphiLSP shim state for the current workspace.

1. Compute the workspace key for matching: take the bash CWD via `pwd -W` (Windows-form, forward slashes) and translate `/` → `\` so it matches what the shim writes into `workspace.txt` (Delphi's `GetCurrentDir` output uses backslashes).

2. Scan candidate session-registration roots:
   - `$HOME/.claude/plugins/data/*/sessions/*/workspace.txt`
   - `$LOCALAPPDATA/delphi-lsp-claude/sessions/*/workspace.txt` (fallback path the shim uses when `CLAUDE_PLUGIN_DATA` isn't exported)

3. For each candidate, read its first line (strip UTF-8 BOM with `sed -e '1s/^\xef\xbb\xbf//'`). If it matches the current workspace key, the directory's basename is the shim PID. Verify the PID is still alive — on Windows, query via `tasklist /FI "PID eq <pid>"` or PowerShell `Get-Process -Id <pid>`. Skip dead PIDs (orphaned dirs from previous shim runs that didn't unregister cleanly).

4. For each *live* matching shim, read `active.txt` from the same dir. If present and non-empty: that's the explicitly-selected project. If missing or empty: the shim is using its auto-discovered settings file (the shallowest `*.delphilsp.json` under the workspace, alphabetical tiebreak).

5. List all `*.delphilsp.json` files in the workspace (excluding common ignore dirs: `__history`, `__recovery`, `Win32`, `Win64`, `node_modules`, `.git`).

6. Format the output as a compact summary. Lead with the active project for each live shim, then list the other available projects underneath. If multiple live shims exist (concurrent Claude Code sessions on this workspace), note that they may have different active projects. If no live shim is registered, say so and remind the user that `/delphi-project <path>` written *now* will be picked up by the shim when Claude Code next spawns it.

Suggested output shape:

```
DelphiLSP shim status
---------------------
Workspace: D:\Documents\TestDproj
Live shims: 1

  PID 4832  active = Lsp2Test.delphilsp.json (auto-discovered)

Available .delphilsp.json files:
  Lsp2Test.delphilsp.json     <- active
  TestForLSP.delphilsp.json

Switch with: /delphi-project <name|path>
```
