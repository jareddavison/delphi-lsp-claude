// Copyright (c) 2026 Jared Davison. Released under the MIT License (see LICENSE).
//
// AI-generated (Claude Code). Review before trusting in production.
//
// JSON-RPC / LSP message helpers. Pure-ish: most functions take a JSON
// string and return a JSON string. The few that fail-and-swallow log via
// DelphiLsp.Logging's Diag so the caller doesn't need to.
//
// Used by the proxy machinery in delphi-lsp-shim.dpr to inspect and
// transform messages flowing in both directions between Claude Code and
// DelphiLSP.

unit DelphiLsp.LspMessage;

interface

uses
  Winapi.Windows,
  System.JSON;

type
  // Mirror of one open document on the LSP wire. Maintained by intercepting
  // textDocument/didOpen, didChange, didClose so the shim can replay
  // didOpens to a fresh DelphiLSP child after a /delphi-reload recycle.
  TOpenDocument = record
    LanguageId: string;
    Version: Integer;
    Text: string;
  end;

// Parse `method` from a JSON-RPC message. Returns '' if the input isn't
// JSON, isn't an object, or has no `method` field.
function GetMessageMethod(const Json: string): string;

// Inject `initializationOptions: { serverType, agentCount }` into a JSON-RPC
// `initialize` request. If the field already exists, fills in only the
// missing keys. Returns the input unchanged if the message isn't an
// initialize request or fails to parse.
function InjectInitOptions(const Json: string;
  const ServerType: string; AgentCount: Integer): string;

// Build a `workspace/didChangeConfiguration` notification with
// settings.settingsFile = Uri.
function MakeDidChangeConfigJson(const Uri: string): string;

// Build a synthesized `textDocument/didOpen` for the given URI + cached
// document state. Used during /delphi-reload replay to a fresh DelphiLSP
// child.
function MakeDidOpenJson(const Uri: string; const Doc: TOpenDocument): string;

// Replace the `id` field of a cached LSP request JSON with NewId. Used to
// rewrite the cached `initialize` request before replaying it to a fresh
// DelphiLSP child — the original ID was already consumed by the LSP client
// when the original initialize handshake completed.
//
// Uses an Integer (emitted as a JSON number) rather than a string because
// DelphiLSP doesn't preserve string ids in responses — when sent a request
// with id="delphi-lsp-shim-replay-1" it responds with id=0 (apparently
// parseInt-coercing then falling back to 0 on failure), which broke the
// swallow-list match. Caller picks a distinctive negative number so it
// won't collide with the LSP client's positive-integer id stream.
function RewriteInitId(const Json: string; NewId: Integer): string;

// LSP positions are zero-indexed line + UTF-16 character offset within
// line. Walk the text counting line breaks; once at the target line,
// advance Character UTF-16 code units (Delphi `string` is UTF-16 so 1
// element per code unit). Handles \r\n, \n, and bare \r line endings.
// Returns a 1-based string offset, clamped to [1, Length(Text)+1].
function PositionToOffset(const Text: string; Line, Character: Integer): Integer;

// Apply one entry of textDocument/didChange's `contentChanges` array.
// Two shapes per LSP spec: full replace (no `range` field) or incremental
// (`range` + `text` to splice in). Mutates Text in place.
procedure ApplyContentChange(var Text: string; const Change: TJSONObject);

// Extract `params.processId` from a JSON-RPC `initialize` request. Per LSP
// spec, that's the spawning process's PID. Returns 0 if the field is
// missing, not numeric, or out of DWORD range.
function ExtractInitializeProcessId(const Json: string): DWORD;

// Parse a textDocument/didOpen notification. Returns False on parse
// failure, structural mismatch, or missing required fields (uri /
// languageId / version / text). On True, fills Uri and Doc; on False
// both stay zero-valued.
function TryParseDidOpen(const Json: string; out Uri: string;
  out Doc: TOpenDocument): Boolean;

// Extract `params.textDocument.uri` from a textDocument/* notification
// (used for didChange and didClose, where the caller wants the uri to
// look up the doc before applying any state changes). Returns False on
// parse failure, structural mismatch, or missing/empty uri.
function TryExtractTextDocumentUri(const Json: string;
  out Uri: string): Boolean;

