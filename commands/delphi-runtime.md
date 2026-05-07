---
description: Override which DelphiLSP.exe the shim spawns. By default the shim picks the RAD Studio version hinted by the active .delphilsp.json (the IDE that wrote it), falling back to the highest installed. Use this slash command when you need a different version - e.g. you have multiple RAD Studios installed and want to test against an older one, or the auto-detected version is wrong. Argument is a BDS version like `37.0` (registry-resolved to that install's `bin\DelphiLSP.exe`) or an absolute path to a specific `DelphiLSP.exe`. The override persists until cleared by `/delphi-runtime clear`. Triggers a child recycle so the new server is in effect immediately.
argument-hint: <bds-version | path-to-DelphiLSP.exe | clear>
---

Set or clear the per-shim DelphiLSP runtime override to **$ARGUMENTS**.

1. Compute the workspace key for matching: bash `pwd -W` translated `/` to `\` so it matches the shim's `workspace.txt`.

2. Scan candidate session-registration roots:
   - `$HOME/.claude/plugins/data/*/sessions/*/workspace.txt`
   - `$LOCALAPPDATA/delphi-lsp-claude/sessions/*/workspace.txt`

3. For each `workspace.txt`, read the first line (strip UTF-8 BOM with `sed -e '1s/^\xef\xbb\xbf//'`). If it equals the workspace key, the directory's basename is a shim PID. Verify the PID is live via `tasklist //FI "PID eq <pid>"`. Skip dead PIDs.

4. Interpret `$ARGUMENTS`:
   - Literal `clear` (case-insensitive): delete `<dir>/runtime.txt` from each matching shim dir.
   - Anything else: write `$ARGUMENTS` to `<dir>/runtime.txt` atomically (`printf '%s' "$arg" > runtime.txt.tmp && mv -f runtime.txt.tmp runtime.txt`). The shim accepts either a BDS version like `37.0` (looked up in the registry) or an absolute path to a `DelphiLSP.exe` (must contain `\` or `/` or end in `.exe`).

5. Write `<dir>/reload.flag` (atomically as above) to trigger a child recycle, so the new DelphiLSP.exe is spawned immediately. Without the recycle the override would only take effect on the next time the child died for some other reason.

6. Confirm to the user: the override applied (or cleared), how many shims received it, and which DelphiLSP.exe the shim is now running. The shim writes the resolved path + source ("DELPHI_LSP_EXE", "runtime.txt:version=37.0", "hinted by ...", "highest installed (BDS X.Y)", "PATH") to its log on every spawn - read the most recent `Resolved DelphiLSP:` line from `$DELPHI_LSP_SHIM_LOG` (if set) to verify what's running.

7. After signaling, retry the LSP query that prompted this command. The recycle is asynchronous; give DelphiLSP a moment to re-index before the first retry.

If no shim is registered for the current workspace, tell the user the LSP server isn't running for this workspace yet - the override file will be picked up on the next spawn.
