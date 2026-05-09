// Copyright (c) 2026 Jared Davison. Released under the MIT License (see LICENSE).
//
// AI-generated (Claude Code). Review before trusting in production.

unit DelphiLsp.PluginDataTests;

interface

uses
  DUnitX.TestFramework;

type
  [TestFixture]
  TPluginDataTests = class
  private
    FRoot: string;
    procedure WriteJsonl(const RelPath: string);
  public
    [Setup] procedure Setup;
    [TearDown] procedure TearDown;

    // ResolvePluginDataBase: env-driven, can't easily test the full env
    // matrix from inside a single test process, so just sanity-check the
    // shape of what we get back.
    [Test] procedure ResolvePluginDataBase_ReturnsNonEmpty;

    // ResolveProjectsRoot: similarly env-driven; sanity test only.
    [Test] procedure ResolveProjectsRoot_ReturnsNonEmpty;

    // IsClaudeSessionAlive — meaningfully testable with synthetic projects
    // root containing fake encoded-cwd subdirs and .jsonl files.
    [Test] procedure IsClaudeSessionAlive_FindsSessionInSubdir;
    [Test] procedure IsClaudeSessionAlive_ReturnsFalseWhenJsonlMissing;
    [Test] procedure IsClaudeSessionAlive_ReturnsFalseForBlankSession;
    [Test] procedure IsClaudeSessionAlive_ReturnsFalseForBlankRoot;
    [Test] procedure IsClaudeSessionAlive_ReturnsFalseForMissingRoot;
    [Test] procedure IsClaudeSessionAlive_FindsAcrossMultipleSubdirs;
  end;

implementation

uses
  System.SysUtils,
  System.IOUtils,
  DelphiLsp.PluginData;

{ TPluginDataTests }

procedure TPluginDataTests.WriteJsonl(const RelPath: string);
var
  Full, Dir: string;
begin
  Full := IncludeTrailingPathDelimiter(FRoot) + RelPath;
  Dir := ExtractFilePath(Full);
  if (Dir <> '') and not TDirectory.Exists(Dir) then
    TDirectory.CreateDirectory(Dir);
  TFile.WriteAllText(Full, '');
end;

procedure TPluginDataTests.Setup;
begin
  FRoot := TPath.Combine(TPath.GetTempPath, 'plugindata-' +
    TGUID.NewGuid.ToString.Replace('{', '').Replace('}', ''));
  TDirectory.CreateDirectory(FRoot);
end;

procedure TPluginDataTests.TearDown;
begin
  if (FRoot <> '') and TDirectory.Exists(FRoot) then
    TDirectory.Delete(FRoot, True);
end;

procedure TPluginDataTests.ResolvePluginDataBase_ReturnsNonEmpty;
var
  Result: string;
begin
  // CLAUDE_PLUGIN_DATA likely set by Claude Code (or LOCALAPPDATA fallback).
  // Either way, the returned path should be non-empty under normal envs.
  Result := ResolvePluginDataBase;
  Assert.IsTrue(Result <> '', 'expected non-empty plugin data base path');
end;

procedure TPluginDataTests.ResolveProjectsRoot_ReturnsNonEmpty;
var
  Result: string;
begin
  Result := ResolveProjectsRoot;
  Assert.IsTrue(Result <> '', 'expected non-empty projects root');
  Assert.IsTrue(Result.ToLower.Contains('projects'),
    'returned path should end in or contain "projects"');
end;

procedure TPluginDataTests.IsClaudeSessionAlive_FindsSessionInSubdir;
const
  SessionId = 'abc-123-fake';
begin
  WriteJsonl('D--Some-Cwd\' + SessionId + '.jsonl');
  Assert.IsTrue(IsClaudeSessionAlive(FRoot, SessionId),
    'should find session via .jsonl in any subdir');
end;

procedure TPluginDataTests.IsClaudeSessionAlive_ReturnsFalseWhenJsonlMissing;
begin
  // Create the projects-root structure but no matching .jsonl
  WriteJsonl('D--Some-Cwd\different-session.jsonl');
  Assert.IsFalse(IsClaudeSessionAlive(FRoot, 'queried-session-not-here'));
end;

procedure TPluginDataTests.IsClaudeSessionAlive_ReturnsFalseForBlankSession;
begin
  Assert.IsFalse(IsClaudeSessionAlive(FRoot, ''));
end;

procedure TPluginDataTests.IsClaudeSessionAlive_ReturnsFalseForBlankRoot;
begin
  Assert.IsFalse(IsClaudeSessionAlive('', 'abc-123'));
end;

procedure TPluginDataTests.IsClaudeSessionAlive_ReturnsFalseForMissingRoot;
begin
  Assert.IsFalse(
    IsClaudeSessionAlive(FRoot + '\nonexistent-subtree', 'abc-123'));
end;

procedure TPluginDataTests.IsClaudeSessionAlive_FindsAcrossMultipleSubdirs;
const
  SessionId = 'multi-cwd-session';
begin
  // Multiple per-cwd subdirs; .jsonl lives in only one of them.
  WriteJsonl('D--First-Cwd\unrelated-1.jsonl');
  WriteJsonl('D--Second-Cwd\unrelated-2.jsonl');
  WriteJsonl('D--Third-Cwd\' + SessionId + '.jsonl');
  WriteJsonl('D--Fourth-Cwd\unrelated-3.jsonl');
  Assert.IsTrue(IsClaudeSessionAlive(FRoot, SessionId),
    'must find the .jsonl regardless of which subdir holds it');
end;

initialization
  TDUnitX.RegisterTestFixture(TPluginDataTests);

end.
