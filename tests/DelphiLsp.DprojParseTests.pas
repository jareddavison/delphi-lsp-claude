// Copyright (c) 2026 Jared Davison. Released under the MIT License (see LICENSE).
//
// AI-generated (Claude Code). Review before trusting in production.

unit DelphiLsp.DprojParseTests;

interface

uses
  DUnitX.TestFramework;

type
  [TestFixture]
  TDprojParseTests = class
  private
    FRoot: string;
    procedure WriteFile(const RelPath, Content: string);
  public
    [Setup] procedure Setup;
    [TearDown] procedure TearDown;

    // ExtractDccFlagValue
    [Test] procedure ExtractDccFlagValue_UnquotedAtStart;
    [Test] procedure ExtractDccFlagValue_UnquotedAfterSpace;
    [Test] procedure ExtractDccFlagValue_QuotedWithSpaces;
    [Test] procedure ExtractDccFlagValue_NotPresent_ReturnsEmpty;
    [Test] procedure ExtractDccFlagValue_DoesNotMatchMidToken;

    // ResolveDcuOutputDir
    [Test] procedure ResolveDcuOutputDir_AbsoluteFromRelativeNU;
    [Test] procedure ResolveDcuOutputDir_NoFile_ReturnsEmpty;
    [Test] procedure ResolveDcuOutputDir_NoDccOptions_ReturnsEmpty;
    [Test] procedure ResolveDcuOutputDir_NoNUFlag_ReturnsEmpty;

    // CountRecentDcus
    [Test] procedure CountRecentDcus_CountsRecentOnly;
    [Test] procedure CountRecentDcus_NoDir_ReturnsZero;
    [Test] procedure CountRecentDcus_AllStale_ReturnsZero;

    // FindOwningDelphilspJsons
    [Test] procedure FindOwning_ReturnsSingleOwner;
    [Test] procedure FindOwning_ReturnsEmptyForUnreferencedFile;
    [Test] procedure FindOwning_DecodesXmlEntitiesInPath;
    [Test] procedure FindOwning_SkipsWhenSiblingDelphilspMissing;
  end;

implementation

uses
  System.SysUtils,
  System.IOUtils,
  System.DateUtils,
  DelphiLsp.DprojParse;

{ TDprojParseTests }

procedure TDprojParseTests.WriteFile(const RelPath, Content: string);
var
  FullPath, Dir: string;
begin
  FullPath := IncludeTrailingPathDelimiter(FRoot) + RelPath;
  Dir := ExtractFilePath(FullPath);
  if (Dir <> '') and not TDirectory.Exists(Dir) then
    TDirectory.CreateDirectory(Dir);
  TFile.WriteAllText(FullPath, Content, TEncoding.UTF8);
end;

procedure TDprojParseTests.Setup;
begin
  FRoot := TPath.Combine(TPath.GetTempPath, 'dprojparse-' +
    TGUID.NewGuid.ToString.Replace('{', '').Replace('}', ''));
  TDirectory.CreateDirectory(FRoot);
end;

procedure TDprojParseTests.TearDown;
begin
  if (FRoot <> '') and TDirectory.Exists(FRoot) then
    TDirectory.Delete(FRoot, True);
end;

{ ExtractDccFlagValue }

procedure TDprojParseTests.ExtractDccFlagValue_UnquotedAtStart;
begin
  Assert.AreEqual('.\Win32\Debug',
    ExtractDccFlagValue('-NU.\Win32\Debug -E.\Win32\Debug', '-NU'));
end;

procedure TDprojParseTests.ExtractDccFlagValue_UnquotedAfterSpace;
begin
  Assert.AreEqual('.\Win32\Debug',
    ExtractDccFlagValue('-LE.\foo -NU.\Win32\Debug -E.\bar', '-NU'));
end;

procedure TDprojParseTests.ExtractDccFlagValue_QuotedWithSpaces;
begin
  Assert.AreEqual('C:\Program Files\stuff',
    ExtractDccFlagValue('-LE.\foo -NU"C:\Program Files\stuff" -E.\bar', '-NU'));
end;

