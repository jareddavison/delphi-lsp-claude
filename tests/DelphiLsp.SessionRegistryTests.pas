// Copyright (c) 2026 Jared Davison. Released under the MIT License (see LICENSE).
//
// AI-generated (Claude Code). Review before trusting in production.

unit DelphiLsp.SessionRegistryTests;

interface

uses
  DUnitX.TestFramework;

type
  [TestFixture]
  TSessionRegistryTests = class
  private
    FRoot: string;
  public
    [Setup] procedure Setup;
    [TearDown] procedure TearDown;

    // RegisterSessionAt
    [Test] procedure Register_CreatesPidDir;
    [Test] procedure Register_WritesWorkspaceTxt;
    [Test] procedure Register_ResultPathsArePopulated;
    [Test] procedure Register_ActiveSentinelPathPointsAtActiveTxt;
    [Test] procedure Register_EmptyRoot_ReturnsEmpty;
    [Test] procedure Register_SecondCallIsIdempotent;

    // UnregisterSession
    [Test] procedure Unregister_RemovesDir;
    [Test] procedure Unregister_EmptyPath_NoOp;
    [Test] procedure Unregister_NonexistentDir_DoesNotCrash;
    [Test] procedure Unregister_RemovesSubfilesAndDirs;
  end;

implementation

uses
  Winapi.Windows,
  System.SysUtils,
  System.IOUtils,
  DelphiLsp.SessionRegistry;

procedure TSessionRegistryTests.Setup;
begin
  FRoot := TPath.Combine(TPath.GetTempPath, 'sessionreg-' +
    TGUID.NewGuid.ToString.Replace('{', '').Replace('}', ''));
  TDirectory.CreateDirectory(FRoot);
end;

procedure TSessionRegistryTests.TearDown;
begin
  try
    if TDirectory.Exists(FRoot) then TDirectory.Delete(FRoot, True);
  except
    // Best-effort.
  end;
end;

procedure TSessionRegistryTests.Register_CreatesPidDir;
var
  R: TSessionRegistration;
begin
  R := RegisterSessionAt(FRoot, 12345, 'D:\TestCwd');
  Assert.IsTrue(R.SessionDir <> '', 'expected non-empty SessionDir');
  Assert.IsTrue(TDirectory.Exists(R.SessionDir),
    'session dir should be created on disk');
  Assert.IsTrue(R.SessionDir.EndsWith('12345'),
    Format('session dir should end with pid; got: %s', [R.SessionDir]));
end;

procedure TSessionRegistryTests.Register_WritesWorkspaceTxt;
var
  R: TSessionRegistration;
  WorkspaceTxt, Content: string;
begin
  R := RegisterSessionAt(FRoot, 999, 'D:\Cwd\With spaces');
  WorkspaceTxt := IncludeTrailingPathDelimiter(R.SessionDir) + 'workspace.txt';
  Assert.IsTrue(FileExists(WorkspaceTxt), 'workspace.txt should exist');
  Content := TFile.ReadAllText(WorkspaceTxt, TEncoding.UTF8);
  // Trim — TStringList.SaveToFile adds a trailing newline.
  Assert.AreEqual('D:\Cwd\With spaces', Trim(Content));
end;

procedure TSessionRegistryTests.Register_ResultPathsArePopulated;
var
  R: TSessionRegistration;
begin
  R := RegisterSessionAt(FRoot, 1, 'D:\Cwd');
  Assert.IsTrue(R.SessionDir <> '');
  Assert.IsTrue(R.ActiveSentinelPath <> '');
end;

procedure TSessionRegistryTests.Register_ActiveSentinelPathPointsAtActiveTxt;
var
  R: TSessionRegistration;
begin
  // Slash-command consumers depend on this exact filename.
  R := RegisterSessionAt(FRoot, 42, 'D:\Cwd');
  Assert.IsTrue(R.ActiveSentinelPath.EndsWith('active.txt'),
    Format('expected active.txt suffix; got: %s', [R.ActiveSentinelPath]));
end;

procedure TSessionRegistryTests.Register_EmptyRoot_ReturnsEmpty;
var
  R: TSessionRegistration;
begin
  // The high-level RegisterSession passes '' when ResolvePluginDataBase
  // can't locate a usable data dir. The lower-level RegisterSessionAt
  // mirrors that: empty in -> empty out, no FS work.
  R := RegisterSessionAt('', 1, 'D:\Cwd');
  Assert.AreEqual('', R.SessionDir);
  Assert.AreEqual('', R.ActiveSentinelPath);
end;

procedure TSessionRegistryTests.Register_SecondCallIsIdempotent;
var
  R1, R2: TSessionRegistration;
begin
  // Same pid -> same dir. Second call should succeed without
  // erroring on the existing dir (ForceDirectories is idempotent).
  R1 := RegisterSessionAt(FRoot, 7777, 'D:\First');
  R2 := RegisterSessionAt(FRoot, 7777, 'D:\Second');
  Assert.AreEqual(R1.SessionDir, R2.SessionDir);
  // workspace.txt should be overwritten with the second cwd.
  Assert.AreEqual('D:\Second',
    Trim(TFile.ReadAllText(IncludeTrailingPathDelimiter(R2.SessionDir) +
      'workspace.txt', TEncoding.UTF8)));
end;

procedure TSessionRegistryTests.Unregister_RemovesDir;
var
  R: TSessionRegistration;
begin
  R := RegisterSessionAt(FRoot, 555, 'D:\Cwd');
  Assert.IsTrue(TDirectory.Exists(R.SessionDir));
  UnregisterSession(R.SessionDir);
  Assert.IsFalse(TDirectory.Exists(R.SessionDir),
    'session dir should be deleted');
end;

procedure TSessionRegistryTests.Unregister_EmptyPath_NoOp;
begin
  // Pass '' -> early out, nothing touched, no crash.
  UnregisterSession('');
  Assert.Pass('empty path ignored cleanly');
end;

procedure TSessionRegistryTests.Unregister_NonexistentDir_DoesNotCrash;
begin
  UnregisterSession(IncludeTrailingPathDelimiter(FRoot) + 'never-existed');
  Assert.Pass('missing dir tolerated');
end;

procedure TSessionRegistryTests.Unregister_RemovesSubfilesAndDirs;
var
  R: TSessionRegistration;
  SubDir: string;
begin
  R := RegisterSessionAt(FRoot, 88, 'D:\Cwd');
  // Simulate the shim having deposited extra files (active.txt, reload.flag, etc.)
  TFile.WriteAllText(IncludeTrailingPathDelimiter(R.SessionDir) +
    'reload.flag', '');
  SubDir := IncludeTrailingPathDelimiter(R.SessionDir) + 'subdir';
  TDirectory.CreateDirectory(SubDir);
  TFile.WriteAllText(IncludeTrailingPathDelimiter(SubDir) + 'inner.txt', 'x');

  UnregisterSession(R.SessionDir);
  Assert.IsFalse(TDirectory.Exists(R.SessionDir),
    'recursive delete should remove the whole tree');
end;

initialization
  TDUnitX.RegisterTestFixture(TSessionRegistryTests);

end.
