// Copyright (c) 2026 Jared Davison. Released under the MIT License (see LICENSE).
//
// AI-generated (Claude Code). Review before trusting in production.

unit DelphiLsp.ProcessTreeTests;

interface

uses
  DUnitX.TestFramework;

type
  [TestFixture]
  TProcessTreeTests = class
  public
    [Test] procedure GetParentOfPid_ReturnsNonZeroForCurrentProcess;
    [Test] procedure GetParentOfPid_ReturnsZeroForBogusPid;
    [Test] procedure GetParentProcessId_MatchesGetParentOfPid;
    [Test] procedure GetAncestorPids_FirstEntryIsStartPid;
    [Test] procedure GetAncestorPids_StopsAtSystemPid;
    [Test] procedure GetAncestorPids_NoCycles;
    [Test] procedure GetAncestorPids_BoundedAt20Levels;
    [Test] procedure GetAncestorPids_StartPidZero_ReturnsEmpty;
  end;

implementation

uses
  Winapi.Windows,
  System.Generics.Collections,
  DelphiLsp.ProcessTree;

procedure TProcessTreeTests.GetParentOfPid_ReturnsNonZeroForCurrentProcess;
begin
  // Test runner has SOME parent (cmd, PowerShell, or VS test runner).
  Assert.IsTrue(GetParentOfPid(GetCurrentProcessId) > 0,
    'current process should have a non-zero parent');
end;

procedure TProcessTreeTests.GetParentOfPid_ReturnsZeroForBogusPid;
begin
  // PID 0 is reserved (System Idle Process); it's never a valid query target
  // and the toolhelp scan won't find it.
  Assert.IsTrue(GetParentOfPid(0) = 0,
    'bogus PID 0 should return 0');
  // Very high PID unlikely to exist on a normal system.
  Assert.IsTrue(GetParentOfPid($7FFFFFFF) = 0,
    'unlikely PID should return 0');
end;

procedure TProcessTreeTests.GetParentProcessId_MatchesGetParentOfPid;
begin
  Assert.IsTrue(GetParentProcessId = GetParentOfPid(GetCurrentProcessId),
    'GetParentProcessId is sugar for GetParentOfPid(GetCurrentProcessId)');
end;

procedure TProcessTreeTests.GetAncestorPids_FirstEntryIsStartPid;
var
  Ancestors: TArray<DWORD>;
begin
  Ancestors := GetAncestorPids(GetCurrentProcessId);
  Assert.IsTrue(Length(Ancestors) >= 1,
    'should have at least the start PID itself');
  Assert.IsTrue(Ancestors[0] = GetCurrentProcessId,
    'first entry must be the start PID (the walk includes self)');
end;

procedure TProcessTreeTests.GetAncestorPids_StopsAtSystemPid;
var
  Ancestors: TArray<DWORD>;
  I: Integer;
begin
  Ancestors := GetAncestorPids(GetCurrentProcessId);
  // No entry should be PID 4 (System) or PID 0 — walk halts before adding them.
  for I := 0 to High(Ancestors) do
  begin
    Assert.IsTrue(Ancestors[I] > 4,
      'ancestor PID must not be the System process (PID 4) or below');
  end;
end;

procedure TProcessTreeTests.GetAncestorPids_NoCycles;
var
  Ancestors: TArray<DWORD>;
  Seen: TList<DWORD>;
  I: Integer;
begin
  // Cycle guard: each PID should appear at most once in the result.
  Ancestors := GetAncestorPids(GetCurrentProcessId);
  Seen := TList<DWORD>.Create;
  try
    for I := 0 to High(Ancestors) do
    begin
      Assert.IsTrue(Seen.IndexOf(Ancestors[I]) < 0,
        'ancestor list must not contain duplicates (cycle detection)');
      Seen.Add(Ancestors[I]);
    end;
  finally
    Seen.Free;
  end;
end;

procedure TProcessTreeTests.GetAncestorPids_BoundedAt20Levels;
var
  Ancestors: TArray<DWORD>;
begin
  Ancestors := GetAncestorPids(GetCurrentProcessId);
  Assert.IsTrue(Length(Ancestors) <= 20,
    'ancestor walk must respect the MaxDepth=20 bound');
end;

procedure TProcessTreeTests.GetAncestorPids_StartPidZero_ReturnsEmpty;
var
  Ancestors: TArray<DWORD>;
begin
  // PID 0 is below the SystemPid=4 cutoff; the loop's `Current > SystemPid`
  // guard exits immediately without adding anything.
  Ancestors := GetAncestorPids(0);
  Assert.IsTrue(Length(Ancestors) = 0,
    'StartPid=0 must yield an empty array');
end;

initialization
  TDUnitX.RegisterTestFixture(TProcessTreeTests);

end.
