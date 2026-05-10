// Copyright (c) 2026 Jared Davison. Released under the MIT License (see LICENSE).
//
// AI-generated (Claude Code). Review before trusting in production.

unit DelphiLsp.StickyStateTests;

interface

uses
  DUnitX.TestFramework;

type
  [TestFixture]
  TStickyStateTests = class
  private
    FRoot: string;
    FStatePath: string;
    FSettingsFile: string;
    procedure WriteStateRaw(const Json: string);
    function StateContent: string;
  public
    [Setup] procedure Setup;
    [TearDown] procedure TearDown;

    // ReadStickyForCwd
    [Test] procedure Read_ReturnsEmpty_WhenStatePathDoesntExist;
    [Test] procedure Read_ReturnsEmpty_WhenStatePathBlank;
    [Test] procedure Read_ReturnsEmpty_WhenCwdHashAbsent;
    [Test] procedure Read_ReturnsEmpty_WhenStateFileMalformedJson;
    [Test] procedure Read_ReturnsEmpty_WhenSettingsFileNoLongerExists;
    [Test] procedure Read_ReturnsPath_WhenEntryExistsAndFileExists;

    // WriteStickyForCwd
    [Test] procedure Write_NoOp_WhenStatePathBlank;
    [Test] procedure Write_NoOp_WhenCwdBlank;
    [Test] procedure Write_NoOp_WhenSettingsBlank;
    [Test] procedure Write_CreatesNewFile_WhenAbsent;
    [Test] procedure Write_AddsEntry_PreservingOtherCwds;
    [Test] procedure Write_OverwritesExistingEntry_ForSameCwd;
    [Test] procedure Write_CreatesParentDirectory;

    // Round trip
    [Test] procedure Roundtrip_WriteThenRead_ReturnsSamePath;
    [Test] procedure Roundtrip_NormalizesCwd_TrailingSlashIgnored;

    // BuildStickyStatePath
    [Test] procedure BuildPath_BothInputsPresent_ReturnsCanonicalForm;
    [Test] procedure BuildPath_EmptyBase_ReturnsEmpty;
    [Test] procedure BuildPath_EmptySessionId_ReturnsEmpty;
    [Test] procedure BuildPath_BaseWithoutTrailingSlash_StillCorrect;
    [Test] procedure BuildPath_BaseWithTrailingSlash_NoDoubleSeparator;
  end;

implementation

uses
  System.SysUtils,
  System.IOUtils,
  System.JSON,
  DelphiLsp.StickyState;

{ TStickyStateTests }

procedure TStickyStateTests.WriteStateRaw(const Json: string);
begin
  TFile.WriteAllText(FStatePath, Json, TEncoding.UTF8);
end;

function TStickyStateTests.StateContent: string;
begin
  if FileExists(FStatePath) then
    Result := TFile.ReadAllText(FStatePath, TEncoding.UTF8)
  else
    Result := '';
end;

procedure TStickyStateTests.Setup;
begin
  FRoot := TPath.Combine(TPath.GetTempPath, 'sticky-' +
    TGUID.NewGuid.ToString.Replace('{', '').Replace('}', ''));
  TDirectory.CreateDirectory(FRoot);
  FStatePath := IncludeTrailingPathDelimiter(FRoot) + 'state.json';
  FSettingsFile := IncludeTrailingPathDelimiter(FRoot) + 'Foo.delphilsp.json';
  // Create a real settings file so the round-trip tests have something
  // FileExists(...)-positive to point at.
  TFile.WriteAllText(FSettingsFile, '{}');
end;

procedure TStickyStateTests.TearDown;
begin
  if (FRoot <> '') and TDirectory.Exists(FRoot) then
    TDirectory.Delete(FRoot, True);
end;

{ ReadStickyForCwd }

procedure TStickyStateTests.Read_ReturnsEmpty_WhenStatePathDoesntExist;
begin
  Assert.AreEqual('',
    ReadStickyForCwd(FRoot + '\nonexistent.json', 'D:\foo'));
end;

procedure TStickyStateTests.Read_ReturnsEmpty_WhenStatePathBlank;
begin
  Assert.AreEqual('', ReadStickyForCwd('', 'D:\foo'));
end;

procedure TStickyStateTests.Read_ReturnsEmpty_WhenCwdHashAbsent;
begin
  // Empty JSON object — no entry for any cwd hash.
  WriteStateRaw('{}');
  Assert.AreEqual('',
    ReadStickyForCwd(FStatePath, 'D:\never-saved-this-cwd'));
end;

procedure TStickyStateTests.Read_ReturnsEmpty_WhenStateFileMalformedJson;
begin
  WriteStateRaw('not json at all {');
  Assert.AreEqual('',
    ReadStickyForCwd(FStatePath, 'D:\anything'));
end;

procedure TStickyStateTests.Read_ReturnsEmpty_WhenSettingsFileNoLongerExists;
var
  Cwd: string;
begin
  // Write a sticky entry pointing at a now-deleted file. Read should return
  // '' rather than a stale path the caller can't load.
  Cwd := 'D:\some\path';
  WriteStickyForCwd(FStatePath, Cwd, FSettingsFile);
  TFile.Delete(FSettingsFile);
  Assert.AreEqual('', ReadStickyForCwd(FStatePath, Cwd));
end;

procedure TStickyStateTests.Read_ReturnsPath_WhenEntryExistsAndFileExists;
var
  Cwd: string;
