---
description: Show the current DelphiLSP shim state for this workspace — registered shim PIDs, which `.delphilsp.json` each is using as its active project, and what other `.delphilsp.json` files are available to switch to via `/delphi-project`. Read-only; safe to invoke any time.
---

!`CLAUDE_PLUGIN_DATA="${CLAUDE_PLUGIN_DATA}" "${CLAUDE_PLUGIN_ROOT}/bin/delphi-lsp-shim.exe" --status`

**The output above is from the actual shim binary. It is the source of truth — do not paraphrase or simulate it.**

## How to read the output

- **Workspace** is the cwd the shim resolved.
- **My Claude session** is the Claude Code session id this command resolved to (or `<could not resolve>` if hook correlation files are missing).
- **Shims** section lists every registered shim for this workspace. Each row shows PID, `[alive]`/`[dead - will be GC'd]`, `[MINE]` if owned by the current Claude session, plus its `active project` and any `runtime override`.
- **Available .delphilsp.json files** is what `/delphi-project <name>` can switch to.

## What to do based on what you see

| Pattern | What to do |
| :--- | :--- |
| `Shims: none registered for this workspace.` AND `Hint: no live shim. Make any LSP query...` | This is normal before any LSP query. Make a real LSP query (hover, documentSymbol, etc.) on a `.pas`/`.dpr` file to spawn the shim, then re-run this command. |
| `Shims for this workspace (...)` with `[MINE]` row | A shim is running and belongs to this session. Relay the active project and any other relevant fields. |
| `[MINE]` is absent but other shims are listed | Another concurrent Claude Code session owns the running shims. Make an LSP query to spawn one for this session. |
| (no output, or `Shell command permission check failed`) | The `!`-block was denied. **STOP.** Tell the user: "Add `Bash(*delphi-lsp-shim*)` to the `permissions.allow` array in `~/.claude/settings.json` (or run `/update-config`)." Do not generate substitute output. |

## Hard rules

- **Never write bash, PowerShell, or any script that walks `sessions/`, reads `workspace.txt`, or otherwise re-implements `--status` in script.** The shim handles canonical path comparison (slash-direction, drive letter case, BOM stripping). Anything you write will get it wrong on at least one of those.
- **Never simulate the shim's output.** If the `!`-block produced no text, the user has a permission or install problem — surface it, don't paper over it with a plausible-looking fake.
