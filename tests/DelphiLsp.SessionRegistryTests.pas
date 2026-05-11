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
    [Test] procedure Register_WritesClaudeSessionIdWhenProvided;
    [Test] procedure Register_SkipsClaudeSessionWhenEmpty;

    // UnregisterSession
    [Test] procedure Unregister_RemovesDir;
    [Test] procedure Unregister_EmptyPath_NoOp;
    [Test] procedure Unregister_NonexistentDir_DoesNotCrash;
    [Test] procedure Unregister_RemovesSubfilesAndDirs;

    // FindShimSessionsForCwdAt
    [Test] procedure Find_NoSessions_ReturnsEmpty;
    [Test] procedure Find_MatchingCwd_ReturnedRegardlessOfLiveness;
    [Test] procedure Find_NonMatchingCwd_Excluded;
    [Test] procedure Find_TrailingSlashCwd_StillMatches;
    [Test] procedure Find_DiscoversClaudeSessionId;
    [Test] procedure Find_DiscoversActiveProjectAndRuntimeOverride;
    [Test] procedure Find_OursVsTheirsByClaudeSessionId;
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
  R := RegisterSessionAt(FRoot, 12345, 'D:\TestCwd', '');
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
  R := RegisterSessionAt(FRoot, 999, 'D:\Cwd\With spaces', '');
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
  R := RegisterSessionAt(FRoot, 1, 'D:\Cwd', '');
  Assert.IsTrue(R.SessionDir <> '');
  Assert.IsTrue(R.ActiveSentinelPath <> '');
end;

procedure TSessionRegistryTests.Register_ActiveSentinelPathPointsAtActiveTxt;
var
  R: TSessionRegistration;
begin
  // Slash-command consumers depend on this exact filename.
  R := RegisterSessionAt(FRoot, 42, 'D:\Cwd', '');
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
  R := RegisterSessionAt('', 1, 'D:\Cwd', '');
  Assert.AreEqual('', R.SessionDir);
  Assert.AreEqual('', R.ActiveSentinelPath);
end;

procedure TSessionRegistryTests.Register_SecondCallIsIdempotent;
var
  R1, R2: TSessionRegistration;
begin
  // Same pid -> same dir. Second call should succeed without
  // erroring on the existing dir (ForceDirectories is idempotent).
  R1 := RegisterSessionAt(FRoot, 7777, 'D:\First', '');
  R2 := RegisterSessionAt(FRoot, 7777, 'D:\Second', '');
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
  R := RegisterSessionAt(FRoot, 555, 'D:\Cwd', '');
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
  R := RegisterSessionAt(FRoot, 88, 'D:\Cwd', '');
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

procedure TSessionRegistryTests.Register_WritesClaudeSessionIdWhenProvided;
const
  TestSessionId = '12345678-aaaa-bbbb-cccc-1234567890ab';
var
  R: TSessionRegistration;
  ClaudeFile, Content: string;
begin
  R := RegisterSessionAt(FRoot, 4242, 'D:\Cwd', TestSessionId);
  ClaudeFile := IncludeTrailingPathDelimiter(R.SessionDir) + 'claude-session.txt';
  Assert.IsTrue(FileExists(ClaudeFile),
    'claude-session.txt should be written when ClaudeSessionId is non-empty');
  Content := TFile.ReadAllText(ClaudeFile, TEncoding.UTF8);
  Assert.AreEqual(TestSessionId, Trim(Content));
end;

procedure TSessionRegistryTests.Register_SkipsClaudeSessionWhenEmpty;
var
  R: TSessionRegistration;
  ClaudeFile: string;
begin
  // Backward-compat: pre-disambiguation callers (or shims that
  // couldn't resolve a session id) pass '' and we must NOT write
  // claude-session.txt — its absence is meaningful (the FindShim
  // helper treats absent as "unknown owner").
  R := RegisterSessionAt(FRoot, 5151, 'D:\Cwd', '');
  ClaudeFile := IncludeTrailingPathDelimiter(R.SessionDir) + 'claude-session.txt';
  Assert.IsFalse(FileExists(ClaudeFile),
    'claude-session.txt should NOT exist when ClaudeSessionId is empty');
end;

{ FindShimSessionsForCwdAt }

procedure TSessionRegistryTests.Find_NoSessions_ReturnsEmpty;
var
  Sessions: TArray<TShimSession>;
begin
  Sessions := FindShimSessionsForCwdAt(FRoot, 'D:\Anything');
  Assert.IsTrue(Length(Sessions) = 0);
end;