// Parse a textDocument/didChange notification and apply its
// contentChanges to Doc in place (Text mutated, Version updated when
// the message specifies one). Returns False on parse failure or
// missing uri/structure; in that case Doc is unchanged. The caller
// should have already looked up Doc by uri.
function TryApplyDidChange(const Json: string;
  var Doc: TOpenDocument): Boolean;

// Extract the `id` field from a JSON-RPC message as a string. Returns
// '' if the message has no id, isn't valid JSON, or isn't an object.
// Numeric ids are returned as their decimal string form. Used by the
// child-reader to match against a swallow list when /delphi-reload's
// replayed-initialize response should be dropped.
function ExtractMessageId(const Json: string): string;

// Build a synthetic textDocument/didOpen for a file the shim has never
// seen a real didOpen for. Resolves Uri to a local path, validates the
// extension (.pas/.dpr/.dpk/.inc), reads the current disk content, and
// returns the assembled JSON + the populated TOpenDocument so the
// caller can seed its FOpenDocs cache.
//
// Used when Claude Code's Edit/Read tooling sends a didChange without
// having first sent a didOpen — DelphiLSP needs an in-memory baseline
// or it skips real diagnostics. Returns False (and leaves outs zeroed)
// when the URI doesn't map to a readable Pascal file.
function TryBuildSyntheticDidOpen(const Uri: string; Version: Integer;
  out Doc: TOpenDocument; out Json: string): Boolean;

implementation

uses
  System.SysUtils,
  System.Generics.Collections,
  DelphiLsp.Logging,
  DelphiLsp.JsonUtils,
  DelphiLsp.Paths,
  DelphiLsp.IO;

function GetMessageMethod(const Json: string): string;
var
  Obj: TJSONObject;
  MethodVal: TJSONValue;
begin
  Result := '';
  Obj := TryParseJsonObject(Json);
  if Obj = nil then Exit;
  try
    MethodVal := Obj.GetValue('method');
    if (MethodVal <> nil) and (MethodVal is TJSONString) then
      Result := TJSONString(MethodVal).Value;
  finally
    Obj.Free;
  end;
end;

function InjectInitOptions(const Json: string;
  const ServerType: string; AgentCount: Integer): string;
var
  Obj, ParamsObj, InitOpts: TJSONObject;
  ParamsVal, InitVal, MethodVal: TJSONValue;
  ExistingPair: TJSONPair;
begin
  Result := Json;
  Obj := TryParseJsonObject(Json);
  if Obj = nil then Exit;
  try
    MethodVal := Obj.GetValue('method');
    if (MethodVal = nil) or not (MethodVal is TJSONString) or
       (TJSONString(MethodVal).Value <> 'initialize') then Exit;

    ParamsVal := Obj.GetValue('params');
    if (ParamsVal = nil) or not (ParamsVal is TJSONObject) then Exit;
    ParamsObj := ParamsVal as TJSONObject;

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
    Obj.Free;
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

function MakeDidOpenJson(const Uri: string; const Doc: TOpenDocument): string;
var
  Root, Params, TextDoc: TJSONObject;
begin
  Root := TJSONObject.Create;
  try
    Root.AddPair('jsonrpc', '2.0');
    Root.AddPair('method', 'textDocument/didOpen');
    TextDoc := TJSONObject.Create;
    TextDoc.AddPair('uri', Uri);
    TextDoc.AddPair('languageId', Doc.LanguageId);
    TextDoc.AddPair('version', TJSONNumber.Create(Doc.Version));
    TextDoc.AddPair('text', Doc.Text);
    Params := TJSONObject.Create;
    Params.AddPair('textDocument', TextDoc);
    Root.AddPair('params', Params);
    Result := Root.ToJSON;
  finally
    Root.Free;
  end;
end;

function RewriteInitId(const Json: string; NewId: Integer): string;
var
  Obj: TJSONObject;
  ExistingPair: TJSONPair;
begin
  Result := Json;
  Obj := TryParseJsonObject(Json);
  if Obj = nil then Exit;
  try
    ExistingPair := Obj.RemovePair('id');
    if ExistingPair <> nil then ExistingPair.Free;
    Obj.AddPair('id', TJSONNumber.Create(NewId));
    Result := Obj.ToJSON;
  finally
    Obj.Free;
  end;
end;

function PositionToOffset(const Text: string; Line, Character: Integer): Integer;
var
  I, CurrentLine: Integer;
