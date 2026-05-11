---
description: Recycle the DelphiLSP child process for the current workspace's shim. Invoke when the LSP appears to be in a bad state — e.g., hover/goToDefinition results contradict the current file contents, expected diagnostics fail to fire after a deliberate or accidental syntax break, or queries return information that's clearly stale relative to recent edits. The shim kills its DelphiLSP child, spawns a fresh one, and replays the cached `initialize` request, the `initialized` notification, the current `workspace/didChangeConfiguration`, and a synthesized `textDocument/didOpen` for every document the shim has been mirroring — so Claude Code's LSP client sees no disruption. After the recycle (typically <2s for small projects, several seconds for large ones), retry the LSP query that prompted this command. Only invoke when there's actual evidence of LSP confusion; routine queries don't need it.
---

!`CLAUDE_PLUGIN_DATA="${CLAUDE_PLUGIN_DATA}" "${CLAUDE_PLUGIN_ROOT}/bin/delphi-lsp-shim.exe" --reload`

The shim filters to its own Claude Code instance's shim (matched on `claude-session.txt`) — concurrent Claude Code sessions in the same workspace are untouched. The recycle takes <2s for small projects, several seconds for large ones; the LSP client sees no disruption because the shim replays `initialize` / `initialized` / `didChangeConfiguration` / a synthesized `didOpen` per tracked document to the fresh DelphiLSP child.

After this command, retry the LSP query that prompted it. If the first retry returns empty results, give DelphiLSP another second or two and retry once more.
