// Copyright (c) 2026 Jared Davison. Released under the MIT License (see LICENSE).
//
// AI-generated (Claude Code). Review before trusting in production.
//
// LSP-session-scoped state that survives both /delphi-project switches
// AND /delphi-reload recycles:
//   - parent stdin/stdout streams (whole shim lifetime)
//   - child stdin/stdout streams + process handle (replaced on recycle)
//   - child-stdin write lock
//   - DidFireConfig flag
//   - cached `initialize` / `initialized` JSON for replay
//   - dictionary of open documents (mirrors what the LSP client believes
//     is open, used to replay didOpen to a fresh child after a recycle)
//
// The session does NOT reach into shim-level globals. Its consumer
// passes the active settings path / current URI as parameters so the
// session is self-contained and the dpr orchestrates the global state.

unit DelphiLsp.LspSession;

interface

uses
  Winapi.Windows,
  System.Classes,
  System.SyncObjs,
  System.Generics.Collections,
  DelphiLsp.LspWire,
  DelphiLsp.LspMessage;

type
  // Drains the child DelphiLSP -> client direction. Owned by TLspSession;
  // replaced on each recycle. The swallow-id list lets RecycleChild drop
  // the replayed-initialize response before it reaches the LSP client.
  TChildReaderThread = class(TThread)
  private
    FFromChild: TLspStream;
    FToClient: TLspStream;
    FSwallowIds: TList<string>;
    function ShouldDrop(const Json: string): Boolean;
  protected
    procedure Execute; override;
  public
    constructor Create(AFromChild, AToClient: TLspStream);
    destructor Destroy; override;
    procedure SwallowResponseId(const Id: string);
  end;

  TLspSession = class
  private
    FClientToShim: TLspStream;
    FShimToClient: TLspStream;
    FShimToChild: TLspStream;
    FChildToShim: TLspStream;
    FChildIn: THandle;
    FChildOut: THandle;
    FChildHandle: THandle;
    FChildInLock: TCriticalSection;
    FDidFireConfig: Boolean;
    FOpenDocs: TDictionary<string, TOpenDocument>;
    FCachedInitJson: string;
    FCachedInitializedJson: string;
    FReader: TChildReaderThread;
    FRecycleCounter: Integer;
    procedure WriteRawLocked(const Json: string);
    procedure TrackOutgoingMessageLocked(const Json: string;
      const Method: string);
  public
    constructor Create(AClientIn, AClientOut: THandle);
    destructor Destroy; override;

    // Spawn DelphiLSP and start a child-reader thread.
    //   SettingsPath — path of the active .delphilsp.json (or '');
    //                  feeds the LspPathResolver chain.
    //   SessionDir   — per-shim sentinel dir; passes through to the
    //                  resolver so /delphi-runtime overrides apply.
    // Returns True iff the child started successfully.
    function StartChildConnection(const SettingsPath,
      SessionDir: string): Boolean;

    // Tear down the current child + reader. Idempotent.
    procedure StopChildConnection;

    // Write a raw JSON message to the child. Locks FChildInLock.
    procedure WriteToChild(const Json: string);

    // Like WriteToChild but also runs the message through the
    // initialize/initialized cache + didOpen/didChange/didClose
    // tracker before forwarding. Method is the parsed JSON-RPC method.
    procedure SendToChild(const Json: string; const Method: string);

    // /delphi-reload entry point. Tears down the child, spawns a fresh
    // one, and replays cached initialize, initialized,
    // didChangeConfiguration (using CurrentUri), and one didOpen per
    // tracked document. Holds the child-stdin lock for the whole
    // sequence so the main proxy loop's next forward goes to the new
    // child cleanly.
    procedure RecycleChild(const SettingsPath, SessionDir,
      CurrentUri: string);

    // True iff a child is connected (StartChildConnection succeeded
    // and StopChildConnection hasn't been called since).
    function ChildAlive: Boolean;

    property ClientStream: TLspStream read FClientToShim;
    property DidFireConfig: Boolean read FDidFireConfig write FDidFireConfig;
  end;

// Compute the next replay-id for a /delphi-reload synthetic-init
// request. Counter is incremented in place; the result is a
// monotonically-decreasing large negative integer that won't collide
// with the LSP client's positive-integer id stream.
//
// DelphiLSP doesn't preserve string ids in responses (parseInt-coerces
// them, falling back to 0 on failure), so we use numeric ids here —
// see RewriteInitId comment in DelphiLsp.LspMessage.
function NextReplayId(var Counter: Integer): Integer;

implementation

uses
  System.SysUtils,
  DelphiLsp.Env,
  DelphiLsp.Logging,
  DelphiLsp.LspPathResolver;

function NextReplayId(var Counter: Integer): Integer;
const
  Base = -1000000;
begin
  Inc(Counter);
  Result := Base - Counter;
end;

{ TChildReaderThread }

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
  IdStr: string;
  Idx: Integer;
begin
  Result := False;
  IdStr := ExtractMessageId(Json);
  if IdStr = '' then Exit;
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
end;

