// Copyright (c) 2026 Jared Davison. Released under the MIT License (see LICENSE).
//
// AI-generated (Claude Code). Review before trusting in production.

unit DelphiLsp.WalkersTests;

interface

uses
  DUnitX.TestFramework;

type
  [TestFixture]
  TWalkersTests = class
  private
    FRoot: string;
    procedure WriteFile(const RelPath: string);
  public
    [Setup]
    procedure Setup;
    [TearDown]
    procedure TearDown;

    [Test] procedure FindsTopLevelMatch;
    [Test] procedure FindsNestedMatchAtDepth3;
    [Test] procedure IgnoresNonMatchingExtension;
    [Test] procedure SkipsHiddenDirs;
    [Test] procedure SkipsBuildOutputDirs;
    [Test] procedure SkipsHistoryDirs;
    [Test] procedure RespectsMaxDepth;
    [Test] procedure CaseInsensitiveExtensionMatch;
  end;

implementation

uses
  System.SysUtils,
  System.IOUtils,
  System.Generics.Collections,
  DelphiLsp.Walkers;

{ TWalkersTests }

procedure TWalkersTests.WriteFile(const RelPath: string);
var
  FullPath, Dir: string;
begin
  FullPath := IncludeTrailingPathDelimiter(FRoot) + RelPath;
  Dir := ExtractFilePath(FullPath);
  if (Dir <> '') and not TDirectory.Exists(Dir) then
    TDirectory.CreateDirectory(Dir);
  TFile.WriteAllText(FullPath, '');
end;

procedure TWalkersTests.Setup;
begin
  FRoot := TPath.Combine(TPath.GetTempPath, 'walkers-test-' +
    TGUID.NewGuid.ToString.Replace('{', '').Replace('}', ''));
  TDirectory.CreateDirectory(FRoot);

  // Synthetic workspace: 2 .delphilsp.json files, 1 .dproj, 1 .pas, plus
  // various dirs the walker should skip.
  WriteFile('A.delphilsp.json');
  WriteFile('A.dproj');
  WriteFile('A.pas');
  WriteFile('sub1\B.delphilsp.json');
  WriteFile('sub1\sub2\sub3\Deep.delphilsp.json');

  // Files inside skipped dirs — must NOT be returned.
  WriteFile('node_modules\inner\Bad.delphilsp.json');
  WriteFile('__history\Bad.delphilsp.json');
  WriteFile('Win32\Debug\Bad.delphilsp.json');
  WriteFile('Win64\Release\Bad.delphilsp.json');
  WriteFile('.git\objects\Bad.delphilsp.json');
  WriteFile('.hidden\Bad.delphilsp.json');

  // Beyond default depth (we'll test with explicit MaxDepth).
  WriteFile('a\b\c\d\e\f\g\TooDeep.delphilsp.json');
end;

procedure TWalkersTests.TearDown;
begin
  if (FRoot <> '') and TDirectory.Exists(FRoot) then
    TDirectory.Delete(FRoot, True);
end;

procedure TWalkersTests.FindsTopLevelMatch;
var
  Acc: TList<string>;
begin
  Acc := TList<string>.Create;
  try
    CollectFilesByExt(FRoot, '.delphilsp.json', 0, Acc);
    Assert.IsTrue(Acc.Count >= 1, 'expected at least 1 match');
    var Found := False;
    for var P in Acc do
      if P.EndsWith('A.delphilsp.json') then Found := True;
    Assert.IsTrue(Found, 'top-level A.delphilsp.json must be returned');
  finally
    Acc.Free;
  end;
end;

procedure TWalkersTests.FindsNestedMatchAtDepth3;
var
  Acc: TList<string>;
  Found: Boolean;
  P: string;
begin
  Acc := TList<string>.Create;
  try
    CollectFilesByExt(FRoot, '.delphilsp.json', 0, Acc);
    Found := False;
    for P in Acc do
      if P.EndsWith('Deep.delphilsp.json') then Found := True;
    Assert.IsTrue(Found, 'sub1\sub2\sub3\Deep.delphilsp.json must be returned');
  finally
    Acc.Free;
  end;
end;

procedure TWalkersTests.IgnoresNonMatchingExtension;
var
  Acc: TList<string>;
  P: string;
