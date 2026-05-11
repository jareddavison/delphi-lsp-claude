---
description: Recycle the entire delphi-lsp shim process (not just DelphiLSP). Use after rebuilding `bin/delphi-lsp-shim.exe` to pick up the new binary without restarting Claude Code. Differs from `/delphi-reload` which only recycles DelphiLSP itself while keeping the shim alive. The next LSP query after this command spawns a fresh shim lazily.
---

!`CLAUDE_PLUGIN_DATA="${CLAUDE_PLUGIN_DATA}" "${CLAUDE_PLUGIN_ROOT}/bin/delphi-lsp-shim.exe" --shim-reload`

The shim filters to only its own Claude Code instance (matched on `claude-session.txt`), so concurrent Claude Code sessions in the same workspace are not affected. If no shim is running yet, the next LSP query spawns a fresh one from the current binary on disk anyway — nothing to do.
