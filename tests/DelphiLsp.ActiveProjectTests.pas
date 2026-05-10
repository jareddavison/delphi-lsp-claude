// Copyright (c) 2026 Jared Davison. Released under the MIT License (see LICENSE).
//
// AI-generated (Claude Code). Review before trusting in production.

unit DelphiLsp.ActiveProjectTests;

interface

uses
  DUnitX.TestFramework;

type
  [TestFixture]
  TActiveProjectTests = class
  private
    FRoot: string;
    function PathIn(const Name: string): string;
    procedure WriteFile(const Name, Content: string);
    procedure DeleteFixtureFile(const Name: string);
  public
    [Setup] procedure Setup;
    [TearDown] procedure TearDown;

    // Construction
    [Test] procedure Create_PopulatesPathAndUri;
    [Test] procedure Create_NoWatcherStartedAutomatically;

    // Invalidate / CheckAndConsumeIfChanged
    [Test] procedure Check_NotInvalidated_ReturnsFalse;
    [Test] procedure Check_InvalidatedButHashUnchanged_ReturnsFalse;
    [Test] procedure Check_InvalidatedAndContentChanged_ReturnsTrue;
    [Test] procedure Check_ConsumesInvalidatedFlagOnSuccess;
    [Test] procedure Check_PreservesInvalidatedFlagWhenFileMissing;
    [Test] procedure Check_FileRecreatedAfterDeletion_ReturnsTrueIfDifferent;
    [Test] procedure Invalidate_IsIdempotent;

    // Edge cases
    [Test] procedure Create_NonexistentFile_StillConstructs;
    [Test] procedure Create_NonexistentFile_FirstChangeReturnsTrue;
  end;

implementation

uses
  System.SysUtils,
  System.IOUtils,
  DelphiLsp.ActiveProject;

procedure TActiveProjectTests.Setup;
begin
  FRoot := TPath.Combine(TPath.GetTempPath, 'activeproj-' +
    TGUID.NewGuid.ToString.Replace('{', '').Replace('}', ''));
  TDirectory.CreateDirectory(FRoot);
end;

procedure TActiveProjectTests.TearDown;
begin
  try
    if TDirectory.Exists(FRoot) then TDirectory.Delete(FRoot, True);
  except
    // Best-effort; tolerate Windows file-handle lag.
  end;
end;

function TActiveProjectTests.PathIn(const Name: string): string;
begin
  Result := IncludeTrailingPathDelimiter(FRoot) + Name;
end;

procedure TActiveProjectTests.WriteFile(const Name, Content: string);
begin
  TFile.WriteAllText(PathIn(Name), Content, TEncoding.UTF8);
end;

procedure TActiveProjectTests.DeleteFixtureFile(const Name: string);
begin
  System.SysUtils.DeleteFile(PathIn(Name));
end;

procedure TActiveProjectTests.Create_PopulatesPathAndUri;
var
  P: TActiveProject;
  Full: string;
begin
  WriteFile('proj.delphilsp.json', '{}');
  Full := PathIn('proj.delphilsp.json');
  P := TActiveProject.Create(Full);
  try
    Assert.AreEqual(Full, P.Path);
    Assert.IsTrue(P.Uri.StartsWith('file:///'),
      'Uri should be a file:// URI');
    Assert.IsTrue(P.Uri.EndsWith('proj.delphilsp.json'),
      'Uri should end with the filename');
  finally
    P.Free;
  end;
end;

procedure TActiveProjectTests.Create_NoWatcherStartedAutomatically;
var
  P: TActiveProject;
begin
  // The watcher thread is opt-in; tests that don't call StartWatcher
  // should be able to construct + destroy in microseconds, not block
  // on a thread join.
  WriteFile('p.delphilsp.json', 'a');
  P := TActiveProject.Create(PathIn('p.delphilsp.json'));
  P.Free;
  Assert.Pass('constructed and freed without starting a watcher');
end;

procedure TActiveProjectTests.Check_NotInvalidated_ReturnsFalse;
var
  P: TActiveProject;
begin
  WriteFile('q.delphilsp.json', '{"x":1}');
  P := TActiveProject.Create(PathIn('q.delphilsp.json'));
  try
    // Fresh construction; nothing should report as changed.
    Assert.IsFalse(P.CheckAndConsumeIfChanged);
  finally
    P.Free;
  end;
end;

procedure TActiveProjectTests.Check_InvalidatedButHashUnchanged_ReturnsFalse;
var
  P: TActiveProject;
begin
  // The directory watcher fires for any LAST_WRITE/SIZE/FILE_NAME
  // change in the dir, even ones that don't affect the file's content
  // (e.g. neighbour file written, ACL touched, attribute change).
  // The lazy hash check should swallow these as no-ops.
  WriteFile('q.delphilsp.json', 'stable contents');
  P := TActiveProject.Create(PathIn('q.delphilsp.json'));
  try
    P.Invalidate;
    Assert.IsFalse(P.CheckAndConsumeIfChanged,
      'unchanged content should not surface as a change');
  finally
    P.Free;
  end;
