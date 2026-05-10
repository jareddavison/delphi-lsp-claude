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
  DelphiLsp.Sentinels;

type
  TChildReaderThread = class(TThread)
  private
    FFromChild: TLspStream;
    FToClient: TLspStream;
    FSwallowIds: TList<string>;          // response IDs to drop (replay artifacts)
    function ShouldDrop(const Json: string): Boolean;
  protected
    procedure Execute; override;
  public
    constructor Create(AFromChild, AToClient: TLspStream);
    destructor Destroy; override;
    procedure SwallowResponseId(const Id: string);
  end;

  // Watches the per-session sentinel directory for `active.txt`/`reload.flag`
  // changes (slash commands deposit them) and refires `didChangeConfiguration`
  // / triggers recycle as appropriate.
  TSentinelWatcherThread = class(TThread)
  private
    FDir: string;
    FShutdownEvent: TEvent;
  protected
    procedure Execute; override;
  public
    constructor Create(const ADir: string);
    destructor Destroy; override;
    procedure SignalShutdown;
  end;

  // Forward declaration — TActiveProject and TActiveFileWatcherThread
  // reference each other (project owns watcher; watcher holds back-ptr to
  // project so it can call Invalidate on the right object).
  TActiveProject = class;

  // Watches the directory containing the active `.delphilsp.json` (non-recursive)
  // and on any `LAST_WRITE`/`FILE_NAME`/`SIZE` notification calls
  // `Project.Invalidate`. The actual file read+hash comparison happens lazily
  // in the main proxy loop — see TActiveProject.CheckAndConsumeIfChanged.
  TActiveFileWatcherThread = class(TThread)
  private
    FProject: TActiveProject;  // back-pointer; not owned
    FDir: string;
    FShutdownEvent: TEvent;
  protected
    procedure Execute; override;
  public
    constructor Create(AProject: TActiveProject; const ADir: string);
    destructor Destroy; override;
    procedure SignalShutdown;
  end;

  // Encapsulates the LSP-session-scoped state that survives both
  // /delphi-project switches AND /delphi-reload recycles:
  //   - parent stdin/stdout streams (whole shim lifetime)
  //   - child stdin/stdout streams + process handle (replaced on recycle)
  //   - child-stdin write lock
  //   - DidFireConfig flag
  //   - cached `initialize` / `initialized` JSON for replay
  //   - dictionary of open documents (mirrors what the LSP client believes
  //     is open, used to replay didOpen to a fresh child)
  // RunProxy stays a free function but reads/writes through this object.
  TLspSession = class
  private
    FClientToShim: TLspStream;
    FShimToClient: TLspStream;
    FShimToChild: TLspStream;
    FChildToShim: TLspStream;
    FChildIn: THandle;
    FChildOut: THandle;
    FChildHandle: THandle;
    FChildInLock: TCriticalSection;     // serializes track + write + recycle
    FDidFireConfig: Boolean;
    FOpenDocs: TDictionary<string, TOpenDocument>;
    FCachedInitJson: string;
    FCachedInitializedJson: string;
    FReader: TChildReaderThread;
    FRecycleCounter: Integer;            // distinguishes synthetic init IDs across recycles
    procedure WriteRawLocked(const Json: string);
    procedure TrackOutgoingMessageLocked(const Json: string; const Method: string);
  public
    constructor Create(AClientIn, AClientOut: THandle);
    destructor Destroy; override;
    function StartChildConnection: Boolean;
    procedure StopChildConnection;
    procedure WriteToChild(const Json: string);
    procedure SendToChild(const Json: string; const Method: string);
    procedure RecycleChild;
    function ChildAlive: Boolean;
    property ClientStream: TLspStream read FClientToShim;
    property DidFireConfig: Boolean read FDidFireConfig write FDidFireConfig;
  end;

  // Encapsulates everything tied to one specific `.delphilsp.json`. Replacing
  // the active project (`/delphi-project` switch) is just constructing a new
  // TActiveProject and freeing the old one — its watcher dies with it.
  TActiveProject = class
  private
    FPath: string;
    FUri: string;
    FLastHash: string;
    FInvalidated: Boolean;
    FWatcher: TActiveFileWatcherThread;
    function ComputeHash: string;
  public
    constructor Create(const APath: string);
    destructor Destroy; override;
    procedure StartWatcher;
    procedure Invalidate;                       // called from watcher thread
    function CheckAndConsumeIfChanged: Boolean; // true => content actually changed since last seen
    property Path: string read FPath;
    property Uri: string read FUri;
  end;

