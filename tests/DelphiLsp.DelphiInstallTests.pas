// Copyright (c) 2026 Jared Davison. Released under the MIT License (see LICENSE).
//
// AI-generated (Claude Code). Review before trusting in production.

unit DelphiLsp.DelphiInstallTests;

interface

uses
  DUnitX.TestFramework;

type
  [TestFixture]
  TDelphiInstallTests = class
  private
    FRoot: string;
    procedure WriteFile(const RelPath, Content: string);
  public
    [Setup] procedure Setup;
    [TearDown] procedure TearDown;

    // CompareBdsVersions — pure function; comprehensive coverage
    [Test] procedure Compare_EqualVersions;
    [Test] procedure Compare_HigherMajorWins;
    [Test] procedure Compare_HigherMinorWinsWhenMajorEqual;
    [Test] procedure Compare_NonNumericPartsTreatAsZero;
    [Test] procedure Compare_MissingMinorTreatsAsZero;
    [Test] procedure Compare_EmptyStringsAreEqual;

    // ExtractBdsVersionFromSettings
    [Test] procedure Extract_FindsStudioPath;
    [Test] procedure Extract_FindsBdsPath;
    [Test] procedure Extract_FindsBackslashForm;
    [Test] procedure Extract_ReturnsEmptyForNoMatch;
    [Test] procedure Extract_ReturnsEmptyForMissingFile;
    [Test] procedure Extract_PicksFirstMatch;
    [Test] procedure Extract_CaseInsensitiveStudio;

    // FindDelphiLspExeUnder — file existence based
    [Test] procedure FindExe_ReturnsEmptyForBlankRoot;
    [Test] procedure FindExe_ReturnsEmptyWhenNeitherExists;
    [Test] procedure FindExe_PrefersBin32WhenBothExist;
    [Test] procedure FindExe_FallsBackToBinWhenOnly32BitExists;
    [Test] procedure FindExe_FallsBackToBin64WhenOnly64BitExists;

    // FindBdsRootDir / FindHighestBdsVersion / CollectBdsVersionsFrom
    // are registry-walking; can't test deterministically without a real
    // BDS install. Sanity-check that the shape of the call works.
    [Test] procedure FindBdsRootDir_ReturnsForRealInstallOrEmpty;
    [Test] procedure FindHighestBdsVersion_ReturnsResolvableTuple;
  end;

implementation

uses
  System.SysUtils,
  System.IOUtils,
  System.Classes,
  Winapi.Windows,
  DelphiLsp.DelphiInstall;

{ TDelphiInstallTests }

procedure TDelphiInstallTests.WriteFile(const RelPath, Content: string);
var
  Full, Dir: string;
begin
  Full := IncludeTrailingPathDelimiter(FRoot) + RelPath;
  Dir := ExtractFilePath(Full);
  if (Dir <> '') and not TDirectory.Exists(Dir) then
    TDirectory.CreateDirectory(Dir);
  TFile.WriteAllText(Full, Content, TEncoding.UTF8);
end;

procedure TDelphiInstallTests.Setup;
begin
  FRoot := TPath.Combine(TPath.GetTempPath, 'delphiinst-' +
    TGUID.NewGuid.ToString.Replace('{', '').Replace('}', ''));
  TDirectory.CreateDirectory(FRoot);
end;

procedure TDelphiInstallTests.TearDown;
begin
  if (FRoot <> '') and TDirectory.Exists(FRoot) then
    TDirectory.Delete(FRoot, True);
end;

{ CompareBdsVersions }

procedure TDelphiInstallTests.Compare_EqualVersions;
begin
  Assert.IsTrue(CompareBdsVersions('37.0', '37.0') = 0);
  Assert.IsTrue(CompareBdsVersions('22.0', '22.0') = 0);
end;

