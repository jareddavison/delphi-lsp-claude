---
description: Switch the active DelphiLSP project context. Invoke when starting work on files from a different .dproj/.delphilsp.json than the currently loaded one — typical signals are the user mentioning a different project by name, or you're about to open a file under a different project subtree (e.g. a unit test project alongside the main project). Without switching first, hover/goToDefinition results may be stale or wrong because DelphiLSP only loads one project's search paths and conditional defines at a time. Argument is a path to a `.delphilsp.json` (absolute or relative to the workspace), or a project name to match against discovered files.
argument-hint: <path-to-.delphilsp.json | project-name>
---

!`CLAUDE_PLUGIN_DATA="${CLAUDE_PLUGIN_DATA}" "${CLAUDE_PLUGIN_ROOT}/bin/delphi-lsp-shim.exe" --set-project "$ARGUMENTS"`

**The output above is from the actual shim binary. It is the source of truth — do not paraphrase or simulate it.**

## How to read the output

The shim resolves the argument and writes `active.txt` to every shim it owns in this workspace. Resolution rules (first match wins):

1. Absolute path that exists and is a `.delphilsp.json`.
2. Relative path under the workspace that ends in `.delphilsp.json` and exists.
3. Name match: strips a trailing `.dproj`/`.dpr`/`.dpk`/`.delphilsp.json` from the argument and searches the workspace for `*<base>*.delphilsp.json`, picks the shallowest match (case-insensitive). So `DemoProj.dproj`, `DemoProj`, and `demoproj.delphilsp.json` all resolve to the same file.

## What to do based on what you see

| Shim output starts with | What it means | What to do next |
| :--- | :--- | :--- |
| `Resolved: <path>` | The argument was accepted; sentinel written. | Done. To verify, run `Skill(skill="delphi-lsp:delphi-status")` and confirm the listed `active project` matches. Then retry whatever LSP query prompted the switch. |
| `No project argument provided.` | You called this command with empty `$ARGUMENTS`. | Run `Skill(skill="delphi-lsp:delphi-status")` to enumerate available `.delphilsp.json` files in this workspace. Pick one by basename. Then re-invoke `Skill(skill="delphi-lsp:delphi-project", args="<basename>")`. |
| `Could not resolve to a .delphilsp.json: <arg>` | The argument didn't match any file. | Run `Skill(skill="delphi-lsp:delphi-status")` to see what exists. Then re-invoke this command with one of those names. |
| `Refusing to set active project: could not resolve current Claude Code session id.` | Session-id correlation failed; another Claude session may own the shim. | Tell the user; this is a multi-session edge case the shim deliberately won't paper over. |
| (no output, or `Shell command permission check failed`) | The `!`-block was denied by the permission system. | **STOP. Do not improvise.** Tell the user: "Add `Bash(*delphi-lsp-shim*)` to the `permissions.allow` array in `~/.claude/settings.json` (or run `/update-config` and ask Claude to add it). See the plugin README." |

## Hard rules

- **Never write bash, PowerShell, or any script that touches `active.txt`, `sessions/`, `claude-pid/`, `session-state/`, or any file under `${CLAUDE_PLUGIN_DATA}`.** The shim handles all atomicity, path canonicalization, BOM stripping, and session-id matching. Improvised filesystem manipulation skips those guarantees and silently corrupts state.
- **Never simulate the shim's output.** The `!`-block output above is the only authoritative source. If it's missing or you don't trust it, surface that to the user — do not generate a plausible-looking substitute.
- **Always verify after a change**: re-invoke `Skill(skill="delphi-lsp:delphi-status")` and confirm the `active project` matches what you intended. Do not declare success based on the `Resolved:` line alone.

After a successful switch, retry the LSP query that prompted it. The shim's sentinel watcher picks up `active.txt` within a fraction of a second; if the first retry returns empty, give DelphiLSP another second to re-index and retry once more.