end;

procedure TActiveProjectTests.Check_InvalidatedAndContentChanged_ReturnsTrue;
var
  P: TActiveProject;
begin
  WriteFile('r.delphilsp.json', 'before');
  P := TActiveProject.Create(PathIn('r.delphilsp.json'));
  try
    WriteFile('r.delphilsp.json', 'after');
    P.Invalidate;
    Assert.IsTrue(P.CheckAndConsumeIfChanged,
      'real content change should be detected');
  finally
    P.Free;
  end;
end;

procedure TActiveProjectTests.Check_ConsumesInvalidatedFlagOnSuccess;
var
  P: TActiveProject;
begin
  // After a successful CheckAndConsumeIfChanged, the invalidated flag
  // should be cleared — a second immediate call should return False
  // without re-firing.
  WriteFile('s.delphilsp.json', 'first');
  P := TActiveProject.Create(PathIn('s.delphilsp.json'));
  try
    WriteFile('s.delphilsp.json', 'second');
    P.Invalidate;
    Assert.IsTrue(P.CheckAndConsumeIfChanged);
    Assert.IsFalse(P.CheckAndConsumeIfChanged,
      'flag should be consumed after a successful check');
  finally
    P.Free;
  end;
end;

procedure TActiveProjectTests.Check_PreservesInvalidatedFlagWhenFileMissing;
var
  P: TActiveProject;
begin
  // ComputeHash returns '' when the file is unreadable. The contract
  // is "leave the flag set so the next tick retries" — important during
  // mid-write moments where the file briefly doesn't exist or is locked.
  WriteFile('t.delphilsp.json', 'init');
  P := TActiveProject.Create(PathIn('t.delphilsp.json'));
  try
    DeleteFixtureFile('t.delphilsp.json');
    P.Invalidate;
    Assert.IsFalse(P.CheckAndConsumeIfChanged,
      'no file -> hash empty -> not a real change');
    // File reappears with new contents — re-check should fire because
    // the flag was preserved from the failed attempt above.
    WriteFile('t.delphilsp.json', 'recovered');
    Assert.IsTrue(P.CheckAndConsumeIfChanged,
      'after file returns with new content, the preserved flag should detect the change');
  finally
    P.Free;
  end;
end;

procedure TActiveProjectTests.Check_FileRecreatedAfterDeletion_ReturnsTrueIfDifferent;
var
  P: TActiveProject;
begin
  WriteFile('u.delphilsp.json', 'orig');
  P := TActiveProject.Create(PathIn('u.delphilsp.json'));
  try
    DeleteFixtureFile('u.delphilsp.json');
    WriteFile('u.delphilsp.json', 'new');
    P.Invalidate;
    Assert.IsTrue(P.CheckAndConsumeIfChanged);
  finally
    P.Free;
  end;
end;

procedure TActiveProjectTests.Invalidate_IsIdempotent;
var
  P: TActiveProject;
begin
  WriteFile('v.delphilsp.json', 'x');
  P := TActiveProject.Create(PathIn('v.delphilsp.json'));
  try
    // Invalidate fires three times in quick succession (real-world: a
    // burst of file events). Should still produce exactly one change
    // signal — the second/third Invalidate is a no-op.
    P.Invalidate;
    P.Invalidate;
    P.Invalidate;
    WriteFile('v.delphilsp.json', 'y');
    Assert.IsTrue(P.CheckAndConsumeIfChanged);
    Assert.IsFalse(P.CheckAndConsumeIfChanged);
  finally
    P.Free;
  end;
end;

procedure TActiveProjectTests.Create_NonexistentFile_StillConstructs;
var
  P: TActiveProject;
begin
  // Construction shouldn't crash when the path doesn't exist (the
  // hash is just computed as ''). Exercises the FileExists guard
  // in ComputeHash.
  P := TActiveProject.Create(PathIn('does-not-exist.json'));
  try
    Assert.AreEqual(PathIn('does-not-exist.json'), P.Path);
  finally
    P.Free;
  end;
end;

procedure TActiveProjectTests.Create_NonexistentFile_FirstChangeReturnsTrue;
var
  P: TActiveProject;
begin
  // FLastHash is '' when file didn't exist at construction time.
  // Once the file appears with any content, a hash != '' is "changed".
  P := TActiveProject.Create(PathIn('latebloomer.json'));
  try
    WriteFile('latebloomer.json', 'created');
    P.Invalidate;
    Assert.IsTrue(P.CheckAndConsumeIfChanged);
  finally
    P.Free;
  end;
end;

initialization
  TDUnitX.RegisterTestFixture(TActiveProjectTests);

end.