procedure TDelphiInstallTests.Compare_HigherMajorWins;
begin
  Assert.IsTrue(CompareBdsVersions('37.0', '23.0') > 0);
  Assert.IsTrue(CompareBdsVersions('23.0', '37.0') < 0);
  // The "9.0 vs 37.0" case the build.bat originally got wrong with
  // lexicographic sort — must compare numerically.
  Assert.IsTrue(CompareBdsVersions('9.0', '37.0') < 0,
    '9.0 must be less than 37.0 numerically');
end;

procedure TDelphiInstallTests.Compare_HigherMinorWinsWhenMajorEqual;
begin
  Assert.IsTrue(CompareBdsVersions('37.1', '37.0') > 0);
  Assert.IsTrue(CompareBdsVersions('37.0', '37.1') < 0);
end;

procedure TDelphiInstallTests.Compare_NonNumericPartsTreatAsZero;
begin
  // 'foo.bar' parses to (0, 0); equal to '0.0'.
  Assert.IsTrue(CompareBdsVersions('foo.bar', '0.0') = 0);
end;

procedure TDelphiInstallTests.Compare_MissingMinorTreatsAsZero;
begin
  // '37' parses to (37, 0)
  Assert.IsTrue(CompareBdsVersions('37', '37.0') = 0);
end;

procedure TDelphiInstallTests.Compare_EmptyStringsAreEqual;
begin
  // Both empty parse to (0, 0).
  Assert.IsTrue(CompareBdsVersions('', '') = 0);
end;

{ ExtractBdsVersionFromSettings }

procedure TDelphiInstallTests.Extract_FindsStudioPath;
var
  P: string;
begin
  P := IncludeTrailingPathDelimiter(FRoot) + 'a.delphilsp.json';
  WriteFile('a.delphilsp.json',
    '{"settings":{"foo":"file:///c:/program%20files/embarcadero/studio/37.0/bar"}}');
  Assert.AreEqual('37.0', ExtractBdsVersionFromSettings(P));
end;

procedure TDelphiInstallTests.Extract_FindsBdsPath;
var
  P: string;
begin
  P := IncludeTrailingPathDelimiter(FRoot) + 'b.delphilsp.json';
  WriteFile('b.delphilsp.json', '{"foo":"...BDS/22.0/something"}');
  Assert.AreEqual('22.0', ExtractBdsVersionFromSettings(P));
end;

procedure TDelphiInstallTests.Extract_FindsBackslashForm;
var
  P: string;
begin
  P := IncludeTrailingPathDelimiter(FRoot) + 'c.delphilsp.json';
  WriteFile('c.delphilsp.json',
    '{"path":"C:\\Program Files\\Embarcadero\\Studio\\37.0\\bin"}');
  Assert.AreEqual('37.0', ExtractBdsVersionFromSettings(P));
end;

procedure TDelphiInstallTests.Extract_ReturnsEmptyForNoMatch;
var
  P: string;
begin
  P := IncludeTrailingPathDelimiter(FRoot) + 'd.delphilsp.json';
  WriteFile('d.delphilsp.json', '{"unrelated":"content"}');
  Assert.AreEqual('', ExtractBdsVersionFromSettings(P));
end;

procedure TDelphiInstallTests.Extract_ReturnsEmptyForMissingFile;
begin
  Assert.AreEqual('',
    ExtractBdsVersionFromSettings(FRoot + '\nonexistent.delphilsp.json'));
end;

procedure TDelphiInstallTests.Extract_PicksFirstMatch;
var
  P: string;
begin
  // Multiple version references; the regex returns the first match.
  P := IncludeTrailingPathDelimiter(FRoot) + 'e.delphilsp.json';
  WriteFile('e.delphilsp.json',
    '{"a":"studio/37.0/x","b":"BDS/22.0/y"}');
  Assert.AreEqual('37.0', ExtractBdsVersionFromSettings(P));
end;

procedure TDelphiInstallTests.Extract_CaseInsensitiveStudio;
var
  P: string;
begin
  P := IncludeTrailingPathDelimiter(FRoot) + 'f.delphilsp.json';
  WriteFile('f.delphilsp.json', '{"path":"C:/Program Files/Embarcadero/STUDIO/23.0/lib"}');
  Assert.AreEqual('23.0', ExtractBdsVersionFromSettings(P));
