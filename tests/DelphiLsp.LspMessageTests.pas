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

    // TryParseDidOpen
    [Test] procedure TryParseDidOpen_ValidMessage_ExtractsAllFields;
    [Test] procedure TryParseDidOpen_MissingUri_ReturnsFalse;
    [Test] procedure TryParseDidOpen_MissingLanguageId_ReturnsFalse;
    [Test] procedure TryParseDidOpen_MissingVersion_ReturnsFalse;
    [Test] procedure TryParseDidOpen_MissingText_ReturnsFalse;
    [Test] procedure TryParseDidOpen_NoParams_ReturnsFalse;
    [Test] procedure TryParseDidOpen_InvalidJson_ReturnsFalse;
    [Test] procedure TryParseDidOpen_EmptyText_StillSucceeds;

    // TryExtractTextDocumentUri
    [Test] procedure TryExtractUri_DidChangeShape_Extracts;
    [Test] procedure TryExtractUri_DidCloseShape_Extracts;
    [Test] procedure TryExtractUri_MissingUri_ReturnsFalse;
    [Test] procedure TryExtractUri_NoTextDocument_ReturnsFalse;
    [Test] procedure TryExtractUri_InvalidJson_ReturnsFalse;

    // TryApplyDidChange
    [Test] procedure TryApplyDidChange_FullReplace_ReplacesText;
    [Test] procedure TryApplyDidChange_IncrementalRange_AppliesEdit;
    [Test] procedure TryApplyDidChange_MultipleChanges_AppliedInOrder;
    [Test] procedure TryApplyDidChange_BumpsVersion;
    [Test] procedure TryApplyDidChange_NoVersionField_PreservesVersion;
    [Test] procedure TryApplyDidChange_NoUri_LeavesDocUntouched;
    [Test] procedure TryApplyDidChange_EmptyChangesArray_Succeeds;
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

{ TryParseDidOpen }

const
  // Compact didOpen sample. \" / \n inside JSON 'text' field, and a
  // realistic Pascal source body so the Length(Text) assertion is
  // meaningful rather than counting an empty string.
  DID_OPEN_VALID =
    '{"jsonrpc":"2.0","method":"textDocument/didOpen","params":' +
    '{"textDocument":{"uri":"file:///D:/Foo.pas","languageId":"objectpascal",' +
    '"version":1,"text":"unit Foo;\ninterface\nend."}}}';

procedure TLspMessageTests.TryParseDidOpen_ValidMessage_ExtractsAllFields;
var
  Uri: string;
  Doc: TOpenDocument;
