---
description: Switch the active DelphiLSP project context. Invoke when starting work on files from a different .dproj/.delphilsp.json than the currently loaded one — typical signals are the user mentioning a different project by name, or you're about to open a file under a different project subtree (e.g. a unit test project alongside the main project). Without switching first, hover/goToDefinition results may be stale or wrong because DelphiLSP only loads one project's search paths and conditional defines at a time. Argument is a path to a `.delphilsp.json` (absolute or relative to the workspace), or a project name to match against discovered files.
argument-hint: <path-to-.delphilsp.json | project-name>
---

!`CLAUDE_PLUGIN_DATA="${CLAUDE_PLUGIN_DATA}" "${CLAUDE_PLUGIN_ROOT}/bin/delphi-lsp-shim.exe" --set-project "$ARGUMENTS"`

The output above reports how the argument was resolved. Resolution rules (first match wins):

1. Absolute path that exists and is a `.delphilsp.json`.
2. Relative path under the workspace that ends in `.delphilsp.json` and exists.
3. Name match: strips a trailing `.dproj`/`.dpr`/`.dpk`/`.delphilsp.json` from the argument and searches the workspace for `*<base>*.delphilsp.json`, picks the shallowest match (case-insensitive). So `DemoProj.dproj`, `DemoProj`, and `demoproj.delphilsp.json` all resolve to the same file.

The shim filters to this Claude Code session's shim (`claude-session.txt` match). Concurrent Claude Code sessions in the same workspace can have different active projects without colliding.

After switching, retry the LSP query that prompted the switch. The shim's sentinel watcher picks up `active.txt` within a fraction of a second; if the first retry returns empty, give DelphiLSP another second to re-index and retry once more.
