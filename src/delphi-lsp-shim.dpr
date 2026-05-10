program delphi_lsp_shim;

{$APPTYPE CONSOLE}

// Copyright (c) 2026 Jared Davison. Released under the MIT License (see LICENSE).
//
// AI-generated (Claude Code). Review before trusting in production.
//
// Stdio LSP proxy for Embarcadero DelphiLSP.
//
// Mirrors what Embarcadero's VS Code Delphi LSP extension does so DelphiLSP
// delivers semantic features under Claude Code, whose plugin manifest validator
// currently rejects initializationOptions/settings:
//   1. Spawns DelphiLSP.exe with `-LogModes <n> -LSPLogging <workspaceFolder>`.
//   2. Injects `initializationOptions: { serverType, agentCount }` into the
//      forwarded `initialize` request.
//   3. After the client's `initialized` notification, fires
//      `workspace/didChangeConfiguration` with the file URI of an
//      auto-discovered `*.delphilsp.json` under the workspace root.
//   4. Otherwise byte-proxies LSP traffic in both directions.
//
// Tunables (env vars, all optional):
//   DELPHI_LSP_EXE          - path or PATH name (default: DelphiLSP.exe)
//   DELPHI_LSP_LOG_MODES    - integer bitmask (default: 0)
//   DELPHI_LSP_SERVER_TYPE  - controller|agent|linter (default: controller)
//   DELPHI_LSP_AGENT_COUNT  - 1 or 2 (default: 2)
//   DELPHI_LSP_SETTINGS     - explicit path to .delphilsp.json (skips discovery)
//   DELPHI_LSP_SHIM_LOG     - if set, append shim diagnostics to this file

uses
  Winapi.Windows,
  Winapi.TlHelp32,
  System.SysUtils,
  System.Classes,
  System.DateUtils,
  System.IOUtils,
  System.JSON,
  System.SyncObjs,
  System.Hash,
  System.Generics.Collections,
  System.Generics.Defaults,
  DelphiLsp.XmlDecode,
  DelphiLsp.Paths,
  DelphiLsp.Walkers,
  DelphiLsp.Logging,
  DelphiLsp.LspMessage,
  DelphiLsp.ProcessTree,
  DelphiLsp.DprojParse,
  DelphiLsp.StickyState,
  DelphiLsp.PluginData,
  DelphiLsp.SessionIdResolver,
  DelphiLsp.IO,
  DelphiLsp.DelphiInstall,
  DelphiLsp.Gc,
  DelphiLsp.LspWire,
  DelphiLsp.LspPathResolver,
  DelphiLsp.Diagnostics,
  DelphiLsp.HookEntry,
  DelphiLsp.Sentinels,
  DelphiLsp.SettingsResolver,
  DelphiLsp.ActiveProject,
  DelphiLsp.LspSession,
  DelphiLsp.SentinelWatcher,
  DelphiLsp.SessionRegistry,
  DelphiLsp.Env;

var
  GSession: TLspSession;              // session-scoped state (streams, child, open docs, init cache)
  GProjectGuard: TObject;             // TMonitor sentinel for GActiveProject access
  GActiveProject: TActiveProject;     // current project (replaceable)
  GSessionDir: string;                // ${CLAUDE_PLUGIN_DATA}/sessions/<PID>/ (per-shim-process, dies with shim)
  GActiveSentinelPath: string;        // <session>/active.txt
  GClaudeSessionId: string;           // CLAUDE_CODE_SESSION_ID — stable across resume, '' if absent
  GSessionStatePath: string;          // ${CLAUDE_PLUGIN_DATA}/session-state/<claude-session-id>.json — sticky bindings, survives shim death

// Replace the active project. Frees the old TActiveProject (which stops
// its watcher) and constructs a new one with its own watcher and seeded
// content hash. Fires `didChangeConfiguration` for the new URI if init
// has already completed; otherwise the new URI is fired on `initialized`.
procedure SwitchToProject(const NewPath: string);
var
  Old, NewProj: TActiveProject;
  ShouldFire: Boolean;
  NewUri: string;