procedure TDprojParseTests.ExtractDccFlagValue_NotPresent_ReturnsEmpty;
begin
  Assert.AreEqual('',
    ExtractDccFlagValue('-LE.\foo -E.\bar', '-NU'));
end;

procedure TDprojParseTests.ExtractDccFlagValue_DoesNotMatchMidToken;
begin
  // -FOOBAR-NU/path: the -NU shouldn't match because it's mid-token (not
  // preceded by whitespace).
  Assert.AreEqual('',
    ExtractDccFlagValue('-FOOBAR-NU/path', '-NU'));
end;

{ ResolveDcuOutputDir }

procedure TDprojParseTests.ResolveDcuOutputDir_AbsoluteFromRelativeNU;
var
  LspPath, Resolved, Expected: string;
begin
  LspPath := IncludeTrailingPathDelimiter(FRoot) + 'TestProj.delphilsp.json';
  WriteFile('TestProj.delphilsp.json',
    '{"settings":{"dccOptions":"-DDEBUG -NU.\\Win32\\Debug -E.\\Win32\\Debug"}}');
  Resolved := ResolveDcuOutputDir(LspPath);
  Expected := TPath.GetFullPath(TPath.Combine(FRoot, '.\Win32\Debug'));
  Assert.AreEqual(Expected, Resolved);
end;

procedure TDprojParseTests.ResolveDcuOutputDir_NoFile_ReturnsEmpty;
begin
  Assert.AreEqual('',
    ResolveDcuOutputDir(FRoot + '\nonexistent.delphilsp.json'));
end;

procedure TDprojParseTests.ResolveDcuOutputDir_NoDccOptions_ReturnsEmpty;
var
  LspPath: string;
begin
  LspPath := IncludeTrailingPathDelimiter(FRoot) + 'NoOpts.delphilsp.json';
  WriteFile('NoOpts.delphilsp.json', '{"settings":{}}');
  Assert.AreEqual('', ResolveDcuOutputDir(LspPath));
end;

procedure TDprojParseTests.ResolveDcuOutputDir_NoNUFlag_ReturnsEmpty;
var
  LspPath: string;
begin
  LspPath := IncludeTrailingPathDelimiter(FRoot) + 'NoNU.delphilsp.json';
  WriteFile('NoNU.delphilsp.json',
    '{"settings":{"dccOptions":"-DDEBUG -E.\\Win32\\Debug"}}');
  Assert.AreEqual('', ResolveDcuOutputDir(LspPath));
end;

{ CountRecentDcus }

procedure TDprojParseTests.CountRecentDcus_CountsRecentOnly;
var
  DcuDir: string;
  Cutoff: TDateTime;
  StaleFile: string;
  StaleTime: TDateTime;
begin
  DcuDir := IncludeTrailingPathDelimiter(FRoot) + 'Win32\Debug';
  TDirectory.CreateDirectory(DcuDir);

  // 3 fresh DCUs (mtime = now)
  TFile.WriteAllText(IncludeTrailingPathDelimiter(DcuDir) + 'Unit1.dcu', 'fake');
  TFile.WriteAllText(IncludeTrailingPathDelimiter(DcuDir) + 'Unit2.dcu', 'fake');
  TFile.WriteAllText(IncludeTrailingPathDelimiter(DcuDir) + 'Unit3.dcu', 'fake');

  // 1 stale DCU (mtime = 90 days ago)
  StaleFile := IncludeTrailingPathDelimiter(DcuDir) + 'Stale.dcu';
  TFile.WriteAllText(StaleFile, 'fake');
  StaleTime := IncDay(Now, -90);
  TFile.SetLastWriteTime(StaleFile, StaleTime);

  // Cutoff = 30 days ago. Should count the 3 fresh, exclude the 1 stale.
  Cutoff := IncDay(Now, -30);
  Assert.IsTrue(CountRecentDcus(DcuDir, Cutoff) = 3,
    'should count 3 fresh DCUs and exclude the stale one');
end;

procedure TDprojParseTests.CountRecentDcus_NoDir_ReturnsZero;
begin
  Assert.IsTrue(CountRecentDcus(FRoot + '\nonexistent', IncDay(Now, -30)) = 0);
  Assert.IsTrue(CountRecentDcus('', IncDay(Now, -30)) = 0);
