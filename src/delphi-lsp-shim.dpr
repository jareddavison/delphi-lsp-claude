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

var
  GLogPath: string;
  GShimToChild: TLspStream;
  GChildToShim: TLspStream;
  GClientToShim: TLspStream;
  GShimToClient: TLspStream;
  GChildHandle: THandle;
  GSettingsUri: string;
  GDidFireConfig: Boolean;

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
  Json, Method: string;
begin
  Reader := TChildReaderThread.Create(GChildToShim, GShimToClient);
  try
    Reader.FreeOnTerminate := False;
    while True do
    begin
      if not GClientToShim.ReadMessage(Json) then Break;
      Method := GetMessageMethod(Json);
      if Method = 'initialize' then
        Json := InjectInitOptions(Json);
      if not GShimToChild.WriteMessage(Json) then Break;
      if (Method = 'initialized') and (not GDidFireConfig) and (GSettingsUri <> '') then
      begin
        if GShimToChild.WriteMessage(MakeDidChangeConfigJson(GSettingsUri)) then
        begin
          GDidFireConfig := True;
          Diag('Sent didChangeConfiguration: ' + GSettingsUri);
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

procedure InitSettings;
var
  Explicit, Found: string;
begin
  Explicit := GetEnv('DELPHI_LSP_SETTINGS', '');
  if Explicit <> '' then
  begin
    if FileExists(Explicit) then GSettingsUri := PathToFileUri(Explicit);
    Exit;
  end;
  Found := FindSettingsFile(GetCurrentDir);
  if Found <> '' then GSettingsUri := PathToFileUri(Found);
end;

var
  ChildIn, ChildOut: THandle;
begin
  GLogPath := GetEnv('DELPHI_LSP_SHIM_LOG', '');
  Diag('--- delphi-lsp-shim starting ---');
  Diag('CWD: ' + GetCurrentDir);

  try
    InitSettings;
    Diag('Settings URI: ' + GSettingsUri);

    if not StartChild(GChildHandle, ChildIn, ChildOut) then
    begin
      Writeln(ErrOutput, 'delphi-lsp-shim: failed to spawn DelphiLSP');
      Halt(1);
    end;

    GShimToChild   := TLspStream.Create(ChildIn);
    GChildToShim   := TLspStream.Create(ChildOut);
    GClientToShim  := TLspStream.Create(GetStdHandle(STD_INPUT_HANDLE));
    GShimToClient  := TLspStream.Create(GetStdHandle(STD_OUTPUT_HANDLE));

    try
      RunProxy;
    finally
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
    end;
  except
    on E: Exception do
    begin
      Diag('Fatal: ' + E.ClassName + ': ' + E.Message);
      Writeln(ErrOutput, 'delphi-lsp-shim fatal: ' + E.Message);
      Halt(1);
    end;
  end;
end.