begin
  if NewPath = '' then Exit;
  if not FileExists(NewPath) then
  begin
    Diag('SwitchToProject: file does not exist: ' + NewPath);
    Exit;
  end;

  NewUri := '';
  TMonitor.Enter(GProjectGuard);
  try
    if (GActiveProject <> nil) and SameText(GActiveProject.Path, NewPath) then
    begin
      Diag('SwitchToProject: same path, no-op');
      Exit;
    end;
    Old := GActiveProject;
    NewProj := TActiveProject.Create(NewPath);
    NewProj.StartWatcher;
    GActiveProject := NewProj;
    ShouldFire := GSession.DidFireConfig;
    NewUri := NewProj.Uri;
  finally
    TMonitor.Exit(GProjectGuard);
  end;
  // Free outside the guard — we own the only ref now and freeing involves
  // joining the watcher thread, which can take a moment.
  if Old <> nil then Old.Free;
  // Persist as sticky so a restart of this same Claude session lands here
  // without prompting. Must come AFTER the in-memory swap so a partial sticky
  // write doesn't outlive a failed switch.
  WriteStickyForCwd(GSessionStatePath, GetCurrentDir, NewPath);
  if ShouldFire then
  begin
    GSession.WriteToChild(MakeDidChangeConfigJson(NewUri));
    Diag('Switched project: ' + NewUri);
  end
  else
    Diag('Project switched before init complete; will fire on initialized: ' + NewUri);
end;

// Called from the main proxy loop before forwarding each inbound message:
// if the active file's watcher marked it invalidated, hash the file now
// and re-fire `didChangeConfiguration` only if the content actually changed.
procedure CheckAndApplyInvalidation;
var
  P: TActiveProject;
  Uri: string;
  Changed: Boolean;
begin
  Changed := False;
  Uri := '';
  TMonitor.Enter(GProjectGuard);
  try
    P := GActiveProject;
    if (P = nil) or (not GSession.DidFireConfig) then Exit;
    if P.CheckAndConsumeIfChanged then
    begin
      Changed := True;
      Uri := P.Uri;
    end;
  finally
    TMonitor.Exit(GProjectGuard);
  end;
  if Changed then
  begin
    GSession.WriteToChild(MakeDidChangeConfigJson(Uri));
    Diag('Re-fired didChangeConfiguration after content change: ' + Uri);
  end;
end;

procedure ReadAndApplySentinel;
var
  Path: string;
begin
  if ReadFirstNonEmptyTrimmedLine(GActiveSentinelPath, Path) then
    SwitchToProject(Path);
end;

// /delphi-shim-reload writes a sentinel at <session>/shim-reload.flag. Unlike
// /delphi-reload (which only recycles the DelphiLSP child while keeping the
// shim alive), this exits the entire shim process. Claude Code's LSP
// integration is lazy — the next LSP query after exit spawns a fresh shim
// with whatever binary is on disk now. Useful during dev after a rebuild.
procedure ReadAndApplyShimReloadFlag;
begin
  if GSessionDir = '' then Exit;
  if not ConsumeFlagFile(IncludeTrailingPathDelimiter(GSessionDir) +
                         'shim-reload.flag') then Exit;
  Diag('Shim-reload flag detected — exiting non-zero so restartOnCrash respawns us');
  // Exit non-zero so Claude Code's LSP integration treats this as a crash and
  // honors restartOnCrash (set in plugin.json). Empirically a clean exit
  // (code 0) leaves Claude Code's LSP runner in a "server is running" stuck
  // state that never respawns — only unexpected exits trigger the auto-restart.
  // Halt skips main-thread destructors; nothing critical needs flushing
  // (diag log writes per-line, per-PID session dir GC'd by next shim's
  // GcOrphanSessions, OS reclaims pipe handles).
  Halt(1);
