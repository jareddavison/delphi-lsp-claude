// Copyright (c) 2026 Jared Davison. Released under the MIT License (see LICENSE).
//
// AI-generated (Claude Code). Review before trusting in production.

unit DelphiLsp.LspMessageTests;

interface

uses
  DUnitX.TestFramework;

type
  [TestFixture]
  TLspMessageTests = class
  public
    // GetMessageMethod
    [Test] procedure GetMessageMethod_ReturnsInitialize;
    [Test] procedure GetMessageMethod_ReturnsNotification;
    [Test] procedure GetMessageMethod_ReturnsEmptyOnMissingField;
    [Test] procedure GetMessageMethod_ReturnsEmptyOnInvalidJson;

    // InjectInitOptions
    [Test] procedure InjectInitOptions_AddsFieldsWhenMissing;
    [Test] procedure InjectInitOptions_PreservesExistingValues;
    [Test] procedure InjectInitOptions_PassThroughForNonInitialize;
    [Test] procedure InjectInitOptions_PassThroughOnParseFailure;

    // MakeDidChangeConfigJson
    [Test] procedure MakeDidChangeConfigJson_HasMethodAndSettings;

    // RewriteInitId
    [Test] procedure RewriteInitId_ReplacesExistingId;
    [Test] procedure RewriteInitId_HandlesNegativeIds;

    // PositionToOffset
    [Test] procedure PositionToOffset_Line0Col0_ReturnsOne;
    [Test] procedure PositionToOffset_FirstLineMidChar;
    [Test] procedure PositionToOffset_SecondLineAfterCRLF;
    [Test] procedure PositionToOffset_SecondLineAfterLF;
    [Test] procedure PositionToOffset_BeyondEnd_Clamps;

    // ApplyContentChange
    [Test] procedure ApplyContentChange_FullReplaceWhenNoRange;
    [Test] procedure ApplyContentChange_IncrementalInsert;
    [Test] procedure ApplyContentChange_IncrementalDelete;
    [Test] procedure ApplyContentChange_IncrementalReplace;

    // ExtractInitializeProcessId
    [Test] procedure ExtractInitializeProcessId_ReturnsPid;
    [Test] procedure ExtractInitializeProcessId_ReturnsZeroWhenMissing;
    [Test] procedure ExtractInitializeProcessId_ReturnsZeroForNonInitialize;
  end;

implementation

uses
  System.JSON,
  System.SysUtils,
  DelphiLsp.LspMessage;

{ GetMessageMethod }

procedure TLspMessageTests.GetMessageMethod_ReturnsInitialize;
begin
  Assert.AreEqual('initialize',
    GetMessageMethod('{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}'));
end;

procedure TLspMessageTests.GetMessageMethod_ReturnsNotification;
begin
  Assert.AreEqual('textDocument/didChange',
    GetMessageMethod('{"jsonrpc":"2.0","method":"textDocument/didChange","params":{}}'));
end;

procedure TLspMessageTests.GetMessageMethod_ReturnsEmptyOnMissingField;
begin
  Assert.AreEqual('',
    GetMessageMethod('{"jsonrpc":"2.0","id":1,"result":{}}'));
end;

procedure TLspMessageTests.GetMessageMethod_ReturnsEmptyOnInvalidJson;
begin
  Assert.AreEqual('', GetMessageMethod('not json at all'));
  Assert.AreEqual('', GetMessageMethod(''));
end;

{ InjectInitOptions }

procedure TLspMessageTests.InjectInitOptions_AddsFieldsWhenMissing;
var
  Output, ServerType: string;
  AgentCount: Integer;
  Root, ParamsVal, OptsVal: TJSONValue;