var
  GSession: TLspSession;              // session-scoped state (streams, child, open docs, init cache)
  GProjectGuard: TObject;             // TMonitor sentinel for GActiveProject access
  GActiveProject: TActiveProject;     // current project (replaceable)
  GSessionDir: string;                // ${CLAUDE_PLUGIN_DATA}/sessions/<PID>/ (per-shim-process, dies with shim)
  GActiveSentinelPath: string;        // <session>/active.txt
  GClaudeSessionId: string;           // CLAUDE_CODE_SESSION_ID — stable across resume, '' if absent
  GSessionStatePath: string;          // ${CLAUDE_PLUGIN_DATA}/session-state/<claude-session-id>.json — sticky bindings, survives shim death

function GetEnv(const Name, Default: string): string;
begin
  Result := GetEnvironmentVariable(Name);
  if Result = '' then Result := Default;
end;

{ Settings file helpers }

function FindSettingsFile(const Root: string): string;
var
  Acc: TList<string>;
begin
  Result := '';
  Acc := TList<string>.Create;
  try
    CollectFilesByExt(Root, '.delphilsp.json', 0, Acc);
    if Acc.Count = 0 then Exit;
    Acc.Sort(TComparer<string>.Construct(
      function(const A, B: string): Integer
      var
        DA, DB: Integer;
      begin
        DA := Length(A.Split([PathDelim]));
        DB := Length(B.Split([PathDelim]));
        if DA <> DB then Exit(DA - DB);
        Result := CompareStr(A, B);
      end));
    Result := Acc[0];
  finally
    Acc.Free;
  end;
end;


{ TLspSession }

constructor TLspSession.Create(AClientIn, AClientOut: THandle);
begin
  inherited Create;
  FChildInLock := TCriticalSection.Create;
  FOpenDocs := TDictionary<string, TOpenDocument>.Create;
  FClientToShim := TLspStream.Create(AClientIn);
  FShimToClient := TLspStream.Create(AClientOut);
end;

destructor TLspSession.Destroy;
begin
  StopChildConnection;
  FClientToShim.Free;
  FShimToClient.Free;
  FOpenDocs.Free;
  FChildInLock.Free;
  inherited;
end;

function TLspSession.StartChildConnection: Boolean;
var
  SecAttr: TSecurityAttributes;
  ChildInRead, ChildOutWrite: THandle;
  StartupInfo: TStartupInfo;
  ProcInfo: TProcessInformation;
  CmdLine: string;
  ExePath, LogModes, Cwd, ExeSource, SettingsPath: string;
begin
  Result := False;
  SecAttr.nLength := SizeOf(SecAttr);
  SecAttr.bInheritHandle := True;
  SecAttr.lpSecurityDescriptor := nil;

  if not CreatePipe(ChildInRead, FChildIn, @SecAttr, 0) then
  begin
    Diag(Format('CreatePipe (stdin) failed: %d', [GetLastError]));
    Exit;
  end;
  SetHandleInformation(FChildIn, HANDLE_FLAG_INHERIT, 0);

  if not CreatePipe(FChildOut, ChildOutWrite, @SecAttr, 0) then
  begin
    Diag(Format('CreatePipe (stdout) failed: %d', [GetLastError]));
    CloseHandle(ChildInRead); CloseHandle(FChildIn);
    Exit;
  end;
  SetHandleInformation(FChildOut, HANDLE_FLAG_INHERIT, 0);

  ZeroMemory(@StartupInfo, SizeOf(StartupInfo));
  StartupInfo.cb := SizeOf(StartupInfo);
  StartupInfo.dwFlags := STARTF_USESTDHANDLES;
  StartupInfo.hStdInput := ChildInRead;
  StartupInfo.hStdOutput := ChildOutWrite;
  StartupInfo.hStdError := GetStdHandle(STD_ERROR_HANDLE);

  SettingsPath := '';
  TMonitor.Enter(GProjectGuard);
  try
    if GActiveProject <> nil then SettingsPath := GActiveProject.Path;
  finally
    TMonitor.Exit(GProjectGuard);
  end;

  ExePath := ResolveDelphiLspPath(SettingsPath, GSessionDir, ExeSource);
  LogModes := GetEnv('DELPHI_LSP_LOG_MODES', '0');
  Cwd := GetCurrentDir;
  CmdLine := Format('"%s" -LogModes %s -LSPLogging "%s"', [ExePath, LogModes, Cwd]);

  Diag(Format('Resolved DelphiLSP: %s (source=%s)', [ExePath, ExeSource]));
  Diag('Spawning: ' + CmdLine);
  Diag('Cwd: ' + Cwd);

  UniqueString(CmdLine);
  if not CreateProcess(nil, PChar(CmdLine), nil, nil, True, 0, nil, nil,
                       StartupInfo, ProcInfo) then
  begin
    Diag(Format('CreateProcess failed: %d', [GetLastError]));
    CloseHandle(ChildInRead); CloseHandle(FChildIn);
    CloseHandle(ChildOutWrite); CloseHandle(FChildOut);
    Exit;
  end;

  FChildHandle := ProcInfo.hProcess;
  CloseHandle(ProcInfo.hThread);
  CloseHandle(ChildInRead);
  CloseHandle(ChildOutWrite);
  FShimToChild := TLspStream.Create(FChildIn);
  FChildToShim := TLspStream.Create(FChildOut);
  // Reader thread is owned by the session — replaced on every recycle.
  FReader := TChildReaderThread.Create(FChildToShim, FShimToClient);
  FReader.FreeOnTerminate := False;
  Result := True;