end;

// /delphi-reload writes a sentinel file at <session>/reload.flag. The watcher
// notices, this function is called, the flag is consumed (deleted), and the
// session recycles its DelphiLSP child.
procedure ReadAndApplyReloadFlag;
var
  SettingsPath, CurrentUri: string;
begin
  if GSessionDir = '' then Exit;
  if not ConsumeFlagFile(IncludeTrailingPathDelimiter(GSessionDir) +
                         'reload.flag') then Exit;
  Diag('Reload flag detected; recycling child');
  if GSession = nil then Exit;
  SettingsPath := '';
  CurrentUri := '';
  TMonitor.Enter(GProjectGuard);
  try
    if GActiveProject <> nil then
    begin
      SettingsPath := GActiveProject.Path;
      CurrentUri := GActiveProject.Uri;
    end;
  finally
    TMonitor.Exit(GProjectGuard);
  end;
  GSession.RecycleChild(SettingsPath, GSessionDir, CurrentUri);
end;





procedure InitSessionState;
var
  Base, PidDir, FromEnv, FromArgv, FromAncestor: string;
  FromByIdScan, FromProjectsDir: string;
  AncestorPidThatWon: DWORD;
  Ancestors: TArray<DWORD>;
  AncIdx: Integer;
  AncId: DWORD;
  Resolution: TSessionIdResolution;
begin
  DumpClaudeEnv;
  DumpArgv;
  DumpProcessIdentity;

  FromEnv := FilterUnsubstitutedPlaceholder(GetEnv('CLAUDE_CODE_SESSION_ID', ''));
  if (FromEnv = '') and (GetEnv('CLAUDE_CODE_SESSION_ID', '') <> '') then
    Diag('env CLAUDE_CODE_SESSION_ID is unsubstituted placeholder; ignoring');

  FromArgv := ParseSessionIdFromArgv;

  // Walk the shim's process ancestry looking for any hook drop file keyed
  // by an ancestor PID. The hook writes one file per ancestor; we walk
  // ours from the bottom up. They share Claude Code's main process (or
  // higher) as a common ancestor — race-free per Claude Code instance,
  // even with multiple simultaneous sessions in the same workspace.
  PidDir := ClaudePidDir(ResolvePluginDataBase);
  FromAncestor := '';
  AncestorPidThatWon := 0;
  if (FromEnv = '') and (FromArgv = '') then
  begin
    Ancestors := GetAncestorPids(GetCurrentProcessId);
    Diag(Format('Walking %d ancestor(s) for hook drop file', [Length(Ancestors)]));
    for AncIdx := 0 to High(Ancestors) do
    begin
      AncId := Ancestors[AncIdx];
      Diag(Format('  ancestor[%d]=%d', [AncIdx, AncId]));
      FromAncestor := ReadSessionIdFromHookFile(PidDir, IntToStr(AncId));
      if FromAncestor <> '' then
      begin
        AncestorPidThatWon := AncId;
        Break;
      end;
    end;
  end;

  // Fallback chain: by-id scan and projects-dir scan. Computed only if
  // earlier tiers didn't resolve, mirroring the pre-extraction behaviour
  // of bailing out as soon as a value was found.
  FromByIdScan := '';
  FromProjectsDir := '';
  if (FromEnv = '') and (FromArgv = '') and (FromAncestor = '') then
  begin
    FromByIdScan := ResolveSessionIdViaHookFiles(PidDir, GetCurrentDir);
    if FromByIdScan = '' then
      FromProjectsDir := DiscoverSessionIdFromProjectsDir(
        ResolveProjectsRoot, GetCurrentDir);
  end;

  Resolution := ResolveSessionId(
    FromEnv, FromArgv, FromAncestor, FromByIdScan, FromProjectsDir);
  GClaudeSessionId := Resolution.SessionId;

  case Resolution.Source of
    ssEnv:
      Diag('Claude session id from env: ' + GClaudeSessionId);
    ssArgv:
      Diag('Claude session id from argv: ' + GClaudeSessionId);
    ssHookAncestor:
      Diag(Format('Claude session id from hook file (ancestor pid=%d): %s',
        [AncestorPidThatWon, GClaudeSessionId]));
    ssHookByIdScan:
      Diag('Claude session id from hook by-id scan: ' + GClaudeSessionId);
    ssProjectsDirScan:
      Diag('Claude session id from projects-dir scan: ' + GClaudeSessionId);
    ssNone:
    begin
      Diag('Claude session id unresolvable (env/argv/hook/scan all failed); cross-session sticky disabled');
      Exit;
    end;
  end;
  Base := ResolvePluginDataBase;
  if Base = '' then
  begin
    Diag('No plugin-data base; cross-session sticky disabled');
    Exit;
  end;
  GSessionStatePath := BuildStickyStatePath(Base, GClaudeSessionId);
  Diag('Session state path: ' + GSessionStatePath);
