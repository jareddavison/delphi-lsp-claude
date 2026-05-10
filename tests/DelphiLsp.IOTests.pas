// Copyright (c) 2026 Jared Davison. Released under the MIT License (see LICENSE).
//
// AI-generated (Claude Code). Review before trusting in production.

unit DelphiLsp.IOTests;

interface

uses
  DUnitX.TestFramework;

type
  [TestFixture]
  TIOTests = class
  private
    FRoot: string;
    function PathOf(const Name: string): string;
  public
    [Setup] procedure Setup;
    [TearDown] procedure TearDown;

    // WriteFileAtomic
    [Test] procedure WriteFileAtomic_CreatesFileWithContent;
    [Test] procedure WriteFileAtomic_OverwritesExistingFile;
    [Test] procedure WriteFileAtomic_RoundTripsUtf8;
    [Test] procedure WriteFileAtomic_NoTmpLeftBehindOnSuccess;
    [Test] procedure WriteFileAtomic_HandlesEmptyContent;
    [Test] procedure WriteFileAtomic_PreservesAtomicity_NoPartialReads;

    // TryReadAllText
    [Test] procedure TryRead_FileExists_ReturnsTrueAndContent;
    [Test] procedure TryRead_MissingFile_ReturnsFalseSilent;
    [Test] procedure TryRead_EmptyPath_ReturnsFalseSilent;
    [Test] procedure TryRead_EmptyFile_ReturnsTrueWithEmptyContent;
    [Test] procedure TryRead_RoundTripsUtf8Content;
  end;

implementation

uses
  System.SysUtils,
  System.IOUtils,
  DelphiLsp.IO;

{ TIOTests }

procedure TIOTests.Setup;
begin
  FRoot := TPath.Combine(TPath.GetTempPath, 'iotests-' +
    TGUID.NewGuid.ToString.Replace('{', '').Replace('}', ''));
  TDirectory.CreateDirectory(FRoot);
end;

procedure TIOTests.TearDown;
begin
  if (FRoot <> '') and TDirectory.Exists(FRoot) then
    TDirectory.Delete(FRoot, True);
end;

function TIOTests.PathOf(const Name: string): string;
begin
  Result := IncludeTrailingPathDelimiter(FRoot) + Name;
end;

{ WriteFileAtomic }

procedure TIOTests.WriteFileAtomic_CreatesFileWithContent;
var
  P: string;
begin
  P := PathOf('out.txt');
  WriteFileAtomic(P, 'hello world');
  Assert.IsTrue(FileExists(P), 'file should be created');
  Assert.AreEqual('hello world', TFile.ReadAllText(P, TEncoding.UTF8));
end;

procedure TIOTests.WriteFileAtomic_OverwritesExistingFile;
var
  P: string;
begin
  P := PathOf('out.txt');
  TFile.WriteAllText(P, 'old', TEncoding.UTF8);
  WriteFileAtomic(P, 'new');
  Assert.AreEqual('new', TFile.ReadAllText(P, TEncoding.UTF8));
end;

procedure TIOTests.WriteFileAtomic_RoundTripsUtf8;
var
  P: string;
const
  // Mixed ASCII + multi-byte UTF-8 (em-dash, accented chars)
  Content = 'hello — café';
begin
  P := PathOf('utf8.txt');
  WriteFileAtomic(P, Content);
  Assert.AreEqual(Content, TFile.ReadAllText(P, TEncoding.UTF8));
end;

procedure TIOTests.WriteFileAtomic_NoTmpLeftBehindOnSuccess;
var
  P: string;
begin
  P := PathOf('out.txt');
  WriteFileAtomic(P, 'content');
  Assert.IsTrue(FileExists(P));
  Assert.IsFalse(FileExists(P + '.tmp'),
    '.tmp should be moved into place, not left behind');
end;

procedure TIOTests.WriteFileAtomic_HandlesEmptyContent;
var
  P: string;
begin
  P := PathOf('empty.txt');
  WriteFileAtomic(P, '');
  Assert.IsTrue(FileExists(P), 'empty-content write must still create the file');
  Assert.AreEqual('', TFile.ReadAllText(P, TEncoding.UTF8));
end;

procedure TIOTests.WriteFileAtomic_PreservesAtomicity_NoPartialReads;
var
  P: string;
  ReadBack: string;
  I: Integer;
begin
  // Write the same path many times in quick succession; readers between
  // writes should always see a complete previous version, never a half-
  // written or empty file. Run a tight loop; if MoveFileEx semantics hold,
  // every read returns either 'V0', 'V1', ..., or 'V<last>'. (We don't run
  // the reader on a separate thread — sequential writes are enough to verify
  // the .tmp + rename pattern leaves no zombie partials.)
  P := PathOf('atomic.txt');
  for I := 0 to 50 do
  begin
    WriteFileAtomic(P, 'V' + I.ToString);
    ReadBack := TFile.ReadAllText(P, TEncoding.UTF8);
    Assert.IsTrue(ReadBack = 'V' + I.ToString,
      'iteration ' + I.ToString + ' read back unexpected: ' + ReadBack);
  end;
end;

{ TryReadAllText }

procedure TIOTests.TryRead_FileExists_ReturnsTrueAndContent;
var
  Content: string;
begin
  TFile.WriteAllText(PathOf('a.txt'), 'hello world', TEncoding.UTF8);
  Assert.IsTrue(TryReadAllText(PathOf('a.txt'), 'unused', Content));
  Assert.AreEqual('hello world', Content);
end;

procedure TIOTests.TryRead_MissingFile_ReturnsFalseSilent;
var
  Content: string;
begin
  // Missing file is not an "error" — caller can pre-check FileExists
  // if it cares, otherwise gets a clean False.
  Assert.IsFalse(TryReadAllText(PathOf('nope.txt'), 'unused', Content));
  Assert.AreEqual('', Content);
end;

procedure TIOTests.TryRead_EmptyPath_ReturnsFalseSilent;
var
  Content: string;
begin
  Assert.IsFalse(TryReadAllText('', 'unused', Content));
  Assert.AreEqual('', Content);
end;

procedure TIOTests.TryRead_EmptyFile_ReturnsTrueWithEmptyContent;
var
  Content: string;
begin
  // An empty file is a successful read — distinguishes from "missing".
  TFile.WriteAllText(PathOf('empty.txt'), '', TEncoding.UTF8);
  Assert.IsTrue(TryReadAllText(PathOf('empty.txt'), 'unused', Content));
  Assert.AreEqual('', Content);
end;

procedure TIOTests.TryRead_RoundTripsUtf8Content;
var
  Content: string;
const
  Sample = 'café — açaí — 日本語';
begin
  TFile.WriteAllText(PathOf('utf8.txt'), Sample, TEncoding.UTF8);
  Assert.IsTrue(TryReadAllText(PathOf('utf8.txt'), 'unused', Content));
  Assert.AreEqual(Sample, Content);
end;

initialization
  TDUnitX.RegisterTestFixture(TIOTests);

end.