end;

procedure TLspSession.StopChildConnection;
begin
  // Close child stdin first so the child sees EOF and (often) exits cleanly,
  // freeing it to release its end of the stdout pipe.
  if FChildIn <> 0 then
  begin
    CloseHandle(FChildIn);
    FChildIn := 0;
  end;
  if FChildHandle <> 0 then
  begin
    if WaitForSingleObject(FChildHandle, 2000) = WAIT_TIMEOUT then
      TerminateProcess(FChildHandle, 0);
    CloseHandle(FChildHandle);
    FChildHandle := 0;
  end;
  // Reader's blocking ReadFile on FChildOut now returns ERROR_BROKEN_PIPE,
  // ReadMessage returns False, Execute exits — we just have to wait.
  if FReader <> nil then
  begin
    FReader.Terminate; // belt-and-suspenders if reader is somewhere else
    FReader.WaitFor;
    FReader.Free;
    FReader := nil;
  end;
  if FChildOut <> 0 then
  begin
    CloseHandle(FChildOut);
    FChildOut := 0;
  end;
  if FShimToChild <> nil then
  begin
    FShimToChild.Free;
    FShimToChild := nil;
  end;
  if FChildToShim <> nil then
  begin
    FChildToShim.Free;
    FChildToShim := nil;
  end;
end;

procedure TLspSession.WriteRawLocked(const Json: string);
begin
  if FShimToChild <> nil then
    FShimToChild.WriteMessage(Json);
end;

procedure TLspSession.WriteToChild(const Json: string);
begin
  FChildInLock.Acquire;
  try
    WriteRawLocked(Json);
  finally
    FChildInLock.Release;
  end;
end;

procedure TLspSession.SendToChild(const Json: string; const Method: string);
begin
  FChildInLock.Acquire;
  try
    try
      TrackOutgoingMessageLocked(Json, Method);
    except
      on E: Exception do Diag('TrackOutgoingMessage error: ' + E.Message);
    end;
    WriteRawLocked(Json);
  finally
    FChildInLock.Release;
  end;
end;

function TLspSession.ChildAlive: Boolean;
begin
  Result := FShimToChild <> nil;
end;

// Parse outgoing client-to-child message and update session-state mirrors.
// Caches initialize/initialized verbatim. Tracks didOpen/didChange/didClose
// in FOpenDocs so a later /delphi-reload can replay the synthetic didOpens
// to a fresh DelphiLSP child. Caller must hold FChildInLock — this method
// makes no further locking.
procedure TLspSession.TrackOutgoingMessageLocked(const Json: string; const Method: string);
var
  Root: TJSONValue;
  Obj, Params, TextDoc, ChangeObj: TJSONObject;
  Uri: string;
  Doc: TOpenDocument;
  Changes: TJSONArray;
  I: Integer;
  Found: Boolean;