begin
  Assert.IsTrue(TryParseDidOpen(DID_OPEN_VALID, Uri, Doc));
  Assert.AreEqual('file:///D:/Foo.pas', Uri);
  Assert.AreEqual('objectpascal', Doc.LanguageId);
  Assert.IsTrue(Doc.Version = 1, 'expected version=1');
  Assert.AreEqual('unit Foo;'#10'interface'#10'end.', Doc.Text);
end;

procedure TLspMessageTests.TryParseDidOpen_MissingUri_ReturnsFalse;
var
  Uri: string;
  Doc: TOpenDocument;
begin
  Assert.IsFalse(TryParseDidOpen(
    '{"params":{"textDocument":{"languageId":"objectpascal","version":1,"text":"x"}}}',
    Uri, Doc));
  Assert.AreEqual('', Uri);
end;

procedure TLspMessageTests.TryParseDidOpen_MissingLanguageId_ReturnsFalse;
var
  Uri: string;
  Doc: TOpenDocument;
begin
  Assert.IsFalse(TryParseDidOpen(
    '{"params":{"textDocument":{"uri":"u","version":1,"text":"x"}}}',
    Uri, Doc));
end;

procedure TLspMessageTests.TryParseDidOpen_MissingVersion_ReturnsFalse;
var
  Uri: string;
  Doc: TOpenDocument;
begin
  Assert.IsFalse(TryParseDidOpen(
    '{"params":{"textDocument":{"uri":"u","languageId":"objectpascal","text":"x"}}}',
    Uri, Doc));
end;

procedure TLspMessageTests.TryParseDidOpen_MissingText_ReturnsFalse;
var
  Uri: string;
  Doc: TOpenDocument;
begin
  Assert.IsFalse(TryParseDidOpen(
    '{"params":{"textDocument":{"uri":"u","languageId":"objectpascal","version":1}}}',
    Uri, Doc));
end;

procedure TLspMessageTests.TryParseDidOpen_NoParams_ReturnsFalse;
var
  Uri: string;
  Doc: TOpenDocument;
begin
  Assert.IsFalse(TryParseDidOpen('{"jsonrpc":"2.0","method":"x"}', Uri, Doc));
end;

procedure TLspMessageTests.TryParseDidOpen_InvalidJson_ReturnsFalse;
var
  Uri: string;
  Doc: TOpenDocument;
begin
  Assert.IsFalse(TryParseDidOpen('{ broken', Uri, Doc));
end;

procedure TLspMessageTests.TryParseDidOpen_EmptyText_StillSucceeds;
var
  Uri: string;
  Doc: TOpenDocument;
begin
  // Empty file is a legitimate didOpen — empty .pas stub being created.
  Assert.IsTrue(TryParseDidOpen(
    '{"params":{"textDocument":{"uri":"file:///x.pas","languageId":"objectpascal","version":0,"text":""}}}',
    Uri, Doc));
  Assert.AreEqual('', Doc.Text);
end;

{ TryExtractTextDocumentUri }

procedure TLspMessageTests.TryExtractUri_DidChangeShape_Extracts;
var
  Uri: string;
begin
  Assert.IsTrue(TryExtractTextDocumentUri(
    '{"method":"textDocument/didChange","params":' +
    '{"textDocument":{"uri":"file:///A.pas","version":2},"contentChanges":[]}}',
    Uri));
  Assert.AreEqual('file:///A.pas', Uri);
end;

procedure TLspMessageTests.TryExtractUri_DidCloseShape_Extracts;
var
  Uri: string;
begin
  Assert.IsTrue(TryExtractTextDocumentUri(
    '{"method":"textDocument/didClose","params":' +
    '{"textDocument":{"uri":"file:///B.pas"}}}',
    Uri));
  Assert.AreEqual('file:///B.pas', Uri);
end;

procedure TLspMessageTests.TryExtractUri_MissingUri_ReturnsFalse;
var
  Uri: string;
begin
  Assert.IsFalse(TryExtractTextDocumentUri(
    '{"params":{"textDocument":{}}}', Uri));
  Assert.AreEqual('', Uri);
end;

procedure TLspMessageTests.TryExtractUri_NoTextDocument_ReturnsFalse;
var
  Uri: string;
begin
  Assert.IsFalse(TryExtractTextDocumentUri(
    '{"params":{}}', Uri));
end;

procedure TLspMessageTests.TryExtractUri_InvalidJson_ReturnsFalse;
var
  Uri: string;
begin
  Assert.IsFalse(TryExtractTextDocumentUri('not json', Uri));
end;

{ TryApplyDidChange }

procedure TLspMessageTests.TryApplyDidChange_FullReplace_ReplacesText;
var
  Doc: TOpenDocument;
begin
  Doc.LanguageId := 'objectpascal';
  Doc.Version := 1;
  Doc.Text := 'old contents';
  Assert.IsTrue(TryApplyDidChange(
    '{"method":"textDocument/didChange","params":' +
    '{"textDocument":{"uri":"file:///x.pas","version":2},' +
    '"contentChanges":[{"text":"new contents"}]}}',
    Doc));
  Assert.AreEqual('new contents', Doc.Text);
  Assert.IsTrue(Doc.Version = 2, 'version should bump to 2');
end;

procedure TLspMessageTests.TryApplyDidChange_IncrementalRange_AppliesEdit;
var
  Doc: TOpenDocument;
begin
  Doc.Text := 'hello world';
  Doc.Version := 1;
  // Replace 'world' (chars 6..11) with 'Delphi'.
  Assert.IsTrue(TryApplyDidChange(
    '{"params":{"textDocument":{"uri":"file:///x.pas","version":2},' +
    '"contentChanges":[{"range":{"start":{"line":0,"character":6},' +
    '"end":{"line":0,"character":11}},"text":"Delphi"}]}}',
    Doc));
  Assert.AreEqual('hello Delphi', Doc.Text);
end;

procedure TLspMessageTests.TryApplyDidChange_MultipleChanges_AppliedInOrder;
var
  Doc: TOpenDocument;
begin
  // Two ops: first replaces 'foo' with 'bar' (full replace), then
  // appends ' baz' via incremental insert at end. Order matters.
  Doc.Text := 'foo';
  Doc.Version := 1;
  Assert.IsTrue(TryApplyDidChange(
    '{"params":{"textDocument":{"uri":"file:///x.pas","version":2},' +
    '"contentChanges":[' +
    '{"text":"bar"},' +
    '{"range":{"start":{"line":0,"character":3},' +
    '"end":{"line":0,"character":3}},"text":" baz"}' +
    ']}}',
    Doc));
  Assert.AreEqual('bar baz', Doc.Text);
end;

procedure TLspMessageTests.TryApplyDidChange_BumpsVersion;
var
  Doc: TOpenDocument;
begin
  Doc.Version := 5;
  Doc.Text := '';
  Assert.IsTrue(TryApplyDidChange(
    '{"params":{"textDocument":{"uri":"file:///x.pas","version":42},' +
    '"contentChanges":[]}}',
    Doc));
  Assert.IsTrue(Doc.Version = 42, 'version should follow the message');
end;

procedure TLspMessageTests.TryApplyDidChange_NoVersionField_PreservesVersion;
var
  Doc: TOpenDocument;
begin
  Doc.Version := 7;
  Doc.Text := 'before';
  Assert.IsTrue(TryApplyDidChange(
    '{"params":{"textDocument":{"uri":"file:///x.pas"},' +
    '"contentChanges":[{"text":"after"}]}}',
    Doc));
  Assert.IsTrue(Doc.Version = 7, 'no version field -> version unchanged');
  Assert.AreEqual('after', Doc.Text);
end;

procedure TLspMessageTests.TryApplyDidChange_NoUri_LeavesDocUntouched;
var
  Doc: TOpenDocument;
begin
  Doc.Version := 1;
  Doc.Text := 'untouched';
  Assert.IsFalse(TryApplyDidChange(
    '{"params":{"textDocument":{"version":2},' +
    '"contentChanges":[{"text":"would-replace"}]}}',
    Doc));
  Assert.AreEqual('untouched', Doc.Text);
  Assert.IsTrue(Doc.Version = 1);
end;

procedure TLspMessageTests.TryApplyDidChange_EmptyChangesArray_Succeeds;
var
  Doc: TOpenDocument;
begin
  // didChange with no actual edits is rare but valid (e.g. version-only
  // bump). Should succeed and leave Text untouched.
  Doc.Version := 1;
  Doc.Text := 'unchanged';
  Assert.IsTrue(TryApplyDidChange(
    '{"params":{"textDocument":{"uri":"file:///x.pas","version":2},' +
    '"contentChanges":[]}}',
    Doc));
  Assert.AreEqual('unchanged', Doc.Text);
  Assert.IsTrue(Doc.Version = 2);
end;

initialization
  TDUnitX.RegisterTestFixture(TLspMessageTests);

end.
