---
description: Switch the active DelphiLSP project context. Invoke when starting work on files from a different .dproj/.delphilsp.json than the currently loaded one — typical signals are the user mentioning a different project by name, or you're about to open a file under a different project subtree (e.g. a unit test project alongside the main project). Without switching first, hover/goToDefinition results may be stale or wrong because DelphiLSP only loads one project's search paths and conditional defines at a time. Argument is a path to a `.delphilsp.json` (absolute or relative to the workspace), or a project name to match against discovered files.
argument-hint: <path-to-.delphilsp.json | project-name>
---

Switch the active DelphiLSP project to **$ARGUMENTS**.

Resolution order, in this order — pick the first that exists:

1. If `$ARGUMENTS` ends in `.delphilsp.json` and is an absolute path that exists, use it directly.
2. If `$ARGUMENTS` is a relative path that resolves to an existing file under the workspace, use that.
3. Otherwise treat `$ARGUMENTS` as a name and search the workspace recursively for `*$ARGUMENTS*.delphilsp.json` (case-insensitive). Pick the shallowest match.

Then:

1. Locate the shim's session sentinel directories. Claude Code exports `$CLAUDE_PLUGIN_DATA` to LSP subprocesses but NOT to the bash subprocess running this slash command, so the data dir name (e.g. `delphi-lsp-inline`, `delphi-lsp-some-marketplace`) isn't directly knowable here. Instead, scan candidate roots and match by workspace:
   - `$HOME/.claude/plugins/data/*/sessions/<PID>/workspace.txt`
   - `$LOCALAPPDATA/delphi-lsp-claude/sessions/<PID>/workspace.txt` (fallback if CLAUDE_PLUGIN_DATA wasn't available to the shim either)
2. For each candidate `workspace.txt`, read its first line and compare to the current working directory (resolve symlinks before comparing). Collect every `<PID>` directory whose workspace matches. If none match, tell the user the LSP server isn't running for this workspace yet — they should retry after Claude Code finishes loading the plugin.
3. For each matching `<PID>` dir, atomically write the resolved `.delphilsp.json` path to `<PID>/active.txt` using a temp-file-then-rename pattern (`printf '%s' "$path" > active.txt.tmp && mv -f active.txt.tmp active.txt`) so the shim never reads a half-written file.
4. Confirm to the user which `.delphilsp.json` is now active and how many shims received the switch.

If no shim is registered (the sessions dir is missing or has no matching workspace), tell the user that the LSP server isn't running for this workspace yet — once it starts, the shim will pick up `active.txt` automatically if it's already there, but the user should retry the slash command after Claude Code finishes loading the plugin.

After switching, retry the LSP query that prompted this switch. DelphiLSP needs a moment to re-read the project state (typically <1s for small projects, several seconds for large ones); if the first retry returns empty results, retry once more after a brief pause.