begin
  if (Method = 'initialize') and (FCachedInitJson = '') then
  begin
    FCachedInitJson := Json;
    Diag('Cached initialize message');
    Exit;
  end;
  if (Method = 'initialized') and (FCachedInitializedJson = '') then
  begin
    FCachedInitializedJson := Json;
    Diag('Cached initialized notification');
    Exit;
  end;
  if (Method <> 'textDocument/didOpen') and
     (Method <> 'textDocument/didChange') and
     (Method <> 'textDocument/didClose') then
    Exit;

  Root := nil;
  try
    try
      Root := TJSONObject.ParseJSONValue(Json);
    except
      Exit;
    end;
    if not (Root is TJSONObject) then Exit;
    Obj := TJSONObject(Root);
    Params := TJSONObject(Obj.GetValue('params'));
    if not (Params is TJSONObject) then Exit;
    TextDoc := TJSONObject(Params.GetValue('textDocument'));
    if not (TextDoc is TJSONObject) then Exit;
    if (TextDoc.GetValue('uri') = nil) then Exit;
    Uri := TextDoc.GetValue('uri').Value;
    if Uri = '' then Exit;

    if Method = 'textDocument/didOpen' then
    begin
      if (TextDoc.GetValue('languageId') = nil) or
         (TextDoc.GetValue('version') = nil) or
         (TextDoc.GetValue('text') = nil) then Exit;
      Doc.LanguageId := TextDoc.GetValue('languageId').Value;
      Doc.Version := StrToIntDef(TextDoc.GetValue('version').Value, 0);
      Doc.Text := TextDoc.GetValue('text').Value;
      FOpenDocs.AddOrSetValue(Uri, Doc);
      Diag(Format('didOpen tracked: %s (lang=%s, ver=%d, len=%d)',
        [Uri, Doc.LanguageId, Doc.Version, Length(Doc.Text)]));
    end
    else if Method = 'textDocument/didChange' then
    begin
      Found := FOpenDocs.TryGetValue(Uri, Doc);
      if not Found then
      begin
        Diag('didChange for untracked document: ' + Uri);
        Exit;
      end;
      if TextDoc.GetValue('version') <> nil then
        Doc.Version := StrToIntDef(TextDoc.GetValue('version').Value, Doc.Version);
      Changes := TJSONArray(Params.GetValue('contentChanges'));
      if Changes <> nil then
        for I := 0 to Changes.Count - 1 do
        begin
          ChangeObj := TJSONObject(Changes.Items[I]);
          if ChangeObj <> nil then
            ApplyContentChange(Doc.Text, ChangeObj);
        end;
      FOpenDocs.AddOrSetValue(Uri, Doc);
    end
    else if Method = 'textDocument/didClose' then
    begin
      if FOpenDocs.ContainsKey(Uri) then
      begin
        FOpenDocs.Remove(Uri);
        Diag('didClose tracked: ' + Uri);
      end;
    end;
  finally
    Root.Free;
  end;
end;

// Kill the current DelphiLSP child and start a new one. Replays:
//   1. cached `initialize` (rewritten with a synthetic ID we own; reader
//      drops the matching response so the client never sees a duplicate)
//   2. cached `initialized` notification
//   3. `workspace/didChangeConfiguration` for the current active project
//   4. `textDocument/didOpen` for every entry in FOpenDocs
// Holds FChildInLock for the whole sequence so the main proxy loop's
// next forward goes to the new child cleanly.
procedure TLspSession.RecycleChild;
var
  CachedInit, CachedInited, CurrentUri: string;
  ReplayIdNum: Integer;
  Pair: TPair<string, TOpenDocument>;
  ReplayedDocs: Integer;
begin
  Diag('RecycleChild: starting');
  if FCachedInitJson = '' then
  begin
    Diag('RecycleChild: no cached initialize, aborting');
    Exit;
  end;

  FChildInLock.Acquire;
  try
    CachedInit := FCachedInitJson;
    CachedInited := FCachedInitializedJson;

    // Tear down old child (closes pipes, joins reader, frees streams).
    StopChildConnection;

    // Spawn fresh child + start a new reader for it.
    if not StartChildConnection then
    begin
      Diag('RecycleChild: StartChildConnection failed; shim is now without a child');
      Exit;
    end;

    // Synthetic ID lets the reader recognize and drop the replayed init's
    // response (the original ID was already consumed by the LSP client).
    // Distinctive large negative value: very unlikely to collide with the
    // LSP client's positive-integer id stream, and a number (not a string)
    // because DelphiLSP doesn't echo string ids — see RewriteInitId comment.
    Inc(FRecycleCounter);
    ReplayIdNum := -1000000 - FRecycleCounter;
    if FReader <> nil then
      FReader.SwallowResponseId(IntToStr(ReplayIdNum));

    WriteRawLocked(RewriteInitId(CachedInit, ReplayIdNum));
    if CachedInited <> '' then
      WriteRawLocked(CachedInited);

    // Re-fire didChangeConfiguration for current project, if known.
    TMonitor.Enter(GProjectGuard);
    try
      if GActiveProject <> nil then
        CurrentUri := GActiveProject.Uri
      else
        CurrentUri := '';
    finally
      TMonitor.Exit(GProjectGuard);
    end;
    if CurrentUri <> '' then
      WriteRawLocked(MakeDidChangeConfigJson(CurrentUri));

    // Replay every open document so DelphiLSP rebuilds its in-memory model.
    ReplayedDocs := 0;
    for Pair in FOpenDocs do
    begin
      WriteRawLocked(MakeDidOpenJson(Pair.Key, Pair.Value));
      Inc(ReplayedDocs);
    end;

    Diag(Format('RecycleChild: replay complete (replayId=%d, didOpens=%d)',
      [ReplayIdNum, ReplayedDocs]));
  finally
    FChildInLock.Release;
  end;
