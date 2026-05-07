---
description: Recycle the DelphiLSP child process for the current workspace's shim. Invoke when the LSP appears to be in a bad state — e.g., hover/goToDefinition results contradict the current file contents, expected diagnostics fail to fire after a deliberate or accidental syntax break, or queries return information that's clearly stale relative to recent edits. The shim kills its DelphiLSP child, spawns a fresh one, and replays the cached `initialize` request, the `initialized` notification, the current `workspace/didChangeConfiguration`, and a synthesized `textDocument/didOpen` for every document the shim has been mirroring — so Claude Code's LSP client sees no disruption. After the recycle (typically <2s for small projects, several seconds for large ones), retry the LSP query that prompted this command. Only invoke when there's actual evidence of LSP confusion; routine queries don't need it.
---

Recycle the DelphiLSP child process for the current workspace's shim.

1. Compute the workspace key for matching: bash `pwd -W` translated `/` → `\` so it matches the shim's `workspace.txt` (Windows form).
2. Scan candidate session-registration roots:
   - `$HOME/.claude/plugins/data/*/sessions/*/workspace.txt`
   - `$LOCALAPPDATA/delphi-lsp-claude/sessions/*/workspace.txt`
3. For each `workspace.txt`, read the first line (strip UTF-8 BOM with `sed -e '1s/^\xef\xbb\xbf//'`). If it equals the workspace key, the directory's basename is a shim PID.
4. Verify the PID is live via `tasklist //FI "PID eq <pid>"`. Skip dead PIDs (orphans).
5. For each *live* matching session dir, atomically write `reload.flag`:
   ```bash
   printf 'reload' > "${dir}reload.flag.tmp" && mv -f "${dir}reload.flag.tmp" "${dir}reload.flag"
   ```
   (The flag's content doesn't matter — the shim only checks for existence and deletes after consuming.)
6. Confirm to the user how many shims received the reload signal. If zero, tell them no shim is currently running for this workspace; they can retry after Claude Code spawns one (typically on the next LSP query).
7. After signaling, retry the LSP query that prompted this command. The shim recycle is asynchronous from the slash command's perspective — give DelphiLSP a brief moment (~1s) to re-index before the first retry; if the retry returns empty, retry once more after a short pause.
