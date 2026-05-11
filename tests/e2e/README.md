# End-to-end regression tests

Real Haiku-driven regression tests that prove the plugin works for users.
Each test spawns `claude.exe -p` against a copy of `tests/fixtures/MinimalDelphiProject/`
with a tightly-constrained prompt, then asserts on the resulting stream-json
and the shim's diagnostic log.

**Cost:** ~$0.15–0.20 per full run (one small Haiku call per test). Not wired
into the per-commit `tests/build-and-run.bat` for that reason; run manually
before each release.

## Quick start

```powershell
# Build the shim first so the tests run against the current code:
.\build.bat

# Run the full suite:
.\tests\e2e\run-all.ps1

# Run one test by name (substring match):
.\tests\e2e\run-all.ps1 -Filter status

# Keep the temp workspaces after each test (handy for diagnosing a failure):
.\tests\e2e\run-all.ps1 -KeepTemp

# Or run a single test directly:
.\tests\e2e\test-hot-path.ps1
```

Each test creates a fresh workspace under `%TEMP%\delphi-lsp-regression-<tag>-<stamp>\`,
copies the fixture in, patches `__PROJECT_DPR_URL__` in the `.delphilsp.json`,
spawns `claude.exe`, and (on PASS) cleans up the temp dir. On FAIL the temp dir
is preserved with `stream.jsonl`, `stderr.txt`, and `shim.log` for inspection.

## What each test guards

| Script | Scenario | What it would catch |
| :--- | :--- | :--- |
| `test-lsp-cold.ps1` | First-ever `LSP(documentSymbol)` call against a fresh workspace. | Plugin not loading; lazy-spawn path broken; DelphiLSP not initializing; model falling back to the compiler. |
| `test-status-cold.ps1` | `Skill(delphi-lsp:delphi-status)` with no shim running. | Slash-command `!`-preprocessing broken; shim's argv `--status` handler exiting non-zero or missing expected sections. |
| `test-project-resolve.ps1` | `Skill(delphi-lsp:delphi-project, args="TestLSPUse")`. | `$ARGUMENTS` substitution failing; `ResolveDelphilspJsonArg` name-matching broken; exit-code regression in `--set-project`. |
| `test-reload-cold.ps1` | `Skill(delphi-lsp:delphi-reload)` with no shim running. | Cold-state path of `--reload` regressing. |
| `test-shim-reload-cold.ps1` | `Skill(delphi-lsp:delphi-shim-reload)` with no shim running. | Cold-state path of `--shim-reload` regressing. |
| `test-runtime-set-clear.ps1` | `Skill(delphi-lsp:delphi-runtime, args="37.0")` then `args="clear"`. | `clear`-as-arg routing broken; `$ARGUMENTS` not flowing into `!` block. |
| `test-hot-path.ps1` | LSP query (spawn shim) → `/delphi-status` (verify `[MINE]`) → `/delphi-reload` (verify signal). | Per-session disambiguation hiding the shim; `claude-session.txt` write missing; cross-command state regressions. |

## Common assertions across tests

- `claude.exe` exit code is 0.
- Skill `tool_result.is_error` is false.
- Model uses **only** the tools the prompt allowed (typically just LSP + Skill).
- No Bash calls — slash-command output should render inline via `!`-preprocessing.
- Specific stdout substrings present in the rendered body (e.g. `Workspace:`, `Resolved:`, `[MINE]`).
- Shim log shows `initialize.processId=` and `didOpen tracked` for tests that exercise the LSP.

## Failure triage

On FAIL, the test prints the assertion that failed and preserves the temp dir.
Useful files:

- `<tmp>\stream.jsonl` — full claude.exe stream-json. Each line is one event.
  Look for `tool_use` entries to see what the model actually called, and
  `tool_result` entries with `is_error: true` to see what failed.
- `<tmp>\stderr.txt` — claude.exe stderr. Mostly empty unless something crashed.
- `<tmp>\shim.log` — DelphiLSP shim diagnostic log. Look for `--- delphi-lsp-shim
  starting ---`, `initialize.processId=`, `Spawning: ...DelphiLSP.exe`, and any
  error lines.

The most common failure mode after a code change is the shim handler exiting
non-zero (which aborts `!`-preprocessing with `is_error=True`). If a Skill call
shows `is_error=True` with content like `Shell command failed for pattern "...":`,
the corresponding argv-mode handler in `src/units/DelphiLsp.CliCommands.pas` is
exiting 1 or 2 — make it exit 0 and report the business-rule outcome via stdout.

## Adding a new test

1. Copy an existing `test-*.ps1` as a starting point.
2. Set a unique `-Tag` in `New-TestWorkspace`.
3. Write a prompt that forces the specific tool call sequence you want to verify.
   Include "Hard constraints:" forbidding tools you don't want the model to reach for.
4. Add assertions via `Test-Assert -Failures $failures -Condition <expr> -Message <text>`.
5. Call `Write-TestResult` and `exit ($passed ? 0 : 1)` at the end.
6. The new test is automatically picked up by `run-all.ps1`.