begin
  Output := InjectInitOptions(
    '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}',
    'controller', 2);
  Root := TJSONObject.ParseJSONValue(Output);
  try
    Assert.IsTrue(Root is TJSONObject, 'output must be a JSON object');
    ParamsVal := TJSONObject(Root).GetValue('params');
    Assert.IsTrue(ParamsVal is TJSONObject, 'params must exist');
    OptsVal := TJSONObject(ParamsVal).GetValue('initializationOptions');
    Assert.IsTrue(OptsVal is TJSONObject, 'initializationOptions must be added');
    ServerType := TJSONObject(OptsVal).GetValue('serverType').Value;
    AgentCount := StrToInt(TJSONObject(OptsVal).GetValue('agentCount').Value);
    Assert.AreEqual('controller', ServerType);
    Assert.IsTrue(AgentCount = 2, 'agentCount must equal 2');
  finally
    Root.Free;
  end;
end;

procedure TLspMessageTests.InjectInitOptions_PreservesExistingValues;
var
  Output: string;
  Root, ParamsVal, OptsVal: TJSONValue;
begin
  // Existing initOpts has serverType set; injection must NOT overwrite.
  Output := InjectInitOptions(
    '{"jsonrpc":"2.0","id":1,"method":"initialize",' +
    '"params":{"initializationOptions":{"serverType":"agent"}}}',
    'controller', 2);
  Root := TJSONObject.ParseJSONValue(Output);
  try
    ParamsVal := TJSONObject(Root).GetValue('params');
    OptsVal := TJSONObject(ParamsVal).GetValue('initializationOptions');
    Assert.AreEqual('agent',
      TJSONObject(OptsVal).GetValue('serverType').Value,
      'pre-existing serverType must be preserved');
  finally
    Root.Free;
  end;
end;

procedure TLspMessageTests.InjectInitOptions_PassThroughForNonInitialize;
const
  Input = '{"jsonrpc":"2.0","method":"textDocument/didChange","params":{}}';
begin
  Assert.AreEqual(Input, InjectInitOptions(Input, 'controller', 2));
end;

procedure TLspMessageTests.InjectInitOptions_PassThroughOnParseFailure;
const
  Input = 'not json';
begin
  Assert.AreEqual(Input, InjectInitOptions(Input, 'controller', 2));
end;

{ MakeDidChangeConfigJson }

procedure TLspMessageTests.MakeDidChangeConfigJson_HasMethodAndSettings;
var
  Output: string;
  Root, Params, Settings: TJSONValue;
begin
  Output := MakeDidChangeConfigJson('file:///D:/foo.json');
  Root := TJSONObject.ParseJSONValue(Output);
  try
    Assert.AreEqual('workspace/didChangeConfiguration',
      TJSONObject(Root).GetValue('method').Value);
    Params := TJSONObject(Root).GetValue('params');
    Settings := TJSONObject(Params).GetValue('settings');
    Assert.AreEqual('file:///D:/foo.json',
      TJSONObject(Settings).GetValue('settingsFile').Value);
  finally
    Root.Free;
  end;
end;

{ RewriteInitId }

procedure TLspMessageTests.RewriteInitId_ReplacesExistingId;
var
  Output: string;
  Root: TJSONValue;
begin
  Output := RewriteInitId('{"jsonrpc":"2.0","id":1,"method":"initialize"}', 42);
  Root := TJSONObject.ParseJSONValue(Output);
  try
    Assert.AreEqual('42', TJSONObject(Root).GetValue('id').Value);
  finally
    Root.Free;
  end;
end;

procedure TLspMessageTests.RewriteInitId_HandlesNegativeIds;
var
  Output: string;
  Root: TJSONValue;
begin
  // Used by RecycleChild — distinctive negative ids unlikely to collide.
  Output := RewriteInitId('{"jsonrpc":"2.0","id":1,"method":"initialize"}', -1000001);
  Root := TJSONObject.ParseJSONValue(Output);
  try
    Assert.AreEqual('-1000001', TJSONObject(Root).GetValue('id').Value);
  finally
    Root.Free;
  end;
end;

{ PositionToOffset }

procedure TLspMessageTests.PositionToOffset_Line0Col0_ReturnsOne;
begin
  Assert.IsTrue(PositionToOffset('hello', 0, 0) = 1);
