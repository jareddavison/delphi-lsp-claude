# delphi-lsp (Claude Code plugin)

> **Note:** The source and documentation in this project were AI-generated (Claude Code). Review before trusting in production.

A Claude Code code-intelligence plugin that wires Embarcadero's DelphiLSP into Claude Code, mirroring how the official VS Code extension (`embarcaderotechnologies.delphilsp`) launches the server. Adds:

- **Hover, go-to-definition, find references, document/workspace symbols** via DelphiLSP.
- **Push diagnostics** — DelphiLSP analyzes after every edit, errors arrive in the same turn.
- **Per-(session, cwd) sticky project pick** that survives `claude --resume`.
- **Multi-candidate prompt flow** — when a workspace has several `.delphilsp.json` files (typical for multi-project repos), Claude prompts you to pick one via `AskUserQuestion`, then `/delphi-project` loads it. Single-candidate workspaces auto-pick silently.
- **Race-free correlation** between concurrent Claude Code sessions in the same workspace, even when they're working on different projects.

## Requirements

- **Windows** with **RAD Studio 11+** installed. The shim auto-detects the highest installed version via the registry, prefers the 64-bit DelphiLSP (`<install>\bin64\DelphiLSP.exe`) when present, and falls back to the 32-bit one (`<install>\bin\DelphiLSP.exe`). The 64-bit binary ships with higher-tier SKUs; lower tiers get the 32-bit one only — both work. Override via `DELPHI_LSP_EXE` (absolute path) or `/delphi-runtime` (slash command).
- A valid Delphi license (DelphiLSP refuses to start without one).

## Install

Two paths depending on use case.

**For regular use on a machine** (recommended) — install via the bundled marketplace so Claude Code auto-updates the plugin on each new commit:

```text
/plugin marketplace add https://github.com/jareddavison/delphi-lsp-claude
/plugin install delphi-lsp@jareddavison
```

**For local development** — clone and load via `--plugin-dir`:

```bash
git clone https://github.com/jareddavison/delphi-lsp-claude
claude --plugin-dir ./delphi-lsp-claude
```