end;

// Forward decls — sticky-pick helpers live further down (grouped with other
// plugin-data resolution), but SwitchToProject below needs to call them.

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
begin
  if GSessionDir = '' then Exit;
  if not ConsumeFlagFile(IncludeTrailingPathDelimiter(GSessionDir) +
                         'reload.flag') then Exit;
  Diag('Reload flag detected; recycling child');
  if GSession <> nil then
    GSession.RecycleChild;
end;





procedure InitSessionState;
var
  Base, FromArg, FromScan, ClaudePidDir: string;
  Ancestors: TArray<DWORD>;
  AncIdx: Integer;
  AncId: DWORD;
begin
  DumpClaudeEnv;
  DumpArgv;
  DumpProcessIdentity;
  GClaudeSessionId := GetEnv('CLAUDE_CODE_SESSION_ID', '');
  // Reject unsubstituted manifest placeholders — Claude Code 2.1.x doesn't
  // expand ${CLAUDE_CODE_SESSION_ID} in lspServers.<n>.env (only the
  // ${CLAUDE_PLUGIN_ROOT}/${CLAUDE_PLUGIN_DATA}/${user_config.*} whitelist
  // substitutes; arbitrary env vars pass through literally). Without this
  // guard the shim would accept the literal placeholder as a session id
  // and write sticky to a bogus filename.
  if (GClaudeSessionId <> '') and
     ((Pos('${', GClaudeSessionId) > 0) or
      SameText(GClaudeSessionId, '${CLAUDE_CODE_SESSION_ID}')) then
  begin
    Diag('env CLAUDE_CODE_SESSION_ID is unsubstituted placeholder; ignoring');
    GClaudeSessionId := '';
  end;
  if GClaudeSessionId <> '' then
    Diag('Claude session id from env: ' + GClaudeSessionId)
  else
  begin
    FromArg := ParseSessionIdFromArgv;
    if FromArg <> '' then
    begin
      GClaudeSessionId := FromArg;
      Diag('Claude session id from argv: ' + GClaudeSessionId);
    end
    else
    begin
      // Resolve <plugin-data>/claude-pid once; the resolvers operate against it.
      ClaudePidDir := IncludeTrailingPathDelimiter(ResolvePluginDataBase) + 'claude-pid';

      // Walk the shim's process ancestry looking for any hook drop file
      // keyed by an ancestor PID. The hook writes one file per ancestor;
      // we walk ours from the bottom up. They share Claude Code's main
      // process (or higher) as a common ancestor — race-free per Claude
      // Code instance, even with multiple simultaneous sessions in the
      // same workspace.
      Ancestors := GetAncestorPids(GetCurrentProcessId);
      Diag(Format('Walking %d ancestor(s) for hook drop file', [Length(Ancestors)]));
      for AncIdx := 0 to High(Ancestors) do
      begin
        AncId := Ancestors[AncIdx];
        Diag(Format('  ancestor[%d]=%d', [AncIdx, AncId]));
        FromScan := ReadSessionIdFromHookFile(ClaudePidDir, IntToStr(AncId));
        if FromScan <> '' then
        begin
          GClaudeSessionId := FromScan;
          Diag(Format('Claude session id from hook file (ancestor pid=%d): %s',
            [AncId, GClaudeSessionId]));
          Break;
        end;
      end;

      if GClaudeSessionId = '' then
      begin
        // Fallback: by-id-*.json scan + cwd canonical match. Used to be
        // the primary on Windows when hook PPID was wrong; now a backstop.
        FromScan := ResolveSessionIdViaHookFiles(ClaudePidDir, GetCurrentDir);
        if FromScan <> '' then
        begin
          GClaudeSessionId := FromScan;
          Diag('Claude session id from hook by-id scan: ' + GClaudeSessionId);
        end;
      end;

      if GClaudeSessionId = '' then
      begin
        // Last resort: most-recent .jsonl mtime in projects dir. Race window
        // for simultaneous same-cwd sessions.
        FromScan := DiscoverSessionIdFromProjectsDir(ResolveProjectsRoot, GetCurrentDir);
        if FromScan <> '' then
        begin
          GClaudeSessionId := FromScan;
          Diag('Claude session id from projects-dir scan: ' + GClaudeSessionId);
        end;
      end;
    end;
  end;
  if GClaudeSessionId = '' then
  begin
    Diag('Claude session id unresolvable (env/argv/hook/scan all failed); cross-session sticky disabled');
    Exit;
  end;
  Base := ResolvePluginDataBase;
  if Base = '' then
  begin
    Diag('No plugin-data base; cross-session sticky disabled');
    Exit;
  end;
  GSessionStatePath := IncludeTrailingPathDelimiter(Base) + 'session-state' +
                       PathDelim + GClaudeSessionId + '.json';
  Diag('Session state path: ' + GSessionStatePath);
