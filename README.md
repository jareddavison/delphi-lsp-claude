# delphi-lsp (Claude Code plugin)

> **Note:** The source and documentation in this project were AI-generated (Claude Code) and may contain errors. Review before trusting in production.

A Claude Code code-intelligence plugin that wires Embarcadero's DelphiLSP into Claude Code, mirroring how the official VS Code extension (`embarcaderotechnologies.delphilsp`) launches the server.

## What it does

When Claude Code opens a `.pas`, `.inc`, `.dpr`, or `.dpk` file, this plugin spawns `DelphiLSP.exe` and pipes diagnostics + navigation (go-to-def, hover types, find references) back to Claude. After every edit Claude makes, DelphiLSP re-analyzes and reports errors inline — Claude can fix issues in the same turn without running the Delphi compiler.

## Requirements

- **Windows** with **RAD Studio 11+** installed (so `DelphiLSP.exe` is available). The shim resolves `DelphiLSP.exe` via PATH; RAD Studio's installer normally adds its `bin\` directory automatically. If not, set `DELPHI_LSP_EXE` to an absolute path.
- A valid Delphi license (DelphiLSP refuses to start without one).

## Install

Clone the repo and point Claude Code at it:

```bash
git clone https://github.com/jareddavison/delphi-lsp-claude
claude --plugin-dir ./delphi-lsp-claude
```

The `bin/delphi-lsp-shim.exe` ships precompiled, so no Delphi compiler is required to run the plugin — only to rebuild it (see [Building from source](#building-from-source)).

## Per-project `.delphilsp.json` (important)

DelphiLSP needs a `.delphilsp.json` settings file describing the project's search paths, conditional defines, and platform target. RAD Studio generates this automatically when you open a `.dproj` in the IDE. **Without it, the server starts but reports no diagnostics for project-internal symbols.**

To produce one for an existing `.dproj`:

1. Open the project in RAD Studio once — the IDE writes `<ProjectName>.delphilsp.json` next to the `.dproj`.
2. Make sure that file lives somewhere under the workspace root Claude Code opens.

The plugin's shim (`bin/delphi-lsp-shim.exe`) walks the workspace at startup, picks the shallowest matching `.delphilsp.json`, and fires `workspace/didChangeConfiguration` with its file URI so DelphiLSP wires the project for semantic features. Set `DELPHI_LSP_SETTINGS=<absolute path>` in the environment to override the auto-pick.

## How the shim works

Claude Code's plugin manifest validator currently rejects most `lspServers.<name>.*` fields beyond `command`, `args`, and `extensionToLanguage` — including `initializationOptions` and `settings`, which is what the official VS Code extension uses to wire DelphiLSP for semantic features. The shim works around this by sitting between Claude Code and `DelphiLSP.exe` as a small stdio LSP proxy:

1. Spawns `DelphiLSP.exe -LogModes 0 -LSPLogging <workspace>` (matches `embarcaderotechnologies.delphilsp-1.1.0/delphiMain.ts:36-37`).
2. Injects `initializationOptions: { serverType: "controller", agentCount: 2 }` into the forwarded `initialize` request — same defaults as the VS Code extension's `package.json`.
3. After the client's `initialized` notification, fires `workspace/didChangeConfiguration` with the auto-discovered `.delphilsp.json` URI.
4. Otherwise byte-proxies LSP traffic in both directions.

Tunables (env vars, all optional):

| Variable | Default | Purpose |
| :--- | :--- | :--- |
| `DELPHI_LSP_EXE` | `DelphiLSP.exe` | Path or PATH name of the server binary |
| `DELPHI_LSP_LOG_MODES` | `0` | Bit mask passed to `-LogModes` |
| `DELPHI_LSP_SERVER_TYPE` | `controller` | `controller` \| `agent` \| `linter` |
| `DELPHI_LSP_AGENT_COUNT` | `2` | 1 or 2 (controller mode only) |
| `DELPHI_LSP_SETTINGS` | *(auto-discover)* | Explicit path to `.delphilsp.json` |
| `DELPHI_LSP_SHIM_LOG` | *(disabled)* | Append shim diagnostics to this file |

## Building from source

The shim source is `src/delphi-lsp-shim.dpr`. `build.bat` sources `rsvars.bat` from a RAD Studio install and compiles with `dcc64`. The bundled `bin/delphi-lsp-shim.exe` is statically linked and has no runtime dependencies beyond `DelphiLSP.exe` itself.
