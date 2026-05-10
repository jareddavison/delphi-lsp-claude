// Copyright (c) 2026 Jared Davison. Released under the MIT License (see LICENSE).
//
// AI-generated (Claude Code). Review before trusting in production.

unit DelphiLsp.SentinelsTests;

interface

uses
  DUnitX.TestFramework;

type
  [TestFixture]
  TSentinelsTests = class
  private
    FRoot: string;
    function PathIn(const Name: string): string;
    procedure WriteText(const Name, Content: string);
  public
    [Setup] procedure Setup;
    [TearDown] procedure TearDown;

    // ReadFirstNonEmptyTrimmedLine
    [Test] procedure Read_MissingFile_ReturnsFalse;
    [Test] procedure Read_EmptyPath_ReturnsFalse;
    [Test] procedure Read_EmptyFile_ReturnsFalse;
    [Test] procedure Read_BlankLinesOnly_ReturnsFalse;
    [Test] procedure Read_SingleLine_ReturnsValue;
    [Test] procedure Read_TrimsLeadingAndTrailing;
    [Test] procedure Read_SkipsBlankLeadingLines;
    [Test] procedure Read_PicksFirstNonEmpty;
    [Test] procedure Read_WithBom_ReturnsValue;

    // ConsumeFlagFile
    [Test] procedure Consume_MissingFile_ReturnsFalse;
    [Test] procedure Consume_EmptyPath_ReturnsFalse;
    [Test] procedure Consume_ExistingFile_ReturnsTrue_AndDeletes;
    [Test] procedure Consume_DoubleConsume_SecondReturnsFalse;
  end;

implementation

uses
  System.SysUtils,
  System.IOUtils,
  DelphiLsp.Sentinels;

procedure TSentinelsTests.Setup;
begin
  FRoot := TPath.Combine(TPath.GetTempPath, 'sentinels-' +
    TGUID.NewGuid.ToString.Replace('{', '').Replace('}', ''));
  TDirectory.CreateDirectory(FRoot);
end;

procedure TSentinelsTests.TearDown;
begin
  try
    if TDirectory.Exists(FRoot) then TDirectory.Delete(FRoot, True);
  except
    // Tolerate Windows file-handle lag in CI; tests are temp-dir scoped.
  end;
end;

function TSentinelsTests.PathIn(const Name: string): string;
begin
  Result := IncludeTrailingPathDelimiter(FRoot) + Name;
end;

procedure TSentinelsTests.WriteText(const Name, Content: string);
begin
  TFile.WriteAllText(PathIn(Name), Content, TEncoding.UTF8);
end;

procedure TSentinelsTests.Read_MissingFile_ReturnsFalse;
var
  Line: string;
begin
  Assert.IsFalse(ReadFirstNonEmptyTrimmedLine(PathIn('does-not-exist.txt'), Line));
  Assert.AreEqual('', Line);
end;

procedure TSentinelsTests.Read_EmptyPath_ReturnsFalse;
var
  Line: string;
begin
  Assert.IsFalse(ReadFirstNonEmptyTrimmedLine('', Line));
  Assert.AreEqual('', Line);
end;

procedure TSentinelsTests.Read_EmptyFile_ReturnsFalse;
var
  Line: string;
begin
  WriteText('empty.txt', '');
  Assert.IsFalse(ReadFirstNonEmptyTrimmedLine(PathIn('empty.txt'), Line));
  Assert.AreEqual('', Line);
end;

procedure TSentinelsTests.Read_BlankLinesOnly_ReturnsFalse;
var
  Line: string;
begin
  WriteText('blank.txt', #13#10' '#9#13#10#9#13#10);
  Assert.IsFalse(ReadFirstNonEmptyTrimmedLine(PathIn('blank.txt'), Line));
  Assert.AreEqual('', Line);
end;

procedure TSentinelsTests.Read_SingleLine_ReturnsValue;
var
  Line: string;
begin
  WriteText('one.txt', 'D:\path\to.delphilsp.json');
  Assert.IsTrue(ReadFirstNonEmptyTrimmedLine(PathIn('one.txt'), Line));
  Assert.AreEqual('D:\path\to.delphilsp.json', Line);
end;

procedure TSentinelsTests.Read_TrimsLeadingAndTrailing;
var
  Line: string;
begin
  WriteText('trim.txt', '  '#9'D:\foo.json'#9'   '#13#10);
  Assert.IsTrue(ReadFirstNonEmptyTrimmedLine(PathIn('trim.txt'), Line));
  Assert.AreEqual('D:\foo.json', Line);
end;

procedure TSentinelsTests.Read_SkipsBlankLeadingLines;
var
  Line: string;
begin
  WriteText('skip.txt', #13#10' '#13#10'D:\actual.json'#13#10);
  Assert.IsTrue(ReadFirstNonEmptyTrimmedLine(PathIn('skip.txt'), Line));
  Assert.AreEqual('D:\actual.json', Line);
end;

procedure TSentinelsTests.Read_PicksFirstNonEmpty;
var
  Line: string;
begin
  WriteText('multi.txt', 'first'#13#10'second'#13#10'third'#13#10);
  Assert.IsTrue(ReadFirstNonEmptyTrimmedLine(PathIn('multi.txt'), Line));
  Assert.AreEqual('first', Line);
end;

procedure TSentinelsTests.Read_WithBom_ReturnsValue;
var
  Line: string;
begin
  // /delphi-project writes via PowerShell which adds a BOM. Out-File
  // and 'printf > active.txt' from MinGW also write a BOM occasionally.
  // The reader uses TStringList.LoadFromFile + TEncoding.UTF8 which
  // strips the BOM transparently.
  WriteText('bom.txt', 'D:\with-bom.json');
  Assert.IsTrue(ReadFirstNonEmptyTrimmedLine(PathIn('bom.txt'), Line));
  Assert.AreEqual('D:\with-bom.json', Line);
end;

procedure TSentinelsTests.Consume_MissingFile_ReturnsFalse;
begin
  Assert.IsFalse(ConsumeFlagFile(PathIn('not-here.flag')));
end;

procedure TSentinelsTests.Consume_EmptyPath_ReturnsFalse;
begin
  Assert.IsFalse(ConsumeFlagFile(''));
end;

procedure TSentinelsTests.Consume_ExistingFile_ReturnsTrue_AndDeletes;
var
  Flag: string;
begin
  Flag := PathIn('reload.flag');
  WriteText('reload.flag', '');
  Assert.IsTrue(FileExists(Flag), 'pre-condition: flag should exist');
  Assert.IsTrue(ConsumeFlagFile(Flag));
  Assert.IsFalse(FileExists(Flag), 'flag should have been deleted');
end;

procedure TSentinelsTests.Consume_DoubleConsume_SecondReturnsFalse;
var
  Flag: string;
begin
  Flag := PathIn('reload.flag');
  WriteText('reload.flag', '');
  Assert.IsTrue(ConsumeFlagFile(Flag), 'first consume should succeed');
  Assert.IsFalse(ConsumeFlagFile(Flag), 'second consume should fail (file gone)');
end;

initialization
  TDUnitX.RegisterTestFixture(TSentinelsTests);

end.