end;

procedure RegisterSession;
var
  Base, SessionsRoot, WorkspaceFile: string;
  WS: TStringList;
begin
  Base := ResolvePluginDataBase;
  if Base = '' then
  begin
    Diag('No usable data dir; running without per-session sentinel');
    Exit;
  end;
  SessionsRoot := IncludeTrailingPathDelimiter(Base) + 'sessions';
  GcOrphanSessions(SessionsRoot, GetCurrentProcessId);
  GSessionDir := IncludeTrailingPathDelimiter(SessionsRoot) +
                 IntToStr(GetCurrentProcessId);
  GActiveSentinelPath := IncludeTrailingPathDelimiter(GSessionDir) + 'active.txt';
  try
    if not ForceDirectories(GSessionDir) then
    begin
      Diag('ForceDirectories failed: ' + GSessionDir);
      GSessionDir := ''; GActiveSentinelPath := '';
      Exit;
    end;
    WorkspaceFile := IncludeTrailingPathDelimiter(GSessionDir) + 'workspace.txt';
    WS := TStringList.Create;
    try
      WS.Add(GetCurrentDir);
      WS.SaveToFile(WorkspaceFile, TEncoding.UTF8);
    finally
      WS.Free;
    end;
    Diag('Registered session at ' + GSessionDir);
  except
    on E: Exception do
    begin
      Diag('Session registration failed: ' + E.Message);
      GSessionDir := ''; GActiveSentinelPath := '';
    end;
  end;
end;

procedure UnregisterSession;
begin
  if GSessionDir = '' then Exit;
  try
    TDirectory.Delete(GSessionDir, True);
  except
    // best effort; an orphaned session dir is harmless
  end;
end;

{ TSentinelWatcherThread }

constructor TSentinelWatcherThread.Create(const ADir: string);
begin
  FDir := ADir;
  FShutdownEvent := TEvent.Create(nil, True, False, '');
  inherited Create(False);
end;

destructor TSentinelWatcherThread.Destroy;
begin
  FShutdownEvent.Free;
  inherited;
end;

procedure TSentinelWatcherThread.SignalShutdown;
begin
  FShutdownEvent.SetEvent;
end;

procedure TSentinelWatcherThread.Execute;
var
  ChangeHandle: THandle;
  Handles: array[0..1] of THandle;
  WaitResult: DWORD;
begin
  if FDir = '' then Exit;
  ChangeHandle := FindFirstChangeNotification(PChar(FDir), False,
    FILE_NOTIFY_CHANGE_LAST_WRITE or FILE_NOTIFY_CHANGE_FILE_NAME);
  if ChangeHandle = INVALID_HANDLE_VALUE then
  begin
    Diag('Sentinel watcher: FindFirstChangeNotification failed for ' + FDir);
    Exit;
  end;
  try
    Handles[0] := ChangeHandle;
    Handles[1] := FShutdownEvent.Handle;
    while not Terminated do
    begin
      WaitResult := WaitForMultipleObjects(2, @Handles[0], False, INFINITE);
      if WaitResult = WAIT_OBJECT_0 then
      begin
        try
          ReadAndApplySentinel;
          ReadAndApplyReloadFlag;
          ReadAndApplyShimReloadFlag;
        except
          on E: Exception do Diag('Sentinel callback error: ' + E.Message);
        end;
        FindNextChangeNotification(ChangeHandle);
      end
      else if WaitResult = WAIT_OBJECT_0 + 1 then
        Break;
    end;
  finally
    FindCloseChangeNotification(ChangeHandle);
  end;
  Diag('Sentinel watcher exiting');
end;

{ TActiveFileWatcherThread }

constructor TActiveFileWatcherThread.Create(AProject: TActiveProject; const ADir: string);
begin
  FProject := AProject;
  FDir := ADir;
  FShutdownEvent := TEvent.Create(nil, True, False, '');
  inherited Create(False);
end;

destructor TActiveFileWatcherThread.Destroy;
begin
  FShutdownEvent.Free;
  inherited;
end;

procedure TActiveFileWatcherThread.SignalShutdown;
begin
  FShutdownEvent.SetEvent;
end;

procedure TActiveFileWatcherThread.Execute;
var
  ChangeHandle: THandle;
  Handles: array[0..1] of THandle;
  WaitResult: DWORD;
