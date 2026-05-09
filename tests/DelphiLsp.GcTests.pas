// Copyright (c) 2026 Jared Davison. Released under the MIT License (see LICENSE).
//
// AI-generated (Claude Code). Review before trusting in production.

unit DelphiLsp.GcTests;

interface

uses
  DUnitX.TestFramework;

type
  [TestFixture]
  TGcTests = class
  private
    FRoot: string;
    FSessionsRoot: string;
    FStateDir: string;
    FClaudePidDir: string;
    FProjectsRoot: string;
    function PathOf(const RelPath: string): string;
    procedure TouchFile(const RelPath, Content: string);
    procedure MakeDir(const RelPath: string);
    procedure MakeAliveJsonl(const SessionId: string);
  public
    [Setup] procedure Setup;
    [TearDown] procedure TearDown;

    // GcOrphanSessions
    [Test] procedure OrphanGc_RemovesDirsForDeadPids;
    [Test] procedure OrphanGc_KeepsSelfPidDir;
    [Test] procedure OrphanGc_IgnoresNonNumericDirs;
    [Test] procedure OrphanGc_NoOp_WhenSessionsRootMissing;

    // GcStaleSessionState
    [Test] procedure StaleSticky_RemovesUnresumableSessions;
    [Test] procedure StaleSticky_KeepsAliveSession;
    [Test] procedure StaleSticky_NeverRemovesCurrentSession;
    [Test] procedure StaleSticky_NoOp_WhenDirMissing;

    // GcStaleClaudePidFiles
    [Test] procedure StalePid_RemovesDeadPidFiles;
    [Test] procedure StalePid_RemovesUnresumableByIdFiles;
    [Test] procedure StalePid_KeepsAliveByIdFiles;
    [Test] procedure StalePid_NoOp_WhenDirMissing;
  end;

implementation

uses
  Winapi.Windows,
  System.SysUtils,
  System.IOUtils,
  DelphiLsp.Gc;

{ TGcTests }

function TGcTests.PathOf(const RelPath: string): string;
begin
  Result := IncludeTrailingPathDelimiter(FRoot) + RelPath;
end;

procedure TGcTests.TouchFile(const RelPath, Content: string);
var
  Full, Dir: string;
begin
  Full := PathOf(RelPath);
  Dir := ExtractFilePath(Full);
  if (Dir <> '') and not TDirectory.Exists(Dir) then
    TDirectory.CreateDirectory(Dir);
  TFile.WriteAllText(Full, Content);
end;

procedure TGcTests.MakeDir(const RelPath: string);
begin
  TDirectory.CreateDirectory(PathOf(RelPath));
end;