procedure TSessionRegistryTests.Find_MatchingCwd_ReturnedRegardlessOfLiveness;
var
  Sessions: TArray<TShimSession>;
begin
  // Use a fake PID (99999999 — unlikely to be alive) and register at FRoot.
  RegisterSessionAt(FRoot, 99999999, 'D:\TargetCwd', '');
  Sessions := FindShimSessionsForCwdAt(FRoot, 'D:\TargetCwd');
  Assert.IsTrue(Length(Sessions) = 1, 'should find the one matching session');
  Assert.IsTrue(Sessions[0].Pid = 99999999);
  Assert.IsFalse(Sessions[0].Alive, 'PID is fake; should not be alive');
end;

procedure TSessionRegistryTests.Find_NonMatchingCwd_Excluded;
var
  Sessions: TArray<TShimSession>;
begin
  RegisterSessionAt(FRoot, 11111, 'D:\Other\Cwd', '');
  RegisterSessionAt(FRoot, 22222, 'D:\Our\Cwd', '');
  Sessions := FindShimSessionsForCwdAt(FRoot, 'D:\Our\Cwd');
  Assert.IsTrue(Length(Sessions) = 1, 'only matching cwd should be returned');
  Assert.IsTrue(Sessions[0].Pid = 22222);
end;

procedure TSessionRegistryTests.Find_TrailingSlashCwd_StillMatches;
var
  Sessions: TArray<TShimSession>;
begin
  // NormalizeCwd strips trailing slashes; matches regardless of form.
  RegisterSessionAt(FRoot, 33333, 'D:\Some\Path', '');
  Sessions := FindShimSessionsForCwdAt(FRoot, 'D:\Some\Path\');
  Assert.IsTrue(Length(Sessions) = 1,
    'trailing-slash form should canonicalize to match');
end;

procedure TSessionRegistryTests.Find_DiscoversClaudeSessionId;
const
  Sid = 'a1b2c3d4';
var
  Sessions: TArray<TShimSession>;
begin
  RegisterSessionAt(FRoot, 44444, 'D:\Cwd', Sid);
  Sessions := FindShimSessionsForCwdAt(FRoot, 'D:\Cwd');
  Assert.IsTrue(Length(Sessions) = 1);
  Assert.AreEqual(Sid, Sessions[0].ClaudeSessionId);
end;

procedure TSessionRegistryTests.Find_DiscoversActiveProjectAndRuntimeOverride;
var
  R: TSessionRegistration;
  Sessions: TArray<TShimSession>;
begin
  R := RegisterSessionAt(FRoot, 55555, 'D:\Cwd', '');
  // Drop synthetic active.txt and runtime.txt as if a slash command
  // had set them.
  TFile.WriteAllText(IncludeTrailingPathDelimiter(R.SessionDir) + 'active.txt',
    'D:\Path\To\Project.delphilsp.json', TEncoding.UTF8);
  TFile.WriteAllText(IncludeTrailingPathDelimiter(R.SessionDir) + 'runtime.txt',
    '37.0', TEncoding.UTF8);
  Sessions := FindShimSessionsForCwdAt(FRoot, 'D:\Cwd');
  Assert.IsTrue(Length(Sessions) = 1);
  Assert.AreEqual('D:\Path\To\Project.delphilsp.json',
    Sessions[0].ActiveProject);
  Assert.AreEqual('37.0', Sessions[0].RuntimeOverride);
end;

procedure TSessionRegistryTests.Find_OursVsTheirsByClaudeSessionId;
const
  MyId = 'mine-aaa';
  TheirId = 'theirs-bbb';
var
  Sessions: TArray<TShimSession>;
  S: TShimSession;
  MineFound, TheirsFound: Boolean;
begin
  // Two shims for the same cwd, different Claude sessions — both
  // returned by Find. The caller (CliCommands) does the filter.
  RegisterSessionAt(FRoot, 60001, 'D:\Cwd', MyId);
  RegisterSessionAt(FRoot, 60002, 'D:\Cwd', TheirId);
  Sessions := FindShimSessionsForCwdAt(FRoot, 'D:\Cwd');
  Assert.IsTrue(Length(Sessions) = 2,
    'both shims for the same cwd should be returned regardless of session');
  MineFound := False;
  TheirsFound := False;
  for S in Sessions do
  begin
    if S.ClaudeSessionId = MyId then MineFound := True;
    if S.ClaudeSessionId = TheirId then TheirsFound := True;
  end;
  Assert.IsTrue(MineFound and TheirsFound,
    'both ClaudeSessionId values should be present');
end;

initialization
  TDUnitX.RegisterTestFixture(TSessionRegistryTests);

end.
