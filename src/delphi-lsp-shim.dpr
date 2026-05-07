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
  System.SysUtils,
  System.Classes,
  System.IOUtils,
  System.JSON,
  System.SyncObjs,
  System.Hash,
  System.Generics.Collections,
  System.Generics.Defaults;

type
  TLspStream = class
  private
    FStream: THandleStream;
  public
    constructor Create(AHandle: THandle);
    destructor Destroy; override;
    function ReadByte(out B: Byte): Boolean;
    function ReadExact(var Buf; Count: Integer): Boolean;
    function WriteExact(const Buf; Count: Integer): Boolean;
    function ReadMessage(out Json: string): Boolean;
    function WriteMessage(const Json: string): Boolean;
  end;

  TChildReaderThread = class(TThread)
  private
    FFromChild: TLspStream;
    FToClient: TLspStream;
  protected
    procedure Execute; override;
  public
    constructor Create(AFromChild, AToClient: TLspStream);
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
  GLogPath: string;
  GShimToChild: TLspStream;
  GChildToShim: TLspStream;
  GClientToShim: TLspStream;
  GShimToClient: TLspStream;
  GChildHandle: THandle;
  GDidFireConfig: Boolean;            // guarded by GProjectGuard
  GChildInLock: TCriticalSection;     // serializes writes to child stdin
  GProjectGuard: TObject;             // TMonitor sentinel for GActiveProject access
  GActiveProject: TActiveProject;     // current project (replaceable)
  GSessionDir: string;                // ${CLAUDE_PLUGIN_DATA}/sessions/<PID>/
  GActiveSentinelPath: string;        // <session>/active.txt

procedure Diag(const Msg: string);
var
  F: TextFile;
  Line: string;
begin
  if GLogPath = '' then Exit;
  Line := Format('[%s] %s', [FormatDateTime('yyyy-mm-dd hh:nn:ss.zzz', Now), Msg]);
  try
    AssignFile(F, GLogPath);
    if FileExists(GLogPath) then Append(F) else Rewrite(F);
    try
      Writeln(F, Line);
    finally
      CloseFile(F);
    end;
  except
    // best effort
  end;
end;

function GetEnv(const Name, Default: string): string;
begin
  Result := GetEnvironmentVariable(Name);
  if Result = '' then Result := Default;
end;

{ TLspStream }

constructor TLspStream.Create(AHandle: THandle);
begin
  inherited Create;
  FStream := THandleStream.Create(AHandle);
end;

destructor TLspStream.Destroy;
begin
  // THandleStream does NOT close its handle; ownership stays with caller.
  FStream.Free;
  inherited;
end;

function TLspStream.ReadByte(out B: Byte): Boolean;
var
  Got: Integer;
begin
  Got := FStream.Read(B, 1);
  Result := Got = 1;
end;

function TLspStream.ReadExact(var Buf; Count: Integer): Boolean;
var
  P: PByte;
  Got: Integer;
  Remaining: Integer;
begin
  P := @Buf;
  Remaining := Count;
  while Remaining > 0 do
  begin
    Got := FStream.Read(P^, Remaining);
    if Got <= 0 then Exit(False);
    Inc(P, Got);
    Dec(Remaining, Got);
  end;
  Result := True;
end;

function TLspStream.WriteExact(const Buf; Count: Integer): Boolean;
var
  P: PByte;
  Wrote: Integer;
  Remaining: Integer;
begin
  P := @Buf;
  Remaining := Count;
  while Remaining > 0 do
  begin
    Wrote := FStream.Write(P^, Remaining);
    if Wrote <= 0 then Exit(False);
    Inc(P, Wrote);
    Dec(Remaining, Wrote);
  end;
  Result := True;
end;

function TLspStream.ReadMessage(out Json: string): Boolean;
var
  HeaderBytes: TBytes;
  B: Byte;
  HeaderStr: string;
  Lines: TArray<string>;
  Line: string;
  ColonIdx: Integer;
  ContentLen: Integer;
  BodyBytes: TBytes;
