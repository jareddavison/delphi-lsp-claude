---
description: Recycle the entire delphi-lsp shim process (not just DelphiLSP). Use after rebuilding `bin/delphi-lsp-shim.exe` to pick up the new binary without restarting Claude Code. Differs from `/delphi-reload` which only recycles DelphiLSP itself while keeping the shim alive. The next LSP query after this command spawns a fresh shim lazily.
---

!`CLAUDE_PLUGIN_DATA="${CLAUDE_PLUGIN_DATA}" "${CLAUDE_PLUGIN_ROOT}/bin/delphi-lsp-shim.exe" --shim-reload`

**The output above is from the actual shim binary. It is the source of truth — do not paraphrase or simulate it.**

## What to do based on what you see

| Shim output | What to do |
| :--- | :--- |
| `Signaled N shim(s) to exit. Next LSP query will spawn a fresh one.` | The running shim is exiting. Next LSP query auto-respawns. |
| `No live shim to reload. The next LSP query will spawn one from the current binary on disk.` | Nothing to do — fresh binary will load lazily on demand. |
| `Refusing to reload shim: could not resolve current Claude Code session id.` | Multi-session edge case. Surface to user. |
| (no output, or `Shell command permission check failed`) | The `!`-block was denied. **STOP.** Tell the user: "Add `Bash(*delphi-lsp-shim*)` to the `permissions.allow` array in `~/.claude/settings.json` (or run `/update-config`)." |

## Hard rules

- **Never write bash, PowerShell, or any script that kills the shim process directly or touches files under `${CLAUDE_PLUGIN_DATA}`.** Use only this command's `!`-block.
- **Never simulate the shim's output.** If the `!`-block produced no text, surface the permission/install problem.