begin
  if (FDir = '') or (not DirectoryExists(FDir)) then
  begin
    Diag('ActiveFileWatcher: dir missing, skipping: ' + FDir);
    Exit;
  end;
  ChangeHandle := FindFirstChangeNotification(PChar(FDir), False,
    FILE_NOTIFY_CHANGE_LAST_WRITE or FILE_NOTIFY_CHANGE_FILE_NAME or FILE_NOTIFY_CHANGE_SIZE);
  if ChangeHandle = INVALID_HANDLE_VALUE then
  begin
    Diag(Format('ActiveFileWatcher: FindFirstChangeNotification failed for %s (gle=%d)',
      [FDir, GetLastError]));
    Exit;
  end;
  try
    Handles[0] := ChangeHandle;
    Handles[1] := FShutdownEvent.Handle;
    while not Terminated do
    begin
      WaitResult := WaitForMultipleObjects(2, @Handles[0], False, INFINITE);
      if WaitResult = WAIT_OBJECT_0 then
      begin
        // Just mark invalidated; the main proxy loop hashes lazily on the
        // next inbound LSP message and decides whether to re-fire.
        try
          if FProject <> nil then FProject.Invalidate;
        except
          on E: Exception do Diag('ActiveFileWatcher invalidate error: ' + E.Message);
        end;
        FindNextChangeNotification(ChangeHandle);
      end
      else if WaitResult = WAIT_OBJECT_0 + 1 then
        Break;
    end;
  finally
    FindCloseChangeNotification(ChangeHandle);
  end;
  Diag('ActiveFileWatcher exiting for ' + FDir);
end;

{ TActiveProject }

constructor TActiveProject.Create(const APath: string);
begin
  inherited Create;
  FPath := APath;
  FUri := PathToFileUri(APath);
  FLastHash := ComputeHash;
  FInvalidated := False;
end;

destructor TActiveProject.Destroy;
begin
  if FWatcher <> nil then
  begin
    FWatcher.SignalShutdown;
    FWatcher.WaitFor;
    FWatcher.Free;
    FWatcher := nil;
  end;
  inherited;
end;

procedure TActiveProject.StartWatcher;
var
  Dir: string;
begin
  if FWatcher <> nil then Exit; // already started
  Dir := ExtractFilePath(FPath);
  if Dir = '' then Exit;
  // Strip the trailing path delimiter — FindFirstChangeNotification
  // accepts paths with or without it, but `DirectoryExists` is happier
  // with the canonical form.
  Dir := ExcludeTrailingPathDelimiter(Dir);
  FWatcher := TActiveFileWatcherThread.Create(Self, Dir);
end;

procedure TActiveProject.Invalidate;
begin
  TMonitor.Enter(Self);
  try
    if not FInvalidated then
    begin
      FInvalidated := True;
      Diag('Active file watcher: invalidated ' + FPath);
    end;
  finally
    TMonitor.Exit(Self);
  end;
end;

function TActiveProject.CheckAndConsumeIfChanged: Boolean;
var
  NewHash: string;
begin
  Result := False;
  TMonitor.Enter(Self);
  try
    if not FInvalidated then Exit;
    NewHash := ComputeHash;
    if NewHash = '' then
    begin
      // Couldn't read (transient mid-write?). Leave the flag set so the
      // next inbound LSP message retries the hash.
      Diag('Active file hash read failed; leaving invalidated for retry');
      Exit;
    end;
    FInvalidated := False;
    if NewHash <> FLastHash then
    begin
      FLastHash := NewHash;
      Result := True;
    end
    else
      Diag('Active file invalidation cleared: hash unchanged (no-op write)');
  finally
    TMonitor.Exit(Self);
  end;
end;

function TActiveProject.ComputeHash: string;
var
  FS: TFileStream;
  Hasher: THashSHA2;
  Buf: TBytes;
  Got: Integer;
begin
  Result := '';
  if not FileExists(FPath) then Exit;
  try
    FS := TFileStream.Create(FPath, fmOpenRead or fmShareDenyNone);
    try
      Hasher := THashSHA2.Create(SHA256);
      SetLength(Buf, 8192);
      repeat
        Got := FS.Read(Buf[0], Length(Buf));
        if Got > 0 then
          Hasher.Update(Buf, Got);
      until Got <= 0;
      Result := Hasher.HashAsString;
    finally
      FS.Free;
    end;
  except
    on E: Exception do
    begin
      Diag('ComputeHash failed for ' + FPath + ': ' + E.Message);
      Result := '';
    end;
  end;
end;

{ Child-reader thread: drains DelphiLSP -> our stdout }

constructor TChildReaderThread.Create(AFromChild, AToClient: TLspStream);
begin
  FFromChild := AFromChild;
  FToClient := AToClient;
  FSwallowIds := TList<string>.Create;
  inherited Create(False);
end;

destructor TChildReaderThread.Destroy;
begin
  FSwallowIds.Free;
  inherited;