Either way, `bin/delphi-lsp-shim.exe` ships precompiled — no Delphi compiler needed to run, only to rebuild (see [Building](#building)).

## Per-project `.delphilsp.json`

DelphiLSP needs a `.delphilsp.json` settings file per project (search paths, conditional defines, platform/config target). Without it, the server runs syntactic-only — no semantic queries, no diagnostics.

**The IDE feature must be turned on first.** Per Embarcadero's docs ([Code Insight Reference: Creating .delphilsp.json Files](https://docwiki.embarcadero.com/RADStudio/Florence/en/Code_Insight_Reference#Creating_.delphilsp.json_Files)), enable `Tools → Options → User Interface → Editor → Language → Language Server Protocol → Save .delphilsp.json file when project is saved`. Then save the `.dproj` and the IDE writes `<ProjectName>.delphilsp.json` next to it.

The file lives in the workspace, gets committed (or not, your call), and is picked up by this plugin automatically.

When you switch the IDE's active config or platform (Debug/Release, Win32/Win64, etc.), RAD Studio rewrites `.delphilsp.json`. The shim watches for that and re-fires `didChangeConfiguration` automatically — so semantic queries reflect the IDE's current target.

## How project selection works

When Claude Code starts in a workspace:

1. **Single `.delphilsp.json` candidate** → auto-picked silently.
2. **Multiple candidates** → on first session in this workspace, Claude is told (via the SessionStart hook) to call `AskUserQuestion` with the candidate list, then `/delphi-project <name>` to load. Your pick is persisted as **sticky bindings**.
3. **Resumed session** (`claude --resume <id>`) → sticky bindings restore your previous pick silently.
4. **Override anytime** — `/delphi-project <name>` reloads on demand and rewrites the sticky.

Sticky bindings are scoped per-(Claude session id, cwd). Two simultaneous sessions on the same repo can have different projects loaded without interfering.

## Slash commands

| Command | Purpose |
| :--- | :--- |
| `/delphi-project <name\|path>` | Switch the active `.delphilsp.json`. Argument is a basename match (e.g. `MyApp`), a relative path, or an absolute `.delphilsp.json` path. |
| `/delphi-status` | Read-only — show registered shim PIDs, active project, and other available `.delphilsp.json` files in the workspace. |
| `/delphi-reload` | Recycle DelphiLSP's child process (replays cached `initialize` + open documents). Useful if DelphiLSP gets into a bad state. |
| `/delphi-runtime <ver\|path\|clear>` | Override which `DelphiLSP.exe` to spawn — e.g. `/delphi-runtime 37.0` for BDS 23.0 (Delphi 12 Athens), or an absolute `.exe` path. |

## How the shim works

Claude Code's plugin manifest validator accepts `command`, `args`, `env`, `extensionToLanguage`, `initializationOptions`, `settings`, `transport`, `workspaceFolder`, `startupTimeout` (etc.) for `lspServers.<name>.*`. However, manifest `${...}` substitution is whitelist-limited — only `${CLAUDE_PLUGIN_ROOT}`, `${CLAUDE_PLUGIN_DATA}`, `${user_config.*}` expand; arbitrary env vars (including `${CLAUDE_CODE_SESSION_ID}`) pass through literally. Combined with the fact that LSP subprocess env doesn't include `CLAUDE_CODE_SESSION_ID`, this plugin can't tell DelphiLSP about the project via static manifest. Hence the shim:

1. **Spawns** `DelphiLSP.exe -LogModes 0 -LSPLogging <workspace>` (matches `embarcaderotechnologies.delphilsp-1.1.0/delphiMain.ts:36-37`).
2. **Injects** `initializationOptions: { serverType: "controller", agentCount: 2 }` into the forwarded `initialize` request — same defaults as the VS Code extension.
3. **Fires** `workspace/didChangeConfiguration` with the chosen `.delphilsp.json` URI on `initialized`, or whenever `/delphi-project` switches.
4. **Watches** the active `.delphilsp.json` for content changes (IDE re-writes on target switch) and re-fires `didChangeConfiguration` if the hash changes.
5. **Byte-proxies** all other LSP traffic in both directions.

Plus dual-mode operation: when invoked with `--hook-session-start` or `--hook-session-end`, the same exe runs the corresponding SessionStart/SessionEnd hook (registered in `hooks/hooks.json`) and exits. One binary, all the heavy lifting (Win32 process tree walk, JSON parse, sticky bindings r/w) lives in shared Delphi code.

## Persistent state

Under `${CLAUDE_PLUGIN_DATA}` (resolves to `<claude-data-dir>/plugins/data/<plugin-id>/`):

| Path | Lifetime | Purpose |
| :--- | :--- | :--- |
| `session-state/<claude-session-id>.json` | Persistent | Sticky project pick keyed by sha256 of canonical cwd. Survives shim death and Claude Code restart. GC'd only when the corresponding `.jsonl` in `<claude-data-dir>/projects/` is gone (session unresumable). |
| `claude-pid/<ancestor-pid>.json` | Per-session | Hook-deposited correlation drop, one per ancestor PID. Lets the shim resolve its session id race-free by walking its own ancestry. GC'd at startup if the PID is dead, or eagerly on SessionEnd. |
| `claude-pid/by-id-<session>.json` | Per-session | Same hook drop, keyed by session id (cwd-canonical-match fallback). |
| `sessions/<shim-pid>/active.txt` | Per-shim | In-session pick written by `/delphi-project`. |
| `sessions/<shim-pid>/runtime.txt` | Per-shim | DelphiLSP path override written by `/delphi-runtime`. |
| `sessions/<shim-pid>/reload.flag` | Per-shim | Sentinel deposited by `/delphi-reload`, consumed by the shim. |

Cleanup:

- **Startup GC** — sweeps stale `session-state/*.json` and `claude-pid/*.json` entries. Skipped entirely if the shim's own session can't be located in the projects dir (defends against data-dir overrides, sync lag, encoding-format changes).
- **SessionEnd hook** — eagerly deletes per-session correlation drops on session close.
- **Orphan session GC** — sweeps `sessions/<dead-pid>/` directories on every shim startup.

## Tunables (env vars, all optional)

| Variable | Default | Purpose |
| :--- | :--- | :--- |
| `DELPHI_LSP_EXE` | *(auto-detect)* | Path or PATH name of `DelphiLSP.exe`. Highest BDS version is auto-resolved via registry; this overrides. |
| `DELPHI_LSP_BITS` | *(prefer 64)* | Force a specific DelphiLSP variant when both `<install>\bin64\` and `<install>\bin\` exist. `32` selects 32-bit, `64` selects 64-bit (fails loudly if missing rather than falling back), unset selects 64-then-32. Doesn't apply when `DELPHI_LSP_EXE` is set explicitly. |
| `DELPHI_LSP_LOG_MODES` | `0` | Bitmask passed to `-LogModes`. |
| `DELPHI_LSP_SERVER_TYPE` | `controller` | `controller` \| `agent` \| `linter` (controller spawns sub-process agents; non-controller modes don't push diagnostics). |
| `DELPHI_LSP_AGENT_COUNT` | `2` | 1 or 2 (controller mode only; ≥2 enables Error Insight push diagnostics). |
| `DELPHI_LSP_SETTINGS` | *(sticky → single-candidate → none)* | Explicit `.delphilsp.json` path; bypasses sticky/auto-pick chain. |
| `DELPHI_LSP_SHIM_LOG` | *(disabled)* | Append shim diagnostics to this file. |

## Branches & releases

`main` is the **published** branch — Claude Code's marketplace auto-pulls from it on every restart, so anything pushed here goes live to all users immediately. Don't merge to `main` unless you've tested the change end-to-end.

Work on `dev` (or topic branches off `dev`) for in-progress changes. When ready to release:

1. Merge `dev` → `main` (fast-forward or squash, your call).
2. Bump `version` in `.claude-plugin/plugin.json` (semver — patch for fixes, minor for features, major for breaking).
3. Tag the `main` HEAD as `vX.Y.Z` and push the tag (`git tag v0.6.0 && git push origin v0.6.0`).
4. Push `main`.

Users on the marketplace get the new version on next Claude Code restart. If something turns out to be broken, revert `main` to the previous tag and push.

## Building

```bash
build.bat
```

Picks the highest installed RAD Studio (`C:\Program Files (x86)\Embarcadero\Studio\<X.Y>\` with `bin\dcc64.exe` + `bin\rsvars.bat`); override via `BDS_VERSION=37.0`. Output: `bin\delphi-lsp-shim.exe` — statically linked, no runtime dependencies beyond `DelphiLSP.exe` itself. Compile time ~0.1s.

If the shim is currently running, rename `bin\delphi-lsp-shim.exe` to `bin\delphi-lsp-shim.exe.inuse` first; the `.exe.inuse*` pattern is gitignored. (Or just run `/delphi-shim-reload` from inside Claude Code — exits the shim and Claude Code auto-respawns it lazily on the next LSP query, picking up whatever binary is on disk now.)

## License & trademarks

Source code in this repository is released under the MIT License (see `LICENSE`).

Trademark notice — this project is not affiliated with, endorsed by, or sponsored by either organization:

- **Claude**, **Claude Code**, and the Anthropic logo are trademarks of Anthropic, PBC.
- **Delphi**, **DelphiLSP**, **RAD Studio**, and **Embarcadero** are trademarks of Embarcadero Technologies, Inc. (an Idera, Inc. company).

The names appear in this README, package metadata, and source code purely as descriptive references to the products this plugin interoperates with (nominative fair use). The repository name `delphi-lsp-claude` is a compound of *Delphi LSP* (the language-server protocol implementation this plugin proxies) and *Claude* (the AI assistant this plugin integrates with) — both used descriptively. The published plugin name in `plugin.json` is just `delphi-lsp`. Nothing here represents an official Anthropic or Embarcadero project.

Users are responsible for holding their own valid Delphi license to run `DelphiLSP.exe`.
