// Copyright (c) 2026 Jared Davison. Released under the MIT License (see LICENSE).
//
// AI-generated (Claude Code). Review before trusting in production.

unit DelphiLsp.SessionIdResolverTests;

interface

uses
  DUnitX.TestFramework;

type
  [TestFixture]
  TSessionIdResolverTests = class
  private
    FRoot: string;
    FClaudePidDir: string;
    FProjectsRoot: string;
    procedure WriteJson(const RelPath, Content: string);
  public
    [Setup] procedure Setup;
    [TearDown] procedure TearDown;

    // ParseSessionIdFromArgv: hard to test without a separate process, so
    // we exercise it indirectly by checking it returns '' (no matching arg
    // in the test runner's argv) — confirms the shape of the function at
    // least.
    [Test] procedure ParseSessionIdFromArgv_ReturnsEmptyWhenAbsent;

    // ReadSessionIdFromHookFile
    [Test] procedure ReadSession_ReturnsId_WhenFilePresent;
    [Test] procedure ReadSession_ReturnsEmpty_WhenFileMissing;
    [Test] procedure ReadSession_ReturnsEmpty_WhenJsonInvalid;
    [Test] procedure ReadSession_ReturnsEmpty_WhenSessionIdAbsent;
    [Test] procedure ReadSession_ReturnsEmpty_WhenKeyBlank;

    // ResolveSessionIdViaHookFiles
    [Test] procedure ResolveByCwd_ReturnsMatchingId;
    [Test] procedure ResolveByCwd_PicksMostRecentOnTie;
    [Test] procedure ResolveByCwd_IgnoresMismatchedCwd;
    [Test] procedure ResolveByCwd_HandlesMixedCaseCwd;
    [Test] procedure ResolveByCwd_ReturnsEmpty_WhenDirMissing;
    [Test] procedure ResolveByCwd_ReturnsEmpty_WhenNoFilesMatch;

    // DiscoverSessionIdFromProjectsDir
    [Test] procedure DiscoverFromProjects_ReturnsBasenameOfMostRecent;
    [Test] procedure DiscoverFromProjects_ReturnsEmpty_WhenNoEncodedDir;
    [Test] procedure DiscoverFromProjects_ReturnsEmpty_WhenNoJsonl;
    [Test] procedure DiscoverFromProjects_EncodesCwdCorrectly;
  end;

implementation

uses
  System.SysUtils,
  System.IOUtils,
  System.DateUtils,
  DelphiLsp.SessionIdResolver;

{ TSessionIdResolverTests }

procedure TSessionIdResolverTests.WriteJson(const RelPath, Content: string);
var
  Full, Dir: string;
begin
  Full := IncludeTrailingPathDelimiter(FRoot) + RelPath;
  Dir := ExtractFilePath(Full);
  if (Dir <> '') and not TDirectory.Exists(Dir) then
    TDirectory.CreateDirectory(Dir);
  TFile.WriteAllText(Full, Content, TEncoding.UTF8);
end;

procedure TSessionIdResolverTests.Setup;
begin
  FRoot := TPath.Combine(TPath.GetTempPath, 'sessionid-' +
    TGUID.NewGuid.ToString.Replace('{', '').Replace('}', ''));
  TDirectory.CreateDirectory(FRoot);
  FClaudePidDir := IncludeTrailingPathDelimiter(FRoot) + 'claude-pid';
  FProjectsRoot := IncludeTrailingPathDelimiter(FRoot) + 'projects';
  TDirectory.CreateDirectory(FClaudePidDir);
  TDirectory.CreateDirectory(FProjectsRoot);
end;

procedure TSessionIdResolverTests.TearDown;
begin
  if (FRoot <> '') and TDirectory.Exists(FRoot) then
    TDirectory.Delete(FRoot, True);
end;

{ ParseSessionIdFromArgv }

procedure TSessionIdResolverTests.ParseSessionIdFromArgv_ReturnsEmptyWhenAbsent;
begin
  // Test runner's argv almost certainly doesn't contain --claude-session-id=,
  // so this returns ''. Exercises the no-match path of the loop.
  Assert.AreEqual('', ParseSessionIdFromArgv);
end;

{ ReadSessionIdFromHookFile }

procedure TSessionIdResolverTests.ReadSession_ReturnsId_WhenFilePresent;
begin
  WriteJson('claude-pid\12345.json', '{"session_id":"abc-123","cwd":"D:\\foo"}');
  Assert.AreEqual('abc-123',
    ReadSessionIdFromHookFile(FClaudePidDir, '12345'));
end;

procedure TSessionIdResolverTests.ReadSession_ReturnsEmpty_WhenFileMissing;
begin
  Assert.AreEqual('',
    ReadSessionIdFromHookFile(FClaudePidDir, '99999'));
end;

procedure TSessionIdResolverTests.ReadSession_ReturnsEmpty_WhenJsonInvalid;
begin
  WriteJson('claude-pid\invalid.json', 'not json {');
  Assert.AreEqual('',
    ReadSessionIdFromHookFile(FClaudePidDir, 'invalid'));
end;

procedure TSessionIdResolverTests.ReadSession_ReturnsEmpty_WhenSessionIdAbsent;
begin
  WriteJson('claude-pid\nosession.json', '{"cwd":"D:\\foo"}');
  Assert.AreEqual('',
    ReadSessionIdFromHookFile(FClaudePidDir, 'nosession'));
end;

