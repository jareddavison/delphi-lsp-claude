---
description: Override which DelphiLSP.exe the shim spawns. By default the shim picks the RAD Studio version hinted by the active .delphilsp.json (the IDE that wrote it), falling back to the highest installed. Use this slash command when you need a different version - e.g. you have multiple RAD Studios installed and want to test against an older one, or the auto-detected version is wrong. Argument is a BDS version like `37.0` (registry-resolved to that install's `bin\DelphiLSP.exe`) or an absolute path to a specific `DelphiLSP.exe`. The override persists until cleared by `/delphi-runtime clear`. Triggers a child recycle so the new server is in effect immediately.
argument-hint: <bds-version | path-to-DelphiLSP.exe | clear>
---

Set or clear the DelphiLSP runtime override for this Claude Code session's shim.

If the argument is the literal `clear` (case-insensitive):

```bash
"${CLAUDE_PLUGIN_ROOT}/bin/delphi-lsp-shim.exe" --clear-runtime
```

Otherwise:

```bash
"${CLAUDE_PLUGIN_ROOT}/bin/delphi-lsp-shim.exe" --set-runtime "$ARGUMENTS"
```

The argument is either a BDS version like `37.0` (registry-resolved to that install's `bin\DelphiLSP.exe`) or an absolute path to a specific `DelphiLSP.exe`. After writing `runtime.txt`, the shim auto-triggers a child recycle so the new DelphiLSP is in effect immediately.

Filters to this Claude Code session's shim — concurrent Claude Code sessions can have different runtime overrides without interfering.

After the command, retry the LSP query that prompted it. The recycle is asynchronous; give DelphiLSP a moment to re-index before the first retry.