end;

procedure TLspMessageTests.PositionToOffset_FirstLineMidChar;
begin
  Assert.IsTrue(PositionToOffset('hello world', 0, 6) = 7);
end;

procedure TLspMessageTests.PositionToOffset_SecondLineAfterCRLF;
begin
  // 'hello' (5) + #13#10 (2) + 'w' = offset 8 for second line, char 0
  Assert.IsTrue(PositionToOffset('hello'#13#10'world', 1, 0) = 8);
end;

procedure TLspMessageTests.PositionToOffset_SecondLineAfterLF;
begin
  Assert.IsTrue(PositionToOffset('hello'#10'world', 1, 0) = 7);
end;

procedure TLspMessageTests.PositionToOffset_BeyondEnd_Clamps;
begin
  // Way past end — should clamp to Length+1
  Assert.IsTrue(PositionToOffset('abc', 99, 99) = 4);
end;

{ ApplyContentChange }

procedure TLspMessageTests.ApplyContentChange_FullReplaceWhenNoRange;
var
  Text: string;
  Change: TJSONObject;
begin
  Text := 'old content';
  Change := TJSONObject.ParseJSONValue('{"text":"new content"}') as TJSONObject;
  try
    ApplyContentChange(Text, Change);
    Assert.AreEqual('new content', Text);
  finally
    Change.Free;
  end;
end;

procedure TLspMessageTests.ApplyContentChange_IncrementalInsert;
var
  Text: string;
  Change: TJSONObject;
begin
  // Insert 'X' at line 0, char 5 (between 'hello' and ' world')
  Text := 'hello world';
  Change := TJSONObject.ParseJSONValue(
    '{"range":{"start":{"line":0,"character":5},"end":{"line":0,"character":5}},' +
    '"text":"X"}') as TJSONObject;
  try
    ApplyContentChange(Text, Change);
    Assert.AreEqual('helloX world', Text);
  finally
    Change.Free;
  end;
end;

procedure TLspMessageTests.ApplyContentChange_IncrementalDelete;
var
  Text: string;
  Change: TJSONObject;
begin
  // Delete chars 5..6 (the space) from 'hello world' → 'helloworld'
  Text := 'hello world';
  Change := TJSONObject.ParseJSONValue(
    '{"range":{"start":{"line":0,"character":5},"end":{"line":0,"character":6}},' +
    '"text":""}') as TJSONObject;
  try
    ApplyContentChange(Text, Change);
    Assert.AreEqual('helloworld', Text);
  finally
    Change.Free;
  end;
end;

procedure TLspMessageTests.ApplyContentChange_IncrementalReplace;
var
  Text: string;
  Change: TJSONObject;
begin
  // Replace 'world' with 'Delphi'
  Text := 'hello world';
  Change := TJSONObject.ParseJSONValue(
    '{"range":{"start":{"line":0,"character":6},"end":{"line":0,"character":11}},' +
    '"text":"Delphi"}') as TJSONObject;
  try
    ApplyContentChange(Text, Change);
    Assert.AreEqual('hello Delphi', Text);
  finally
    Change.Free;
  end;
end;

{ ExtractInitializeProcessId }

procedure TLspMessageTests.ExtractInitializeProcessId_ReturnsPid;
begin
  Assert.IsTrue(ExtractInitializeProcessId(
    '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"processId":12345}}'
  ) = 12345);
end;

procedure TLspMessageTests.ExtractInitializeProcessId_ReturnsZeroWhenMissing;
begin
  Assert.IsTrue(ExtractInitializeProcessId(
    '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}'
  ) = 0);
end;

procedure TLspMessageTests.ExtractInitializeProcessId_ReturnsZeroForNonInitialize;
begin
  Assert.IsTrue(ExtractInitializeProcessId(
    '{"jsonrpc":"2.0","method":"textDocument/didChange","params":{"processId":12345}}'
  ) = 0);
end;

initialization
  TDUnitX.RegisterTestFixture(TLspMessageTests);

end.