begin
  Acc := TList<string>.Create;
  try
    CollectFilesByExt(FRoot, '.dproj', 0, Acc);
    Assert.IsTrue(Acc.Count = 1,
      Format('expected 1 .dproj match, got %d', [Acc.Count]));
    for P in Acc do
      Assert.IsTrue(P.EndsWith('.dproj'), 'unexpected non-.dproj match: ' + P);
  finally
    Acc.Free;
  end;
end;

procedure TWalkersTests.SkipsHiddenDirs;
var
  Acc: TList<string>;
  P: string;
begin
  Acc := TList<string>.Create;
  try
    CollectFilesByExt(FRoot, '.delphilsp.json', 0, Acc);
    for P in Acc do
    begin
      Assert.IsFalse(P.Contains('\.hidden\'),
        '.hidden\ should be skipped: ' + P);
      Assert.IsFalse(P.Contains('\.git\'),
        '.git\ should be skipped: ' + P);
    end;
  finally
    Acc.Free;
  end;
end;

procedure TWalkersTests.SkipsBuildOutputDirs;
var
  Acc: TList<string>;
  P: string;
begin
  Acc := TList<string>.Create;
  try
    CollectFilesByExt(FRoot, '.delphilsp.json', 0, Acc);
    for P in Acc do
    begin
      Assert.IsFalse(P.ToLower.Contains('\win32\'),
        'Win32\ should be skipped: ' + P);
      Assert.IsFalse(P.ToLower.Contains('\win64\'),
        'Win64\ should be skipped: ' + P);
      Assert.IsFalse(P.Contains('\node_modules\'),
        'node_modules\ should be skipped: ' + P);
    end;
  finally
    Acc.Free;
  end;
end;

procedure TWalkersTests.SkipsHistoryDirs;
var
  Acc: TList<string>;
  P: string;
begin
  Acc := TList<string>.Create;
  try
    CollectFilesByExt(FRoot, '.delphilsp.json', 0, Acc);
    for P in Acc do
      Assert.IsFalse(P.Contains('\__history\'),
        '__history\ should be skipped: ' + P);
  finally
    Acc.Free;
  end;
end;

procedure TWalkersTests.RespectsMaxDepth;
var
  Acc: TList<string>;
  P: string;
  FoundDeep: Boolean;
begin
  Acc := TList<string>.Create;
  try
    // Default MaxDepth=6. The TooDeep file is at depth 7, must NOT be found.
    CollectFilesByExt(FRoot, '.delphilsp.json', 0, Acc);
    FoundDeep := False;
    for P in Acc do
      if P.EndsWith('TooDeep.delphilsp.json') then FoundDeep := True;
    Assert.IsFalse(FoundDeep, 'depth-7 file must not be returned at MaxDepth=6');

    // With MaxDepth=10 it should now be found.
    Acc.Clear;
    CollectFilesByExt(FRoot, '.delphilsp.json', 0, Acc, 10);
    FoundDeep := False;
    for P in Acc do
      if P.EndsWith('TooDeep.delphilsp.json') then FoundDeep := True;
    Assert.IsTrue(FoundDeep, 'depth-7 file should be returned at MaxDepth=10');
  finally
    Acc.Free;
  end;
end;

procedure TWalkersTests.CaseInsensitiveExtensionMatch;
var
  Acc: TList<string>;
  Mixed: string;
begin
  // Add a file with mixed-case extension; CollectFilesByExt lowercases the
  // candidate name before comparing, so MIXED.DELPHILSP.JSON should match
  // ExtensionLower='.delphilsp.json'.
  Mixed := IncludeTrailingPathDelimiter(FRoot) + 'MIXED.DELPHILSP.JSON';
  TFile.WriteAllText(Mixed, '');
  try
    Acc := TList<string>.Create;
    try
      CollectFilesByExt(FRoot, '.delphilsp.json', 0, Acc);
      var Found := False;
      for var P in Acc do
        if P.ToUpper.EndsWith('MIXED.DELPHILSP.JSON') then Found := True;
      Assert.IsTrue(Found, 'case-insensitive match should find MIXED.DELPHILSP.JSON');
    finally
      Acc.Free;
    end;
  finally
    TFile.Delete(Mixed);
  end;
end;

initialization
  TDUnitX.RegisterTestFixture(TWalkersTests);

end.