end;

// Register a response ID that the reader should drop on its next sighting,
// then forget. Used by RecycleChild for the synthetic-init response.
procedure TChildReaderThread.SwallowResponseId(const Id: string);
begin
  TMonitor.Enter(FSwallowIds);
  try
    FSwallowIds.Add(Id);
  finally
    TMonitor.Exit(FSwallowIds);
  end;
end;

function TChildReaderThread.ShouldDrop(const Json: string): Boolean;
var
  Root: TJSONValue;
  Obj: TJSONObject;
  IdVal: TJSONValue;
  IdStr: string;
  Idx: Integer;
begin
  Result := False;
  Root := nil;
  try
    try
      Root := TJSONObject.ParseJSONValue(Json);
    except
      Exit;
    end;
    if not (Root is TJSONObject) then Exit;
    Obj := TJSONObject(Root);
    IdVal := Obj.GetValue('id');
    if IdVal = nil then Exit;
    IdStr := IdVal.Value;
    TMonitor.Enter(FSwallowIds);
    try
      Idx := FSwallowIds.IndexOf(IdStr);
      if Idx >= 0 then
      begin
        FSwallowIds.Delete(Idx);
        Result := True;
        Diag('Reader dropped replayed-init response (id=' + IdStr + ')');
      end;
    finally
      TMonitor.Exit(FSwallowIds);
    end;
  finally
    Root.Free;
  end;
end;

procedure TChildReaderThread.Execute;
var
  Json: string;
begin
  while not Terminated do
  begin
    if not FFromChild.ReadMessage(Json) then Break;
    if ShouldDrop(Json) then Continue;
    if not FToClient.WriteMessage(Json) then Break;
  end;
  Diag('Child reader thread exiting');
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
  I: Integer;
begin
  Explicit := GetEnv('DELPHI_LSP_SETTINGS', '');
  if (Explicit <> '') and FileExists(Explicit) then
  begin
    GActiveProject := TActiveProject.Create(Explicit);
    GActiveProject.StartWatcher;
    Diag('Initial settings URI (env DELPHI_LSP_SETTINGS): ' + GActiveProject.Uri);
    Exit;
  end;

  Sticky := ReadStickyForCwd(GSessionStatePath, GetCurrentDir);
  if Sticky <> '' then
  begin
    GActiveProject := TActiveProject.Create(Sticky);
    GActiveProject.StartWatcher;
    Diag('Restored sticky pick from previous session: ' + GActiveProject.Uri +
         ' — /delphi-project to change');
    Exit;
  end;

  Acc := TList<string>.Create;
  try
    CollectFilesByExt(GetCurrentDir, '.delphilsp.json', 0, Acc);
    if Acc.Count = 0 then
    begin
      Diag('No .delphilsp.json found in workspace');
      Exit;
    end;
    if Acc.Count = 1 then
    begin
      GActiveProject := TActiveProject.Create(Acc[0]);
      GActiveProject.StartWatcher;
      Diag('Initial settings URI (single candidate): ' + GActiveProject.Uri);
      WriteStickyForCwd(GSessionStatePath, GetCurrentDir, Acc[0]);
      Exit;
    end;
    Diag(Format('Multiple .delphilsp.json candidates (%d); shim starts without project — user must run /delphi-project', [Acc.Count]));
    for I := 0 to Acc.Count - 1 do
      Diag('  candidate: ' + Acc[I]);
  finally
    Acc.Free;
  end;
end;

var
  SentinelWatcher: TSentinelWatcherThread;
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
        IncludeTrailingPathDelimiter(ResolvePluginDataBase) + 'session-state',
        ResolveProjectsRoot,
        GClaudeSessionId);
      GcStaleClaudePidFiles(
        IncludeTrailingPathDelimiter(ResolvePluginDataBase) + 'claude-pid',
        ResolveProjectsRoot);
    end
    else
      Diag('GC: skipping (own session .jsonl not found or session id unresolved)');
    InitSettings;

    RegisterSession;
    // If a sentinel was already deposited before our spawn (e.g., the user
    // ran /delphi-project before this shim started up), pick it up now so
    // our initial `didChangeConfiguration` fires with the right URI.
    ReadAndApplySentinel;
    if GActiveProject <> nil then
      Diag('Effective settings URI: ' + GActiveProject.Uri)
    else
      Diag('Effective settings URI: (none)');

    if not GSession.StartChildConnection then
    begin
      Writeln(ErrOutput, 'delphi-lsp-shim: failed to spawn DelphiLSP');
      Halt(1);
    end;

    if GSessionDir <> '' then
    begin
      SentinelWatcher := TSentinelWatcherThread.Create(GSessionDir);
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

      UnregisterSession;
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
