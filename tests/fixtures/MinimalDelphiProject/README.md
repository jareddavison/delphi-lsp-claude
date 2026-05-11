# MinimalDelphiProject fixture

A bare-bones console Delphi project used by `tests/e2e/test-haiku-lsp.ps1` to verify the
LSP shim end-to-end with a real `claude.exe -p` invocation.

Do not run or edit in place. The regression test copies this directory to a fresh
temp dir on each run, patches `__PROJECT_DPR_URL__` in `TestLSPUse.delphilsp.json`
to the temp dir's `.dpr` URL, then spawns Claude Code against the temp dir.

## Contents

| File | Purpose |
| :--- | :--- |
| `TestLSPUse.dpr` | Minimal console program (`begin ... end.` with an exception handler). |
| `TestLSPUse.dproj` | RAD Studio project file. |
| `TestLSPUse.res` | Compiled resource (icon, version info) emitted by the IDE. |
| `TestLSPUse.delphilsp.json` | DelphiLSP settings file with `__PROJECT_DPR_URL__` placeholder. |

## Regenerating after a RAD Studio change

If you need to refresh the `.delphilsp.json` (e.g. new BDS version, different
default include paths), open `TestLSPUse.dproj` in the IDE, save it, copy the
freshly-written `TestLSPUse.delphilsp.json` here, then replace the `project`
URL with the literal string `__PROJECT_DPR_URL__`.
