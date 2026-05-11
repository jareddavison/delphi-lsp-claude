---
description: Recycle the DelphiLSP child process for the current workspace's shim. Invoke when the LSP appears to be in a bad state — e.g., hover/goToDefinition results contradict the current file contents, expected diagnostics fail to fire after a deliberate or accidental syntax break, or queries return information that's clearly stale relative to recent edits. The shim kills its DelphiLSP child, spawns a fresh one, and replays the cached `initialize` request, the `initialized` notification, the current `workspace/didChangeConfiguration`, and a synthesized `textDocument/didOpen` for every document the shim has been mirroring — so Claude Code's LSP client sees no disruption. After the recycle (typically <2s for small projects, several seconds for large ones), retry the LSP query that prompted this command. Only invoke when there's actual evidence of LSP confusion; routine queries don't need it.
---

!`CLAUDE_PLUGIN_DATA="${CLAUDE_PLUGIN_DATA}" "${CLAUDE_PLUGIN_ROOT}/bin/delphi-lsp-shim.exe" --reload`

**The output above is from the actual shim binary. It is the source of truth — do not paraphrase or simulate it.**

## What to do based on what you see

| Shim output | What to do |
| :--- | :--- |
| `Signaled N shim(s) to recycle their DelphiLSP child.` | Recycle in flight. Wait <2s (small project) or several seconds (large project), then retry the LSP query that prompted this. |
| `No live shim to reload — nothing to recycle.` | No shim is running for this Claude session. Make any LSP query to spawn one — there's nothing to recycle. |
| `Refusing to recycle DelphiLSP child: could not resolve current Claude Code session id.` | Multi-session edge case. Surface to user. |
| (no output, or `Shell command permission check failed`) | The `!`-block was denied. **STOP.** Tell the user: "Add `Bash(*delphi-lsp-shim*)` to the `permissions.allow` array in `~/.claude/settings.json` (or run `/update-config`)." |

## Hard rules

- **Never write bash, PowerShell, or any script that touches `reload.flag` or files under `${CLAUDE_PLUGIN_DATA}`.** The shim's atomic-write + watcher path is the only correct way to signal a recycle.
- **Never simulate the shim's output.** If the `!`-block produced no text, surface the permission/install problem — don't invent a result.
