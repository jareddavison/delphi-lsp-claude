---
description: Recycle the entire delphi-lsp shim process (not just DelphiLSP). Use after rebuilding `bin/delphi-lsp-shim.exe` to pick up the new binary without restarting Claude Code. Differs from `/delphi-reload` which only recycles DelphiLSP itself while keeping the shim alive. The next LSP query after this command spawns a fresh shim lazily.
---

Exit the running delphi-lsp shim so Claude Code's LSP integration spawns a fresh one (lazily, on next LSP request) with whatever `delphi-lsp-shim.exe` is currently on disk.

Resolution: scan candidate session-registration roots for shim PIDs registered against the current workspace, then signal each by writing `shim-reload.flag`.

1. Compute the workspace key the same way `workspace.txt` was written: bash `pwd -W` (Windows path form), `/` → `\`. The shim writes UTF-8 with a BOM, so strip it before comparison.
2. Scan candidate roots:
   - `$HOME/.claude/plugins/data/*/sessions/*/workspace.txt`
   - `$LOCALAPPDATA/delphi-lsp-claude/sessions/*/workspace.txt`
3. For each `workspace.txt`, read its first line (strip UTF-8 BOM with `sed -e '1s/^\xef\xbb\xbf//'`). If it equals the workspace key, the directory's basename is a shim PID.
4. Verify the PID is live via `tasklist //FI "PID eq <pid>"`. Skip dead PIDs (orphans).
5. For each *live* matching session dir, atomically write `shim-reload.flag`:
   ```bash
   printf 'shim-reload' > "${dir}shim-reload.flag.tmp" && mv -f "${dir}shim-reload.flag.tmp" "${dir}shim-reload.flag"
   ```
   The flag's content doesn't matter — the shim only checks for existence and deletes after consuming.
6. Confirm to the user how many shims received the signal. If zero, no shim is currently running for this workspace; tell the user that's fine — when the LSP integration next spawns one, it'll pick up the new binary anyway.

After the shim exits, the next LSP query (hover, goToDefinition, etc.) spawns a fresh shim with the updated binary. The new shim re-resolves session id, re-reads sticky bindings, and re-spawns DelphiLSP — back to a working state. There's no need to retry an LSP query immediately; just continue normally.