begin
  Json := '';
  SetLength(HeaderBytes, 0);
  ContentLen := -1;
  while True do
  begin
    if not ReadByte(B) then Exit(False);
    SetLength(HeaderBytes, Length(HeaderBytes) + 1);
    HeaderBytes[High(HeaderBytes)] := B;
    if (Length(HeaderBytes) >= 4) and
       (HeaderBytes[High(HeaderBytes) - 3] = 13) and
       (HeaderBytes[High(HeaderBytes) - 2] = 10) and
       (HeaderBytes[High(HeaderBytes) - 1] = 13) and
       (HeaderBytes[High(HeaderBytes)]     = 10) then
      Break;
    if Length(HeaderBytes) > 8192 then
    begin
      Diag('LSP header exceeded 8KB; aborting read');
      Exit(False);
    end;
  end;
  HeaderStr := TEncoding.ASCII.GetString(HeaderBytes);
  Lines := HeaderStr.Split([#13#10]);
  for Line in Lines do
  begin
    ColonIdx := Pos(':', Line);
    if (ColonIdx > 0) and
       SameText(Trim(Copy(Line, 1, ColonIdx - 1)), 'Content-Length') then
    begin
      if not TryStrToInt(Trim(Copy(Line, ColonIdx + 1, MaxInt)), ContentLen) then
        ContentLen := -1;
      Break;
    end;
  end;
  if ContentLen < 0 then
  begin
    Diag('No Content-Length header found');
    Exit(False);
  end;
  if ContentLen = 0 then Exit(True);
  SetLength(BodyBytes, ContentLen);
  if not ReadExact(BodyBytes[0], ContentLen) then Exit(False);
  Json := TEncoding.UTF8.GetString(BodyBytes);
  Result := True;
end;

function TLspStream.WriteMessage(const Json: string): Boolean;
var
  Bytes: TBytes;
  Header: RawByteString;
  HeaderBytes: TBytes;
begin
  Bytes := TEncoding.UTF8.GetBytes(Json);
  Header := UTF8Encode('Content-Length: ' + IntToStr(Length(Bytes)) + #13#10#13#10);
  SetLength(HeaderBytes, Length(Header));
  if Length(Header) > 0 then
    Move(Header[1], HeaderBytes[0], Length(Header));
  if not WriteExact(HeaderBytes[0], Length(HeaderBytes)) then Exit(False);
  if Length(Bytes) > 0 then
    Result := WriteExact(Bytes[0], Length(Bytes))
  else
    Result := True;
end;

{ Path / settings file helpers }

function PathToFileUri(const Path: string): string;
var
  Normalized, Encoded: string;
  I: Integer;
  Ch: Char;
begin
  Normalized := StringReplace(Path, '\', '/', [rfReplaceAll]);
  Encoded := '';
  for I := 1 to Length(Normalized) do
  begin
    Ch := Normalized[I];
    case Ch of
      'A'..'Z', 'a'..'z', '0'..'9', '/', '-', '_', '.', '~', ':':
        Encoded := Encoded + Ch;
    else
      Encoded := Encoded + '%' + IntToHex(Ord(Ch), 2);
    end;
  end;
  Result := 'file:///' + Encoded;
end;

procedure CollectSettingsFiles(const Dir: string; Depth: Integer; Acc: TList<string>);
const
  MaxDepth = 6;
var
  SR: TSearchRec;
  FullPath, NameLower: string;
  Skip: Boolean;
begin
  if Depth > MaxDepth then Exit;
  if FindFirst(IncludeTrailingPathDelimiter(Dir) + '*', faAnyFile, SR) = 0 then
  try
    repeat
      if (SR.Name = '.') or (SR.Name = '..') then Continue;
      NameLower := LowerCase(SR.Name);
      Skip := (Length(SR.Name) > 0) and (SR.Name[1] = '.');
      if not Skip then
        Skip := (NameLower = 'node_modules') or (NameLower = '__history') or
                (NameLower = '__recovery') or (NameLower = 'win32') or
                (NameLower = 'win64') or (NameLower = '.git') or (NameLower = '.svn');
      if Skip then Continue;
      FullPath := IncludeTrailingPathDelimiter(Dir) + SR.Name;
      if (SR.Attr and faDirectory) <> 0 then
        CollectSettingsFiles(FullPath, Depth + 1, Acc)
      else if NameLower.EndsWith('.delphilsp.json') then
        Acc.Add(FullPath);
    until FindNext(SR) <> 0;
  finally
    FindClose(SR);
  end;
end;

function FindSettingsFile(const Root: string): string;
var
  Acc: TList<string>;
begin
  Result := '';
  Acc := TList<string>.Create;
  try
    CollectSettingsFiles(Root, 0, Acc);
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

{ JSON manipulation }

function GetMessageMethod(const Json: string): string;
var
  Root: TJSONValue;
  Obj: TJSONObject;
  MethodVal: TJSONValue;
begin
  Result := '';
  Root := nil;
  try
    try
      Root := TJSONObject.ParseJSONValue(Json);
    except
      on E: Exception do
      begin
        Diag('JSON parse failed: ' + E.Message);
        Exit;
      end;
    end;
    if not (Root is TJSONObject) then Exit;
    Obj := Root as TJSONObject;
    MethodVal := Obj.GetValue('method');
    if (MethodVal <> nil) and (MethodVal is TJSONString) then
      Result := TJSONString(MethodVal).Value;
  finally
    Root.Free;
  end;
end;

function InjectInitOptions(const Json: string): string;
var
  Root: TJSONValue;
  Obj, ParamsObj, InitOpts: TJSONObject;
  ParamsVal, InitVal, MethodVal: TJSONValue;
  ServerType: string;
  AgentCount: Integer;
  ExistingPair: TJSONPair;
begin
  Result := Json;
  Root := nil;
  try
    try
      Root := TJSONObject.ParseJSONValue(Json);
    except
      Exit;
    end;
    if not (Root is TJSONObject) then Exit;
    Obj := Root as TJSONObject;
    MethodVal := Obj.GetValue('method');
    if (MethodVal = nil) or not (MethodVal is TJSONString) or
       (TJSONString(MethodVal).Value <> 'initialize') then Exit;

    ParamsVal := Obj.GetValue('params');
    if (ParamsVal = nil) or not (ParamsVal is TJSONObject) then Exit;
    ParamsObj := ParamsVal as TJSONObject;

    ServerType := GetEnv('DELPHI_LSP_SERVER_TYPE', 'controller');
    AgentCount := StrToIntDef(GetEnv('DELPHI_LSP_AGENT_COUNT', '2'), 2);

    InitVal := ParamsObj.GetValue('initializationOptions');
    if (InitVal <> nil) and (InitVal is TJSONObject) then
    begin
      InitOpts := InitVal as TJSONObject;
      if InitOpts.GetValue('serverType') = nil then
        InitOpts.AddPair('serverType', ServerType);
      if InitOpts.GetValue('agentCount') = nil then
        InitOpts.AddPair('agentCount', TJSONNumber.Create(AgentCount));
    end
    else
    begin
      ExistingPair := ParamsObj.RemovePair('initializationOptions');
      if ExistingPair <> nil then ExistingPair.Free;
      InitOpts := TJSONObject.Create;
      InitOpts.AddPair('serverType', ServerType);
      InitOpts.AddPair('agentCount', TJSONNumber.Create(AgentCount));
      ParamsObj.AddPair('initializationOptions', InitOpts);
    end;

    Result := Obj.ToJSON;
    Diag(Format('Injected initializationOptions serverType=%s agentCount=%d',
      [ServerType, AgentCount]));
  finally
    Root.Free;
  end;
end;

function MakeDidChangeConfigJson(const Uri: string): string;
var
  Root, Params, Settings: TJSONObject;
begin
  Root := TJSONObject.Create;
  try
    Root.AddPair('jsonrpc', '2.0');
    Root.AddPair('method', 'workspace/didChangeConfiguration');
    Settings := TJSONObject.Create;
    Settings.AddPair('settingsFile', Uri);
    Params := TJSONObject.Create;
    Params.AddPair('settings', Settings);
    Root.AddPair('params', Params);
    Result := Root.ToJSON;
  finally
    Root.Free;
  end;
end;

{ Child-stdin write helpers + sentinel handling }

// All writes to the child's stdin must funnel through this so the main
// reader thread, sentinel watcher, and any other future writer don't
// interleave Content-Length-framed JSON-RPC messages.
procedure SafeWriteToChild(const Json: string);
begin
  GChildInLock.Acquire;
  try
    if GShimToChild <> nil then
      GShimToChild.WriteMessage(Json);
  finally
    GChildInLock.Release;
  end;
end;

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

  Old := nil;
  ShouldFire := False;
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
    ShouldFire := GDidFireConfig;
    NewUri := NewProj.Uri;
  finally
    TMonitor.Exit(GProjectGuard);
  end;
  // Free outside the guard — we own the only ref now and freeing involves
  // joining the watcher thread, which can take a moment.
  if Old <> nil then Old.Free;
  if ShouldFire then
  begin
    SafeWriteToChild(MakeDidChangeConfigJson(NewUri));
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
    if (P = nil) or (not GDidFireConfig) then Exit;
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
    SafeWriteToChild(MakeDidChangeConfigJson(Uri));
    Diag('Re-fired didChangeConfiguration after content change: ' + Uri);
  end;
end;

procedure ReadAndApplySentinel;
var
  ContentLines: TStringList;
  Path: string;
begin
  if (GActiveSentinelPath = '') or not FileExists(GActiveSentinelPath) then Exit;
  ContentLines := TStringList.Create;
  try
    try
      ContentLines.LoadFromFile(GActiveSentinelPath, TEncoding.UTF8);
    except
      on E: Exception do
      begin
        Diag('Sentinel read failed: ' + E.Message);
        Exit;
      end;
    end;
    if ContentLines.Count = 0 then Exit;
    Path := Trim(ContentLines[0]);
    if Path <> '' then SwitchToProject(Path);
  finally
    ContentLines.Free;
  end;
end;

procedure RegisterSession;
var
  Base, WorkspaceFile: string;
  WS: TStringList;
begin
  // Prefer CLAUDE_PLUGIN_DATA when Claude Code exports it; fall back to
  // %LOCALAPPDATA%\delphi-lsp-claude so slash commands have a deterministic
  // path to find us regardless of plugin-install layout. Both sides of the
  // shim/slash-command divide must resolve to the same dir, so the fallback
  // chain has to match in both places.
  Base := GetEnv('CLAUDE_PLUGIN_DATA', '');
  if Base = '' then
  begin
    Base := GetEnv('LOCALAPPDATA', '');
    if Base <> '' then
      Base := IncludeTrailingPathDelimiter(Base) + 'delphi-lsp-claude';
  end;
  if Base = '' then
  begin
    Diag('No usable data dir; running without per-session sentinel');
    Exit;
  end;
  GSessionDir := IncludeTrailingPathDelimiter(Base) + 'sessions' + PathDelim +
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
  inherited Create(False);
end;

procedure TChildReaderThread.Execute;
var
  Json: string;
begin
  while not Terminated do
  begin
    if not FFromChild.ReadMessage(Json) then Break;
    if not FToClient.WriteMessage(Json) then Break;
  end;
  Diag('Child reader thread exiting');
end;

{ Spawn DelphiLSP with redirected stdio }

function StartChild(out ChildHandle: THandle;
                    out ChildIn, ChildOut: THandle): Boolean;
var
  SecAttr: TSecurityAttributes;
  ChildInRead, ChildOutWrite: THandle;
  StartupInfo: TStartupInfo;
  ProcInfo: TProcessInformation;
  CmdLine: string;
  ExePath, LogModes, Cwd: string;
begin
  Result := False;
  ChildHandle := 0;
  SecAttr.nLength := SizeOf(SecAttr);
  SecAttr.bInheritHandle := True;
  SecAttr.lpSecurityDescriptor := nil;

  if not CreatePipe(ChildInRead, ChildIn, @SecAttr, 0) then
  begin
    Diag(Format('CreatePipe (stdin) failed: %d', [GetLastError]));
    Exit;
  end;
  SetHandleInformation(ChildIn, HANDLE_FLAG_INHERIT, 0);

  if not CreatePipe(ChildOut, ChildOutWrite, @SecAttr, 0) then
  begin
    Diag(Format('CreatePipe (stdout) failed: %d', [GetLastError]));
    CloseHandle(ChildInRead); CloseHandle(ChildIn);
    Exit;
  end;
  SetHandleInformation(ChildOut, HANDLE_FLAG_INHERIT, 0);

  ZeroMemory(@StartupInfo, SizeOf(StartupInfo));
  StartupInfo.cb := SizeOf(StartupInfo);
  StartupInfo.dwFlags := STARTF_USESTDHANDLES;
  StartupInfo.hStdInput := ChildInRead;
  StartupInfo.hStdOutput := ChildOutWrite;
  StartupInfo.hStdError := GetStdHandle(STD_ERROR_HANDLE);

  ExePath := GetEnv('DELPHI_LSP_EXE', 'DelphiLSP.exe');
  LogModes := GetEnv('DELPHI_LSP_LOG_MODES', '0');
  Cwd := GetCurrentDir;
  CmdLine := Format('"%s" -LogModes %s -LSPLogging "%s"', [ExePath, LogModes, Cwd]);

  Diag('Spawning: ' + CmdLine);
  Diag('Cwd: ' + Cwd);

  // CreateProcessW may modify lpCommandLine; ensure the string buffer is
  // refcount-1 (writable) before handing PChar to the kernel.
  UniqueString(CmdLine);
  if not CreateProcess(nil, PChar(CmdLine), nil, nil, True, 0, nil, nil,
                       StartupInfo, ProcInfo) then
  begin
    Diag(Format('CreateProcess failed: %d', [GetLastError]));
    CloseHandle(ChildInRead); CloseHandle(ChildIn);
    CloseHandle(ChildOutWrite); CloseHandle(ChildOut);
    Exit;
  end;

  ChildHandle := ProcInfo.hProcess;
  CloseHandle(ProcInfo.hThread);
  // Close child-side ends so EOF propagates naturally if child exits
  CloseHandle(ChildInRead);
  CloseHandle(ChildOutWrite);
  Result := True;
end;

procedure RunProxy;
var
  Reader: TChildReaderThread;
  Json, Method, UriToFire: string;
  P: TActiveProject;
begin
  Reader := TChildReaderThread.Create(GChildToShim, GShimToClient);
  try
    Reader.FreeOnTerminate := False;
    while True do
    begin
      if not GClientToShim.ReadMessage(Json) then Break;

      // Lazy hash check: if the active-file watcher marked the project
      // invalidated, hash now and re-fire didChangeConfiguration only if
      // the content actually changed.
      CheckAndApplyInvalidation;

      Method := GetMessageMethod(Json);
      if Method = 'initialize' then
        Json := InjectInitOptions(Json);
      SafeWriteToChild(Json);
      if Method = 'initialized' then
      begin
        UriToFire := '';
        TMonitor.Enter(GProjectGuard);
        try
          P := GActiveProject;
          if (not GDidFireConfig) and (P <> nil) then
          begin
            UriToFire := P.Uri;
            GDidFireConfig := True;
          end;
        finally
          TMonitor.Exit(GProjectGuard);
        end;
        if UriToFire <> '' then
        begin
          SafeWriteToChild(MakeDidChangeConfigJson(UriToFire));
          Diag('Sent didChangeConfiguration: ' + UriToFire);
        end;
      end;
    end;
    Diag('Client closed stdin');
  finally
    Reader.Terminate;
    Reader.WaitFor;
    Reader.Free;
  end;
end;

// Establish the initial active project from `DELPHI_LSP_SETTINGS` env var
// (explicit override) or by auto-discovering the shallowest .delphilsp.json
// under the workspace root. Runs before any worker threads start, so no
// guard needed.
procedure InitSettings;
var
  Explicit, Found: string;
begin
  Explicit := GetEnv('DELPHI_LSP_SETTINGS', '');
  if (Explicit <> '') and FileExists(Explicit) then
  begin
    GActiveProject := TActiveProject.Create(Explicit);
    GActiveProject.StartWatcher;
    Exit;
  end;
  Found := FindSettingsFile(GetCurrentDir);
  if Found <> '' then
  begin
    GActiveProject := TActiveProject.Create(Found);
    GActiveProject.StartWatcher;
  end;
end;

var
  ChildIn, ChildOut: THandle;
  SentinelWatcher: TSentinelWatcherThread;
begin
  GLogPath := GetEnv('DELPHI_LSP_SHIM_LOG', '');
  Diag('--- delphi-lsp-shim starting ---');
  Diag('CWD: ' + GetCurrentDir);

  GChildInLock := TCriticalSection.Create;
  GProjectGuard := TObject.Create;
  SentinelWatcher := nil;

  try
    InitSettings;
    if GActiveProject <> nil then
      Diag('Initial settings URI (auto-discovered): ' + GActiveProject.Uri)
    else
      Diag('Initial settings URI: (none discovered)');

    RegisterSession;
    // If a sentinel was already deposited before our spawn (e.g., the user
    // ran /delphi-project before this shim started up), pick it up now so
    // our initial `didChangeConfiguration` fires with the right URI.
    ReadAndApplySentinel;
    if GActiveProject <> nil then
      Diag('Effective settings URI: ' + GActiveProject.Uri)
    else
      Diag('Effective settings URI: (none)');

    if not StartChild(GChildHandle, ChildIn, ChildOut) then
    begin
      Writeln(ErrOutput, 'delphi-lsp-shim: failed to spawn DelphiLSP');
      Halt(1);
    end;

    GShimToChild   := TLspStream.Create(ChildIn);
    GChildToShim   := TLspStream.Create(ChildOut);
    GClientToShim  := TLspStream.Create(GetStdHandle(STD_INPUT_HANDLE));
    GShimToClient  := TLspStream.Create(GetStdHandle(STD_OUTPUT_HANDLE));

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
      // Close our side of the child stdin to signal EOF
      CloseHandle(ChildIn);
      if WaitForSingleObject(GChildHandle, 2000) = WAIT_TIMEOUT then
        TerminateProcess(GChildHandle, 0);
      CloseHandle(ChildOut);
      CloseHandle(GChildHandle);

      GShimToChild.Free;
      GChildToShim.Free;
      GClientToShim.Free;
      GShimToClient.Free;

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

  GChildInLock.Free;
  GProjectGuard.Free;
end.
