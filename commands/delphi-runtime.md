---
description: Override which DelphiLSP.exe the shim spawns. By default the shim picks the RAD Studio version hinted by the active .delphilsp.json (the IDE that wrote it), falling back to the highest installed. Use this slash command when you need a different version - e.g. you have multiple RAD Studios installed and want to test against an older one, or the auto-detected version is wrong. Argument is a BDS version like `37.0` (registry-resolved to that install's `bin\DelphiLSP.exe`), an absolute path to a specific `DelphiLSP.exe`, or the literal word `clear` to remove an existing override. The override persists until cleared. Triggers a child recycle so the new server is in effect immediately.
argument-hint: <bds-version | path-to-DelphiLSP.exe | clear>
---

!`CLAUDE_PLUGIN_DATA="${CLAUDE_PLUGIN_DATA}" "${CLAUDE_PLUGIN_ROOT}/bin/delphi-lsp-shim.exe" --set-runtime "$ARGUMENTS"`

**The output above is from the actual shim binary. It is the source of truth — do not paraphrase or simulate it.**

## Argument values

- A BDS version like `37.0` (registry-resolved to that install's `bin\DelphiLSP.exe`).
- An absolute path to a specific `DelphiLSP.exe`.
- The literal word `clear` to remove any existing override.

## What to do based on what you see

| Shim output starts with | What it means | What to do next |
| :--- | :--- | :--- |
| `Runtime override = <value>. Signalling N shim(s) to recycle DelphiLSP.` | Override applied; child recycle in flight. | Wait ~1-2 seconds for DelphiLSP to re-index, then retry the LSP query that prompted this. |
| `No live shim — runtime override deferred until one spawns.` | Sentinel staged; next shim spawn picks it up. | Tell the user the override is queued; the first LSP query in this session will use it. |
| `No runtime override to clear (or no live shim).` (for `clear`) | Nothing to do. | Confirm to user. |
| `Runtime override cleared on N shim(s); recycled.` (for `clear`) | Override removed; DelphiLSP respawning. | Wait briefly, then retry. |
| `No runtime argument provided.` | Empty `$ARGUMENTS`. | Re-invoke with an explicit value (`37.0`, an absolute `.exe` path, or `clear`). |
| `Refusing to set runtime override: could not resolve current Claude Code session id.` | Multi-session edge case. | Tell the user; do not paper over. |
| (no output, or `Shell command permission check failed`) | The `!`-block was denied. | **STOP. Do not improvise.** Tell the user: "Add `Bash(*delphi-lsp-shim*)` to the `permissions.allow` array in `~/.claude/settings.json` (or run `/update-config` and ask Claude to add it)." |

## Hard rules

- **Never write bash, PowerShell, or any script that touches `runtime.txt`, `reload.flag`, or any file under `${CLAUDE_PLUGIN_DATA}`.** The shim handles atomicity, recycle signalling, and session-id matching.
- **Never simulate the shim's output.** If the `!`-block produced no text, surface that to the user — do not invent a substitute.

The shim's filter scopes effects to this Claude Code session — concurrent Claude Code sessions can have different runtime overrides without interfering.