procedure TGcTests.MakeAliveJsonl(const SessionId: string);
begin
  // The "alive" signal is a .jsonl file under projects-root/<encoded-cwd>/.
  // Just put it in a synthetic encoded-cwd dir; IsClaudeSessionAlive walks
  // every subdir of the projects root.
  TouchFile('projects\D--Some-Cwd\' + SessionId + '.jsonl', '');
end;

procedure TGcTests.Setup;
begin
  FRoot := TPath.Combine(TPath.GetTempPath, 'gctests-' +
    TGUID.NewGuid.ToString.Replace('{', '').Replace('}', ''));
  TDirectory.CreateDirectory(FRoot);
  FSessionsRoot := PathOf('sessions');
  FStateDir := PathOf('session-state');
  FClaudePidDir := PathOf('claude-pid');
  FProjectsRoot := PathOf('projects');
  TDirectory.CreateDirectory(FSessionsRoot);
  TDirectory.CreateDirectory(FStateDir);
  TDirectory.CreateDirectory(FClaudePidDir);
  TDirectory.CreateDirectory(FProjectsRoot);
end;

procedure TGcTests.TearDown;
begin
  if (FRoot <> '') and TDirectory.Exists(FRoot) then
    TDirectory.Delete(FRoot, True);
end;

{ GcOrphanSessions }

procedure TGcTests.OrphanGc_RemovesDirsForDeadPids;
begin
  // PID 99999 is overwhelmingly likely to be unused. Make a dir for it
  // and run the GC; it should be deleted.
  MakeDir('sessions\99999');
  TouchFile('sessions\99999\active.txt', '');
  GcOrphanSessions(FSessionsRoot, GetCurrentProcessId);
  Assert.IsFalse(TDirectory.Exists(PathOf('sessions\99999')),
    'dead-PID dir should be removed');
end;

procedure TGcTests.OrphanGc_KeepsSelfPidDir;
var
  SelfDir: string;
begin
  SelfDir := PathOf('sessions\' + GetCurrentProcessId.ToString);
  TDirectory.CreateDirectory(SelfDir);
  TouchFile('sessions\' + GetCurrentProcessId.ToString + '\active.txt', '');
  GcOrphanSessions(FSessionsRoot, GetCurrentProcessId);
  Assert.IsTrue(TDirectory.Exists(SelfDir),
    'self-PID dir must NEVER be removed by orphan GC');
end;

procedure TGcTests.OrphanGc_IgnoresNonNumericDirs;
begin
  // A non-numeric subdir name shouldn't be parsed as a PID; leave it alone.
  MakeDir('sessions\not-a-pid');
  TouchFile('sessions\not-a-pid\file.txt', '');
  GcOrphanSessions(FSessionsRoot, GetCurrentProcessId);
  Assert.IsTrue(TDirectory.Exists(PathOf('sessions\not-a-pid')),
    'non-numeric dirs are not PID dirs and must not be touched');
end;

procedure TGcTests.OrphanGc_NoOp_WhenSessionsRootMissing;
begin
  // Should not throw or fail.
  GcOrphanSessions(FRoot + '\nonexistent-sessions', GetCurrentProcessId);
  Assert.Pass('no exception is the test');
end;

{ GcStaleSessionState }

procedure TGcTests.StaleSticky_RemovesUnresumableSessions;
const
  StaleId = 'gone-from-history';
begin
  // Sticky entry with no corresponding .jsonl in projects root → unresumable
  // → should be deleted.
  TouchFile('session-state\' + StaleId + '.json', '{}');
  Assert.IsTrue(FileExists(PathOf('session-state\' + StaleId + '.json')),
    'precondition');
  GcStaleSessionState(FStateDir, FProjectsRoot, 'current-session');
  Assert.IsFalse(FileExists(PathOf('session-state\' + StaleId + '.json')),
    'unresumable sticky should be removed');
end;

procedure TGcTests.StaleSticky_KeepsAliveSession;
const
  AliveId = 'still-resumable';
begin
  TouchFile('session-state\' + AliveId + '.json', '{}');
  MakeAliveJsonl(AliveId); // gives IsClaudeSessionAlive a positive hit
  GcStaleSessionState(FStateDir, FProjectsRoot, 'current-session');
  Assert.IsTrue(FileExists(PathOf('session-state\' + AliveId + '.json')),
    'sticky for resumable session must be kept');
end;

procedure TGcTests.StaleSticky_NeverRemovesCurrentSession;
const
  CurrentId = 'this-very-session';
begin
  // No .jsonl exists for this id, so it'd normally be GC'd — but the
  // current-session guard saves it.
  TouchFile('session-state\' + CurrentId + '.json', '{}');
  GcStaleSessionState(FStateDir, FProjectsRoot, CurrentId);
  Assert.IsTrue(FileExists(PathOf('session-state\' + CurrentId + '.json')),
    'sticky for current session must NEVER be GC''d');
end;

procedure TGcTests.StaleSticky_NoOp_WhenDirMissing;
begin
  GcStaleSessionState(FRoot + '\nonexistent', FProjectsRoot, 'sess');
  Assert.Pass('no exception is the test');
end;

{ GcStaleClaudePidFiles }

procedure TGcTests.StalePid_RemovesDeadPidFiles;
begin
  // PID 99999 should not exist.
  TouchFile('claude-pid\99999.json', '{}');
  GcStaleClaudePidFiles(FClaudePidDir, FProjectsRoot);
  Assert.IsFalse(FileExists(PathOf('claude-pid\99999.json')),
    'dead-PID hook drop should be removed');
end;

procedure TGcTests.StalePid_RemovesUnresumableByIdFiles;
const
  StaleId = 'expired-session';
begin
  TouchFile('claude-pid\by-id-' + StaleId + '.json', '{}');
  GcStaleClaudePidFiles(FClaudePidDir, FProjectsRoot);
  Assert.IsFalse(FileExists(PathOf('claude-pid\by-id-' + StaleId + '.json')),
    'by-id hook drop for unresumable session should be removed');
end;

procedure TGcTests.StalePid_KeepsAliveByIdFiles;
const
  AliveId = 'still-alive-session';
begin
  TouchFile('claude-pid\by-id-' + AliveId + '.json', '{}');
  MakeAliveJsonl(AliveId);
  GcStaleClaudePidFiles(FClaudePidDir, FProjectsRoot);
  Assert.IsTrue(FileExists(PathOf('claude-pid\by-id-' + AliveId + '.json')),
    'by-id hook drop for resumable session must be kept');
end;

procedure TGcTests.StalePid_NoOp_WhenDirMissing;
begin
  GcStaleClaudePidFiles(FRoot + '\nonexistent', FProjectsRoot);
  Assert.Pass('no exception is the test');
end;

initialization
  TDUnitX.RegisterTestFixture(TGcTests);

end.