procedure TSessionIdResolverTests.ReadSession_ReturnsEmpty_WhenKeyBlank;
begin
  Assert.AreEqual('', ReadSessionIdFromHookFile(FClaudePidDir, ''));
end;

{ ResolveSessionIdViaHookFiles }

procedure TSessionIdResolverTests.ResolveByCwd_ReturnsMatchingId;
begin
  WriteJson('claude-pid\by-id-sess-A.json',
    '{"session_id":"sess-A","cwd":"D:\\Some\\Cwd"}');
  Assert.AreEqual('sess-A',
    ResolveSessionIdViaHookFiles(FClaudePidDir, 'D:\Some\Cwd'));
end;

procedure TSessionIdResolverTests.ResolveByCwd_PicksMostRecentOnTie;
var
  OldFile: string;
begin
  // Two files for the same cwd; the more-recently-modified wins.
  WriteJson('claude-pid\by-id-old.json',
    '{"session_id":"old","cwd":"D:\\Some\\Cwd"}');
  OldFile := IncludeTrailingPathDelimiter(FClaudePidDir) + 'by-id-old.json';
  TFile.SetLastWriteTime(OldFile, IncDay(Now, -7));

  WriteJson('claude-pid\by-id-recent.json',
    '{"session_id":"recent","cwd":"D:\\Some\\Cwd"}');

  Assert.AreEqual('recent',
    ResolveSessionIdViaHookFiles(FClaudePidDir, 'D:\Some\Cwd'));
end;

procedure TSessionIdResolverTests.ResolveByCwd_IgnoresMismatchedCwd;
begin
  WriteJson('claude-pid\by-id-other.json',
    '{"session_id":"other","cwd":"D:\\Different\\Cwd"}');
  Assert.AreEqual('',
    ResolveSessionIdViaHookFiles(FClaudePidDir, 'D:\Some\Cwd'));
end;

procedure TSessionIdResolverTests.ResolveByCwd_HandlesMixedCaseCwd;
begin
  // Recorded cwd uses one case; query uses another. CanonicalizeCwd
  // (lowercase) makes them match.
  WriteJson('claude-pid\by-id-mixed.json',
    '{"session_id":"mixed","cwd":"d:\\some\\cwd"}');
  Assert.AreEqual('mixed',
    ResolveSessionIdViaHookFiles(FClaudePidDir, 'D:\Some\Cwd'));
end;

procedure TSessionIdResolverTests.ResolveByCwd_ReturnsEmpty_WhenDirMissing;
begin
  Assert.AreEqual('',
    ResolveSessionIdViaHookFiles(FRoot + '\nonexistent', 'D:\foo'));
end;

procedure TSessionIdResolverTests.ResolveByCwd_ReturnsEmpty_WhenNoFilesMatch;
begin
  // Empty claude-pid dir.
  Assert.AreEqual('',
    ResolveSessionIdViaHookFiles(FClaudePidDir, 'D:\foo'));
end;

{ DiscoverSessionIdFromProjectsDir }

procedure TSessionIdResolverTests.DiscoverFromProjects_ReturnsBasenameOfMostRecent;
const
  Encoded = 'D--Some-Cwd';
var
  OldFile: string;
begin
  TDirectory.CreateDirectory(IncludeTrailingPathDelimiter(FProjectsRoot) + Encoded);
  WriteJson('projects\' + Encoded + '\old-session.jsonl', '');
  OldFile := IncludeTrailingPathDelimiter(FProjectsRoot) + Encoded +
             PathDelim + 'old-session.jsonl';
  TFile.SetLastWriteTime(OldFile, IncDay(Now, -3));
  WriteJson('projects\' + Encoded + '\recent-session.jsonl', '');

  Assert.AreEqual('recent-session',
    DiscoverSessionIdFromProjectsDir(FProjectsRoot, 'D:\Some\Cwd'));
end;

procedure TSessionIdResolverTests.DiscoverFromProjects_ReturnsEmpty_WhenNoEncodedDir;
begin
  // Cwd that doesn't match any encoded subdir.
  Assert.AreEqual('',
    DiscoverSessionIdFromProjectsDir(FProjectsRoot, 'D:\Never\Recorded'));
end;

procedure TSessionIdResolverTests.DiscoverFromProjects_ReturnsEmpty_WhenNoJsonl;
const
  Encoded = 'D--Empty-Cwd';
begin
  // Dir exists but has no .jsonl files.
  TDirectory.CreateDirectory(IncludeTrailingPathDelimiter(FProjectsRoot) + Encoded);
  Assert.AreEqual('',
    DiscoverSessionIdFromProjectsDir(FProjectsRoot, 'D:\Empty\Cwd'));
end;

procedure TSessionIdResolverTests.DiscoverFromProjects_EncodesCwdCorrectly;
const
  Encoded = 'D--Documents-TestDproj';
begin
  // Encoding rule: ':' and '\' both become '-'. So D:\Documents\TestDproj
  // becomes D--Documents-TestDproj.
  TDirectory.CreateDirectory(IncludeTrailingPathDelimiter(FProjectsRoot) + Encoded);
  WriteJson('projects\' + Encoded + '\correct-session.jsonl', '');
  Assert.AreEqual('correct-session',
    DiscoverSessionIdFromProjectsDir(FProjectsRoot, 'D:\Documents\TestDproj'));
end;

initialization
  TDUnitX.RegisterTestFixture(TSessionIdResolverTests);

end.