begin
  CurrentLine := 0;
  I := 1;
  while (I <= Length(Text)) and (CurrentLine < Line) do
  begin
    if Text[I] = #13 then
    begin
      Inc(CurrentLine);
      Inc(I);
      if (I <= Length(Text)) and (Text[I] = #10) then
        Inc(I);
    end
    else if Text[I] = #10 then
    begin
      Inc(CurrentLine);
      Inc(I);
    end
    else
      Inc(I);
  end;
  Result := I + Character;
  if Result > Length(Text) + 1 then Result := Length(Text) + 1;
  if Result < 1 then Result := 1;
end;

procedure ApplyContentChange(var Text: string; const Change: TJSONObject);
var
  RangeVal, StartVal, EndVal, TextVal, LineVal, CharVal: TJSONValue;
  StartLine, StartChar, EndLine, EndChar: Integer;
  StartOffset, EndOffset: Integer;
  NewText: string;
begin
  TextVal := Change.GetValue('text');
  if (TextVal = nil) or not (TextVal is TJSONString) then Exit;
  NewText := TJSONString(TextVal).Value;
  RangeVal := Change.GetValue('range');
  if (RangeVal = nil) or not (RangeVal is TJSONObject) then
  begin
    Text := NewText;
    Exit;
  end;
  StartVal := TJSONObject(RangeVal).GetValue('start');
  EndVal := TJSONObject(RangeVal).GetValue('end');
  if (not (StartVal is TJSONObject)) or (not (EndVal is TJSONObject)) then Exit;
  LineVal := TJSONObject(StartVal).GetValue('line');
  CharVal := TJSONObject(StartVal).GetValue('character');
  if (LineVal = nil) or (CharVal = nil) then Exit;
  StartLine := StrToIntDef(LineVal.Value, 0);
  StartChar := StrToIntDef(CharVal.Value, 0);
  LineVal := TJSONObject(EndVal).GetValue('line');
  CharVal := TJSONObject(EndVal).GetValue('character');
  if (LineVal = nil) or (CharVal = nil) then Exit;
  EndLine := StrToIntDef(LineVal.Value, 0);
  EndChar := StrToIntDef(CharVal.Value, 0);
  StartOffset := PositionToOffset(Text, StartLine, StartChar);
  EndOffset := PositionToOffset(Text, EndLine, EndChar);
  if EndOffset < StartOffset then EndOffset := StartOffset;
  Text := Copy(Text, 1, StartOffset - 1) + NewText + Copy(Text, EndOffset, MaxInt);
end;

function ExtractInitializeProcessId(const Json: string): DWORD;
var
  Obj, Params: TJSONObject;
  ParamsVal, MethodVal, PidVal: TJSONValue;
  PidStr: string;
  Tmp: Int64;
begin
  Result := 0;
  Obj := TryParseJsonObject(Json);
  if Obj = nil then Exit;
  try
    MethodVal := Obj.GetValue('method');
    if (MethodVal = nil) or not (MethodVal is TJSONString) or
       (TJSONString(MethodVal).Value <> 'initialize') then Exit;
    ParamsVal := Obj.GetValue('params');
    if not (ParamsVal is TJSONObject) then Exit;
    Params := TJSONObject(ParamsVal);
    PidVal := Params.GetValue('processId');
    if PidVal = nil then Exit;
    PidStr := PidVal.Value;
    if PidStr = '' then Exit;
    if TryStrToInt64(PidStr, Tmp) and (Tmp > 0) and (Tmp <= High(DWORD)) then
      Result := DWORD(Tmp);
  finally
    Obj.Free;
  end;
end;

function TryParseDidOpen(const Json: string; out Uri: string;
  out Doc: TOpenDocument): Boolean;
var
  Obj, Params, TextDoc: TJSONObject;
  ParamsVal, TextDocVal, V: TJSONValue;
begin
  Result := False;
  Uri := '';
  Doc.LanguageId := '';
  Doc.Version := 0;
  Doc.Text := '';
  Obj := TryParseJsonObject(Json);
  if Obj = nil then Exit;
  try
    ParamsVal := Obj.GetValue('params');
    if not (ParamsVal is TJSONObject) then Exit;
    Params := TJSONObject(ParamsVal);
    TextDocVal := Params.GetValue('textDocument');
    if not (TextDocVal is TJSONObject) then Exit;
    TextDoc := TJSONObject(TextDocVal);
    V := TextDoc.GetValue('uri');
    if (V = nil) or (V.Value = '') then Exit;
    Uri := V.Value;
    V := TextDoc.GetValue('languageId');
    if V = nil then Exit;
    Doc.LanguageId := V.Value;
    V := TextDoc.GetValue('version');
    if V = nil then Exit;
    Doc.Version := StrToIntDef(V.Value, 0);
    V := TextDoc.GetValue('text');
    if V = nil then Exit;
    Doc.Text := V.Value;
    Result := True;
  finally
    Obj.Free;
  end;
end;

function TryExtractTextDocumentUri(const Json: string;
  out Uri: string): Boolean;
var
  Obj, Params, TextDoc: TJSONObject;
  ParamsVal, TextDocVal, UriVal: TJSONValue;
begin
  Result := False;
  Uri := '';
  Obj := TryParseJsonObject(Json);
  if Obj = nil then Exit;
  try
    ParamsVal := Obj.GetValue('params');
    if not (ParamsVal is TJSONObject) then Exit;
    Params := TJSONObject(ParamsVal);
    TextDocVal := Params.GetValue('textDocument');
    if not (TextDocVal is TJSONObject) then Exit;
    TextDoc := TJSONObject(TextDocVal);
    UriVal := TextDoc.GetValue('uri');
    if (UriVal = nil) or (UriVal.Value = '') then Exit;
    Uri := UriVal.Value;
    Result := True;
  finally
    Obj.Free;
  end;
end;

function ExtractMessageId(const Json: string): string;
var
  Obj: TJSONObject;
  IdVal: TJSONValue;
begin
  Result := '';
  Obj := TryParseJsonObject(Json);
  if Obj = nil then Exit;
  try
    IdVal := Obj.GetValue('id');
    if IdVal = nil then Exit;
    Result := IdVal.Value;
  finally
    Obj.Free;
  end;
end;

function TryBuildSyntheticDidOpen(const Uri: string; Version: Integer;
  out Doc: TOpenDocument; out Json: string): Boolean;
var
  Path, Ext: string;
begin
  Result := False;
  Doc.LanguageId := '';
  Doc.Version := 0;
  Doc.Text := '';
  Json := '';
  Path := FileUriToPath(Uri);
  if Path = '' then Exit;
  Ext := LowerCase(ExtractFileExt(Path));
  if (Ext <> '.pas') and (Ext <> '.dpr') and
     (Ext <> '.dpk') and (Ext <> '.inc') then Exit;
  if not TryReadAllText(Path, '', Doc.Text) then Exit;
  Doc.LanguageId := 'objectpascal';
  Doc.Version := Version;
  Json := MakeDidOpenJson(Uri, Doc);
  Result := True;
end;

function TryApplyDidChange(const Json: string;
  var Doc: TOpenDocument): Boolean;
var
  Obj, Params, TextDoc, ChangeObj: TJSONObject;
  ParamsVal, TextDocVal, UriVal, VerVal: TJSONValue;
  Changes: TJSONArray;
  ChangesVal: TJSONValue;
  I: Integer;
begin
  Result := False;
  Obj := TryParseJsonObject(Json);
  if Obj = nil then Exit;
  try
    ParamsVal := Obj.GetValue('params');
    if not (ParamsVal is TJSONObject) then Exit;
    Params := TJSONObject(ParamsVal);
    TextDocVal := Params.GetValue('textDocument');
    if not (TextDocVal is TJSONObject) then Exit;
    TextDoc := TJSONObject(TextDocVal);
    UriVal := TextDoc.GetValue('uri');
    if (UriVal = nil) or (UriVal.Value = '') then Exit;

    // Validated enough to mutate Doc.
    VerVal := TextDoc.GetValue('version');
    if VerVal <> nil then
      Doc.Version := StrToIntDef(VerVal.Value, Doc.Version);
    ChangesVal := Params.GetValue('contentChanges');
    if ChangesVal is TJSONArray then
    begin
      Changes := TJSONArray(ChangesVal);
      for I := 0 to Changes.Count - 1 do
      begin
        ChangeObj := TJSONObject(Changes.Items[I]);
        if ChangeObj <> nil then
          ApplyContentChange(Doc.Text, ChangeObj);
      end;
    end;
    Result := True;
  finally
    Obj.Free;
  end;
end;

end.