procedure TChildReaderThread.Execute;
var
  Json, Method: string;
begin
  while not Terminated do
  begin
    if not FFromChild.ReadMessage(Json) then Break;
    Method := GetMessageMethod(Json);
    if Method <> '' then
    begin
      DiagVerbose('reader<-child: method=' + Method +
                  ' len=' + IntToStr(Length(Json)));
      if Method = 'textDocument/publishDiagnostics' then
        DiagVerbose('  body=' + Json);
    end
    else
    begin
      DiagVerbose('reader<-child: response len=' + IntToStr(Length(Json)));
      // Dump response body too — capped to 2KB so workspace/symbol-style
      // huge responses don't flood the log. Lets triage distinguish a
      // semantic-rich documentSymbol response (signatures with types)
      // from a syntactic-only one (bare identifiers).
      if Length(Json) > 2000 then
        DiagVerbose('  body=' + Copy(Json, 1, 2000) +
          Format(' [+%d more chars]', [Length(Json) - 2000]))
      else
        DiagVerbose('  body=' + Json);
    end;
    if ShouldDrop(Json) then Continue;
    if not FToClient.WriteMessage(Json) then Break;
  end;
  Diag('Child reader thread exiting');
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

function TLspSession.StartChildConnection(const SettingsPath,
  SessionDir: string): Boolean;
var
  SecAttr: TSecurityAttributes;
  ChildInRead, ChildOutWrite: THandle;
  StartupInfo: TStartupInfo;
  ProcInfo: TProcessInformation;
  CmdLine: string;
  ExePath, LogModes, Cwd, ExeSource: string;
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

  ExePath := ResolveDelphiLspPath(SettingsPath, SessionDir, ExeSource);
  LogModes := GetEnv('DELPHI_LSP_LOG_MODES', '0');
  Cwd := GetCurrentDir;
  CmdLine := Format('"%s" -LogModes %s -LSPLogging "%s"',
    [ExePath, LogModes, Cwd]);

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
    FReader.Terminate;
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

procedure TLspSession.TrackOutgoingMessageLocked(const Json: string;
  const Method: string);
var
  Uri, SynthDidOpenJson: string;
  Doc: TOpenDocument;
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

  if Method = 'textDocument/didOpen' then
  begin
    DiagVerbose('didOpen body=' + Json);
    if not TryParseDidOpen(Json, Uri, Doc) then Exit;
    FOpenDocs.AddOrSetValue(Uri, Doc);
    Diag(Format('didOpen tracked: %s (lang=%s, ver=%d, len=%d)',
      [Uri, Doc.LanguageId, Doc.Version, Length(Doc.Text)]));
  end
  else if Method = 'textDocument/didChange' then
  begin
    DiagVerbose('didChange body=' + Json);
    if not TryExtractTextDocumentUri(Json, Uri) then Exit;
    if not FOpenDocs.TryGetValue(Uri, Doc) then
    begin
      // Auto-didOpen: Claude Code's Edit/Read tooling drives didChange
      // without first sending didOpen. DelphiLSP needs a baseline or it
      // returns empty diagnostics. Synthesize a didOpen by reading the
      // file from disk, forward it to the child before the actual
      // didChange continues.
      if TryBuildSyntheticDidOpen(Uri, 1, Doc, SynthDidOpenJson) then
      begin
        WriteRawLocked(SynthDidOpenJson);
        FOpenDocs.AddOrSetValue(Uri, Doc);
        Diag(Format('Auto-didOpen synthesized: %s (len=%d)',
          [Uri, Length(Doc.Text)]));
      end
      else
      begin
        Diag('didChange for untracked document: ' + Uri);
        Exit;
      end;
    end;
    if TryApplyDidChange(Json, Doc) then
    begin
      FOpenDocs.AddOrSetValue(Uri, Doc);
      DiagVerbose(Format('didChange tracked: %s (ver=%d, len=%d)',
        [Uri, Doc.Version, Length(Doc.Text)]));
    end;
  end
  else if Method = 'textDocument/didClose' then
  begin
    if not TryExtractTextDocumentUri(Json, Uri) then Exit;
    if FOpenDocs.ContainsKey(Uri) then
    begin
      FOpenDocs.Remove(Uri);
      Diag('didClose tracked: ' + Uri);
    end;
  end;
end;

procedure TLspSession.RecycleChild(const SettingsPath, SessionDir,
  CurrentUri: string);
var
  CachedInit, CachedInited: string;
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

    StopChildConnection;

    if not StartChildConnection(SettingsPath, SessionDir) then
    begin
      Diag('RecycleChild: StartChildConnection failed; shim is now without a child');
      Exit;
    end;

    ReplayIdNum := NextReplayId(FRecycleCounter);
    if FReader <> nil then
      FReader.SwallowResponseId(IntToStr(ReplayIdNum));

    WriteRawLocked(RewriteInitId(CachedInit, ReplayIdNum));
    if CachedInited <> '' then
      WriteRawLocked(CachedInited);

    if CurrentUri <> '' then
      WriteRawLocked(MakeDidChangeConfigJson(CurrentUri));

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

end.
