---
description: Override which DelphiLSP.exe the shim spawns. By default the shim picks the RAD Studio version hinted by the active .delphilsp.json (the IDE that wrote it), falling back to the highest installed. Use this slash command when you need a different version - e.g. you have multiple RAD Studios installed and want to test against an older one, or the auto-detected version is wrong. Argument is a BDS version like `37.0` (registry-resolved to that install's `bin\DelphiLSP.exe`), an absolute path to a specific `DelphiLSP.exe`, or the literal word `clear` to remove an existing override. The override persists until cleared. Triggers a child recycle so the new server is in effect immediately.
argument-hint: <bds-version | path-to-DelphiLSP.exe | clear>
---

!`CLAUDE_PLUGIN_DATA="${CLAUDE_PLUGIN_DATA}" "${CLAUDE_PLUGIN_ROOT}/bin/delphi-lsp-shim.exe" --set-runtime "$ARGUMENTS"`

The argument is either:

- A BDS version like `37.0` (registry-resolved to that install's `bin\DelphiLSP.exe`).
- An absolute path to a specific `DelphiLSP.exe`.
- The literal word `clear` to remove any existing override.

After writing `runtime.txt`, the shim auto-triggers a child recycle so the new DelphiLSP is in effect immediately. The override is filtered to this Claude Code session's shim — concurrent Claude Code sessions can have different runtime overrides without interfering.

After the command, retry the LSP query that prompted it. The recycle is asynchronous; give DelphiLSP a moment to re-index before the first retry.