end;

{ FindDelphiLspExeUnder }

procedure TDelphiInstallTests.FindExe_ReturnsEmptyForBlankRoot;
begin
  Assert.AreEqual('', FindDelphiLspExeUnder(''));
end;

procedure TDelphiInstallTests.FindExe_ReturnsEmptyWhenNeitherExists;
begin
  // Empty fake "BDS root" — no bin or bin64 subdirs.
  Assert.AreEqual('', FindDelphiLspExeUnder(FRoot));
end;

procedure TDelphiInstallTests.FindExe_PrefersBin32WhenBothExist;
var
  Bin64Path, Bin32Path: string;
begin
  // Create both fake exe paths under a synthetic BDS root.
  Bin64Path := IncludeTrailingPathDelimiter(FRoot) + 'bin64\DelphiLSP.exe';
  Bin32Path := IncludeTrailingPathDelimiter(FRoot) + 'bin\DelphiLSP.exe';
  TDirectory.CreateDirectory(ExtractFilePath(Bin64Path));
  TDirectory.CreateDirectory(ExtractFilePath(Bin32Path));
  TFile.WriteAllText(Bin64Path, 'fake');
  TFile.WriteAllText(Bin32Path, 'fake');
  // Default behavior (no DELPHI_LSP_BITS): prefer bin32 since Embarcadero's
  // 64-bit DelphiLSP currently drops diagnostics (RSS-5400, Delphi 13.1).
  Assert.AreEqual(Bin32Path, FindDelphiLspExeUnder(FRoot));
end;

procedure TDelphiInstallTests.FindExe_FallsBackToBinWhenOnly32BitExists;
var
  Bin32Path: string;
begin
  Bin32Path := IncludeTrailingPathDelimiter(FRoot) + 'bin\DelphiLSP.exe';
  TDirectory.CreateDirectory(ExtractFilePath(Bin32Path));
  TFile.WriteAllText(Bin32Path, 'fake');
  Assert.AreEqual(Bin32Path, FindDelphiLspExeUnder(FRoot));
end;

procedure TDelphiInstallTests.FindExe_FallsBackToBin64WhenOnly64BitExists;
var
  Bin64Path: string;
begin
  // With 32-bit absent, the fallback path picks 64-bit even though it's
  // the deprioritised one — better than nothing for users on a 64-bit-only
  // SKU. Loud diagnostic-loss is now a known limitation, not a bug.
  Bin64Path := IncludeTrailingPathDelimiter(FRoot) + 'bin64\DelphiLSP.exe';
  TDirectory.CreateDirectory(ExtractFilePath(Bin64Path));
  TFile.WriteAllText(Bin64Path, 'fake');
  Assert.AreEqual(Bin64Path, FindDelphiLspExeUnder(FRoot));
end;

{ FindBdsRootDir / FindHighestBdsVersion — registry-driven, sanity-only }

procedure TDelphiInstallTests.FindBdsRootDir_ReturnsForRealInstallOrEmpty;
var
  Result: string;
begin
  // On the developer's machine BDS 37.0 should resolve; on a clean CI it
  // wouldn't. Both outcomes are acceptable — just verify the function
  // doesn't crash and returns a string with no trailing path delimiter.
  Result := FindBdsRootDir('37.0');
  if Result <> '' then
    Assert.IsFalse(Result.EndsWith('\') or Result.EndsWith('/'),
      'returned RootDir must not have a trailing path delimiter');
end;

procedure TDelphiInstallTests.FindHighestBdsVersion_ReturnsResolvableTuple;
var
  Version, RootDir: string;
begin
  // Either both are non-empty (real install resolved) or both empty (no
  // BDS on this machine). Should never be inconsistent.
  Version := FindHighestBdsVersion(RootDir);
  Assert.IsTrue((Version <> '') = (RootDir <> ''),
    'Version and RootDir should be both empty or both non-empty');
end;

initialization
  TDUnitX.RegisterTestFixture(TDelphiInstallTests);

end.