end;

{ Hook mode entry points are in DelphiLsp.HookEntry. }

procedure RunProxy;
var
  Json, Method, UriToFire: string;
  P: TActiveProject;
begin
  while True do
  begin
    if not GSession.ClientStream.ReadMessage(Json) then Break;

    // Lazy hash check: if the active-file watcher marked the project
    // invalidated, hash now and re-fire didChangeConfiguration only if
    // the content actually changed.
    CheckAndApplyInvalidation;

    Method := GetMessageMethod(Json);
    if Method = 'initialize' then
    begin
      // Diagnostic: log the spawning process PID Claude Code reports via
      // initialize.processId. Compared against shim's PPID (logged at
      // startup) to determine if hook-PPID == shim-processId, which lets
      // us correlate hook output with shim session race-free.
      Diag(Format('initialize.processId=%d (shim ppid=%d)',
        [ExtractInitializeProcessId(Json), GetParentProcessId]));
      Json := InjectInitOptions(Json,
        GetEnv('DELPHI_LSP_SERVER_TYPE', 'controller'),
        StrToIntDef(GetEnv('DELPHI_LSP_AGENT_COUNT', '2'), 2));
    end;
    // SendToChild atomically tracks (caches init/initialized, applies
    // didOpen/Change/Close to FOpenDocs) and forwards to the child.
    GSession.SendToChild(Json, Method);
    if Method = 'initialized' then
    begin
      // Mark init complete unconditionally — even if no project is selected
      // yet (multi-candidate / no sticky). Otherwise a later SwitchToProject
      // would think init hasn't happened and stage the didChangeConfiguration
      // for "next initialized", which never fires again.
      UriToFire := '';
      TMonitor.Enter(GProjectGuard);
      try
        if not GSession.DidFireConfig then
        begin
          GSession.DidFireConfig := True;
          P := GActiveProject;
          if P <> nil then UriToFire := P.Uri;
        end;
      finally
        TMonitor.Exit(GProjectGuard);
      end;
      if UriToFire <> '' then
      begin
        GSession.WriteToChild(MakeDidChangeConfigJson(UriToFire));
        Diag('Sent didChangeConfiguration: ' + UriToFire);
      end;
    end;
  end;
  Diag('Client closed stdin');
end;

// Establish the initial active project. Resolution order:
//   1. DELPHI_LSP_SETTINGS env var (explicit override)
//   2. Sticky pick for (claude-session-id, cwd) if present and still on disk
//   3. Single-candidate auto-pick (only when there's exactly one .delphilsp.json
//      in the workspace — trivial-case convenience)
//   4. None — shim starts without a project. DelphiLSP runs syntactic-only
//      until /delphi-project picks one. Multi-candidate workspaces always
//      land here, since auto-picking from filesystem shape misfires too often
//      in the real-world case (100-project repo with shared .pas units).
// Runs before any worker threads start, so no guard needed.
procedure InitSettings;
var
  Explicit, Sticky: string;
  Acc: TList<string>;
  Candidates: TArray<string>;
  Decision: TInitSettingsResult;
  I: Integer;