end;

procedure TDprojParseTests.CountRecentDcus_AllStale_ReturnsZero;
var
  DcuDir, StaleFile: string;
begin
  DcuDir := IncludeTrailingPathDelimiter(FRoot) + 'Win32\Debug';
  TDirectory.CreateDirectory(DcuDir);
  StaleFile := IncludeTrailingPathDelimiter(DcuDir) + 'Old.dcu';
  TFile.WriteAllText(StaleFile, 'fake');
  TFile.SetLastWriteTime(StaleFile, IncDay(Now, -100));
  Assert.IsTrue(CountRecentDcus(DcuDir, IncDay(Now, -30)) = 0);
end;

{ FindOwningDelphilspJsons }

procedure TDprojParseTests.FindOwning_ReturnsSingleOwner;
var
  Owners: TArray<string>;
  PasPath: string;
begin
  WriteFile('Foo.dproj',
    '<Project>' +
    '<ItemGroup>' +
    '<DCCReference Include="Unit1.pas"/>' +
    '</ItemGroup>' +
    '</Project>');
  WriteFile('Foo.delphilsp.json', '{}');
  WriteFile('Unit1.pas', '');
  PasPath := IncludeTrailingPathDelimiter(FRoot) + 'Unit1.pas';

  Owners := FindOwningDelphilspJsons(FRoot, PasPath);
  Assert.IsTrue(Length(Owners) = 1, 'expected exactly 1 owner');
  Assert.IsTrue(Owners[0].EndsWith('Foo.delphilsp.json'),
    'owner should be Foo.delphilsp.json');
end;

procedure TDprojParseTests.FindOwning_ReturnsEmptyForUnreferencedFile;
var
  Owners: TArray<string>;
  PasPath: string;
begin
  WriteFile('Foo.dproj',
    '<Project><ItemGroup><DCCReference Include="Unit1.pas"/></ItemGroup></Project>');
  WriteFile('Foo.delphilsp.json', '{}');
  PasPath := IncludeTrailingPathDelimiter(FRoot) + 'Unreferenced.pas';

  Owners := FindOwningDelphilspJsons(FRoot, PasPath);
  Assert.IsTrue(Length(Owners) = 0, 'expected 0 owners for unreferenced file');
end;

procedure TDprojParseTests.FindOwning_DecodesXmlEntitiesInPath;
var
  Owners: TArray<string>;
  PasPath: string;
begin
  // .dproj uses XML entity for & in path; on-disk file has literal &.
  // FindOwning must decode the entity before comparing.
  WriteFile('Bar.dproj',
    '<Project><ItemGroup>' +
    '<DCCReference Include="Foo &amp; Bar\Unit.pas"/>' +
    '</ItemGroup></Project>');
  WriteFile('Bar.delphilsp.json', '{}');
  WriteFile('Foo & Bar\Unit.pas', '');
  PasPath := IncludeTrailingPathDelimiter(FRoot) + 'Foo & Bar\Unit.pas';

  Owners := FindOwningDelphilspJsons(FRoot, PasPath);
  Assert.IsTrue(Length(Owners) = 1,
    'XML entity in path must decode to match the on-disk file');
end;

procedure TDprojParseTests.FindOwning_SkipsWhenSiblingDelphilspMissing;
var
  Owners: TArray<string>;
  PasPath: string;
begin
  // .dproj exists and references the file, but no sibling .delphilsp.json.
  // Owner should NOT be added — without .delphilsp.json the LSP can't load
  // the project anyway.
  WriteFile('Orphan.dproj',
    '<Project><ItemGroup><DCCReference Include="Unit1.pas"/></ItemGroup></Project>');
  // No Orphan.delphilsp.json
  PasPath := IncludeTrailingPathDelimiter(FRoot) + 'Unit1.pas';

  Owners := FindOwningDelphilspJsons(FRoot, PasPath);
  Assert.IsTrue(Length(Owners) = 0,
    'must not return a .dproj that lacks a sibling .delphilsp.json');
end;

initialization
  TDUnitX.RegisterTestFixture(TDprojParseTests);

end.