begin
  Cwd := 'D:\Some\Workspace';
  WriteStickyForCwd(FStatePath, Cwd, FSettingsFile);
  Assert.AreEqual(FSettingsFile, ReadStickyForCwd(FStatePath, Cwd));
end;

{ WriteStickyForCwd }

procedure TStickyStateTests.Write_NoOp_WhenStatePathBlank;
begin
  // Should silently no-op (used when GSessionStatePath isn't resolvable).
  WriteStickyForCwd('', 'D:\anywhere', FSettingsFile);
  Assert.IsFalse(FileExists(FStatePath),
    'no state file should be created when StatePath is blank');
end;

procedure TStickyStateTests.Write_NoOp_WhenCwdBlank;
begin
  WriteStickyForCwd(FStatePath, '', FSettingsFile);
  Assert.IsFalse(FileExists(FStatePath));
end;

procedure TStickyStateTests.Write_NoOp_WhenSettingsBlank;
begin
  WriteStickyForCwd(FStatePath, 'D:\foo', '');
  Assert.IsFalse(FileExists(FStatePath));
end;

procedure TStickyStateTests.Write_CreatesNewFile_WhenAbsent;
begin
  Assert.IsFalse(FileExists(FStatePath), 'precondition: state file absent');
  WriteStickyForCwd(FStatePath, 'D:\foo', FSettingsFile);
  Assert.IsTrue(FileExists(FStatePath), 'state file should be created');
end;

procedure TStickyStateTests.Write_AddsEntry_PreservingOtherCwds;
begin
  WriteStickyForCwd(FStatePath, 'D:\foo', FSettingsFile);
  WriteStickyForCwd(FStatePath, 'D:\bar', FSettingsFile);
  // Both cwds resolvable from a single read pass.
  Assert.AreEqual(FSettingsFile, ReadStickyForCwd(FStatePath, 'D:\foo'));
  Assert.AreEqual(FSettingsFile, ReadStickyForCwd(FStatePath, 'D:\bar'));
end;

procedure TStickyStateTests.Write_OverwritesExistingEntry_ForSameCwd;
var
  SecondFile: string;
begin
  SecondFile := IncludeTrailingPathDelimiter(FRoot) + 'Bar.delphilsp.json';
  TFile.WriteAllText(SecondFile, '{}');

  WriteStickyForCwd(FStatePath, 'D:\foo', FSettingsFile);
  WriteStickyForCwd(FStatePath, 'D:\foo', SecondFile);
  Assert.AreEqual(SecondFile, ReadStickyForCwd(FStatePath, 'D:\foo'),
    'second write to same cwd must overwrite');
end;

procedure TStickyStateTests.Write_CreatesParentDirectory;
var
  NestedPath: string;
begin
  // StatePath in a directory that doesn't exist yet — Write must mkdir -p.
  NestedPath := IncludeTrailingPathDelimiter(FRoot) +
                'session-state\sub\state.json';
  WriteStickyForCwd(NestedPath, 'D:\foo', FSettingsFile);
  Assert.IsTrue(FileExists(NestedPath),
    'parent directories should be created automatically');
end;

{ Round trip }

procedure TStickyStateTests.Roundtrip_WriteThenRead_ReturnsSamePath;
begin
  WriteStickyForCwd(FStatePath, 'D:\Some\Cwd', FSettingsFile);
  Assert.AreEqual(FSettingsFile, ReadStickyForCwd(FStatePath, 'D:\Some\Cwd'));
end;

procedure TStickyStateTests.Roundtrip_NormalizesCwd_TrailingSlashIgnored;
begin
  // NormalizeCwd strips the trailing path delimiter; writing under one form
  // and reading under another must still hit the same hash.
  WriteStickyForCwd(FStatePath, 'D:\Some\Cwd\', FSettingsFile);
  Assert.AreEqual(FSettingsFile, ReadStickyForCwd(FStatePath, 'D:\Some\Cwd'),
    'trailing-slash form must canonicalize to the same hash');
end;

{ BuildStickyStatePath }

procedure TStickyStateTests.BuildPath_BothInputsPresent_ReturnsCanonicalForm;
begin
  Assert.AreEqual(
    'C:\PluginData\session-state\my-session-id.json',
    BuildStickyStatePath('C:\PluginData', 'my-session-id'));
end;

procedure TStickyStateTests.BuildPath_EmptyBase_ReturnsEmpty;
begin
  Assert.AreEqual('', BuildStickyStatePath('', 'session'));
end;

procedure TStickyStateTests.BuildPath_EmptySessionId_ReturnsEmpty;
begin
  Assert.AreEqual('', BuildStickyStatePath('C:\PluginData', ''));
end;

procedure TStickyStateTests.BuildPath_BaseWithoutTrailingSlash_StillCorrect;
begin
  Assert.AreEqual(
    'D:\Data\session-state\sid.json',
    BuildStickyStatePath('D:\Data', 'sid'));
end;

procedure TStickyStateTests.BuildPath_BaseWithTrailingSlash_NoDoubleSeparator;
begin
  // IncludeTrailingPathDelimiter is idempotent — a base that already
  // ends in '\' must not produce '\\'.
  Assert.AreEqual(
    'D:\Data\session-state\sid.json',
    BuildStickyStatePath('D:\Data\', 'sid'));
end;

initialization
  TDUnitX.RegisterTestFixture(TStickyStateTests);

end.