begin
  Explicit := GetEnv('DELPHI_LSP_SETTINGS', '');
  if (Explicit <> '') and not FileExists(Explicit) then Explicit := '';
  Sticky := ReadStickyForCwd(GSessionStatePath, GetCurrentDir);

  Acc := TList<string>.Create;
  try
    CollectFilesByExt(GetCurrentDir, '.delphilsp.json', 0, Acc);
    SetLength(Candidates, Acc.Count);
    for I := 0 to Acc.Count - 1 do Candidates[I] := Acc[I];
  finally
    Acc.Free;
  end;

  Decision := ResolveInitialSettings(Explicit, Sticky, Candidates);
  case Decision.Action of
    isaUseExplicit:
    begin
      GActiveProject := TActiveProject.Create(Decision.ResolvedPath);
      GActiveProject.StartWatcher;
      Diag('Initial settings URI (env DELPHI_LSP_SETTINGS): ' +
           GActiveProject.Uri);
    end;
    isaUseSticky:
    begin
      GActiveProject := TActiveProject.Create(Decision.ResolvedPath);
      GActiveProject.StartWatcher;
      Diag('Restored sticky pick from previous session: ' +
           GActiveProject.Uri + ' — /delphi-project to change');
    end;
    isaUseSingleCandidate:
    begin
      GActiveProject := TActiveProject.Create(Decision.ResolvedPath);
      GActiveProject.StartWatcher;
      Diag('Initial settings URI (single candidate): ' + GActiveProject.Uri);
      WriteStickyForCwd(GSessionStatePath, GetCurrentDir,
                        Decision.ResolvedPath);
    end;
    isaNone:
      Diag('No .delphilsp.json found in workspace');
    isaMultiCandidate:
    begin
      Diag(Format('Multiple .delphilsp.json candidates (%d); shim starts without project — user must run /delphi-project',
        [Length(Decision.Candidates)]));
      for I := 0 to High(Decision.Candidates) do
        Diag('  candidate: ' + Decision.Candidates[I]);
    end;
  end;
end;

var
  SentinelWatcher: TSentinelWatcherThread;
  InitialSettingsPath: string;
  Reg: TSessionRegistration;
begin
  SetLogPath(GetEnv('DELPHI_LSP_SHIM_LOG', ''));

  // Dual-mode binary: when invoked with --hook-session-start, behave as the
  // SessionStart hook (read JSON from stdin, persist correlation files,
  // optionally emit multi-candidate prompt) and exit. Otherwise run as the
  // LSP shim. Same exe so PPID-resolution and plugin-data discovery share
  // implementation; on Windows MinGW bash a separate hook script gets PPID=1
  // due to process tree reparenting, breaking PPID-keyed correlation.
  if (ParamCount >= 1) and SameText(ParamStr(1), '--hook-session-start') then
  begin
    Diag('--- delphi-lsp-shim hook-session-start mode ---');
    Diag('CWD: ' + GetCurrentDir);
    try
      RunSessionStartHook;
    except
      on E: Exception do
        Diag('Hook fatal: ' + E.ClassName + ': ' + E.Message);
    end;
    Halt(0);
  end;

  if (ParamCount >= 1) and SameText(ParamStr(1), '--hook-session-end') then
  begin
    Diag('--- delphi-lsp-shim hook-session-end mode ---');
    try
      RunSessionEndHook;
    except
      on E: Exception do
        Diag('SessionEnd hook fatal: ' + E.ClassName + ': ' + E.Message);
    end;
    Halt(0);
  end;

  if (ParamCount >= 1) and SameText(ParamStr(1), '--find-project-for') then
  begin
    Diag('--- delphi-lsp-shim find-project-for mode ---');
    try
      RunFindProjectForMode;  // halts internally
    except
      on E: Exception do
      begin
        Diag('FindProjectFor fatal: ' + E.ClassName + ': ' + E.Message);
        Halt(1);
      end;
    end;
    Halt(1); // unreachable
  end;

  Diag('--- delphi-lsp-shim starting ---');
  Diag('CWD: ' + GetCurrentDir);

  GProjectGuard := TObject.Create;
  GSession := TLspSession.Create(GetStdHandle(STD_INPUT_HANDLE),
                                 GetStdHandle(STD_OUTPUT_HANDLE));
  SentinelWatcher := nil;

  try
    InitSessionState;
    // GC stale per-session bindings + claude-pid drop files. Sanity check
    // first: if we can't even find our OWN session's .jsonl, the projects-dir
    // probe is fundamentally broken (CLAUDE_HOME override, encoding change,
    // sync lag, mounted drive missing, etc.) — bail out rather than wipe
    // every other session's sticky en masse on a false-negative liveness
    // signal. Same risk applies to claude-pid by-id files (also use
    // IsClaudeSessionAlive), so guard both together.
    if (GClaudeSessionId <> '') and IsClaudeSessionAlive(ResolveProjectsRoot, GClaudeSessionId) then
    begin
      GcStaleSessionState(
        SessionStateDir(ResolvePluginDataBase),
        ResolveProjectsRoot,
        GClaudeSessionId);
      GcStaleClaudePidFiles(
        ClaudePidDir(ResolvePluginDataBase),
        ResolveProjectsRoot);
    end
    else
      Diag('GC: skipping (own session .jsonl not found or session id unresolved)');
    InitSettings;

    Reg := RegisterSession;
    GSessionDir := Reg.SessionDir;
    GActiveSentinelPath := Reg.ActiveSentinelPath;
    // If a sentinel was already deposited before our spawn (e.g., the user
    // ran /delphi-project before this shim started up), pick it up now so
    // our initial `didChangeConfiguration` fires with the right URI.
    ReadAndApplySentinel;
    InitialSettingsPath := '';
    TMonitor.Enter(GProjectGuard);
    try
      if GActiveProject <> nil then
      begin
        InitialSettingsPath := GActiveProject.Path;
        Diag('Effective settings URI: ' + GActiveProject.Uri);
      end
      else
        Diag('Effective settings URI: (none)');
    finally
      TMonitor.Exit(GProjectGuard);
    end;

    if not GSession.StartChildConnection(InitialSettingsPath, GSessionDir) then
    begin
      Writeln(ErrOutput, 'delphi-lsp-shim: failed to spawn DelphiLSP');
      Halt(1);
    end;

    if GSessionDir <> '' then
    begin
      SentinelWatcher := TSentinelWatcherThread.Create(GSessionDir,
        procedure
        begin
          ReadAndApplySentinel;
          ReadAndApplyReloadFlag;
          ReadAndApplyShimReloadFlag;
        end);
      SentinelWatcher.FreeOnTerminate := False;
    end;

    try
      RunProxy;
    finally
      if SentinelWatcher <> nil then
      begin
        SentinelWatcher.SignalShutdown;
        SentinelWatcher.WaitFor;
        SentinelWatcher.Free;
      end;

      // Free the active project (which stops its watcher) before tearing
      // down the guard sentinel.
      TMonitor.Enter(GProjectGuard);
      try
        if GActiveProject <> nil then
        begin
          GActiveProject.Free;
          GActiveProject := nil;
        end;
      finally
        TMonitor.Exit(GProjectGuard);
      end;

      UnregisterSession(GSessionDir);
    end;
  except
    on E: Exception do
    begin
      Diag('Fatal: ' + E.ClassName + ': ' + E.Message);
      Writeln(ErrOutput, 'delphi-lsp-shim fatal: ' + E.Message);
      Halt(1);
    end;
  end;

  GSession.Free;
  GProjectGuard.Free;
end.
