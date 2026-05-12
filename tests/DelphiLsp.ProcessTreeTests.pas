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
    [Test] procedure GetAncestorChain_FirstEntryIsStartPid;
    [Test] procedure GetAncestorChain_FirstEntryNameIsCurrentExe;
    [Test] procedure GetAncestorChain_ParentLinksAreConsistent;
    [Test] procedure GetAncestorChain_StartPidZero_ReturnsEmpty;
    [Test] procedure FindAncestorByName_FindsCurrentProcessByExeName;
    [Test] procedure FindAncestorByName_IsCaseInsensitive;
    [Test] procedure FindAncestorByName_EmptyName_ReturnsZero;
    [Test] procedure FindAncestorByName_NoMatch_ReturnsZero;
    [Test] procedure SelfChainCache_OneSnapshotForRepeatedSelfQueries;
    [Test] procedure SelfChainCache_ResetForcesRebuild;
    [Test] procedure SelfChainCache_OtherPidLookupTakesFreshSnapshot;
  end;

implementation

uses
  Winapi.Windows,
  System.SysUtils,
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

procedure TProcessTreeTests.GetAncestorChain_FirstEntryIsStartPid;
var
  Chain: TArray<TProcessNode>;
begin
  Chain := GetAncestorChain(GetCurrentProcessId);
  Assert.IsTrue(Length(Chain) >= 1,
    'chain should include the start PID itself');
  Assert.IsTrue(Chain[0].Pid = GetCurrentProcessId,
    'first entry must be the start PID');
end;

procedure TProcessTreeTests.GetAncestorChain_FirstEntryNameIsCurrentExe;
var
  Chain: TArray<TProcessNode>;
  ExpectedName: string;
begin
  // The first chain entry corresponds to the current process; its Name
  // should be the test runner's exe basename as reported by toolhelp.
  Chain := GetAncestorChain(GetCurrentProcessId);
  ExpectedName := ExtractFileName(ParamStr(0));
  Assert.IsTrue(SameText(Chain[0].Name, ExpectedName),
    Format('expected first-entry name "%s", got "%s"',
      [ExpectedName, Chain[0].Name]));
end;

procedure TProcessTreeTests.GetAncestorChain_ParentLinksAreConsistent;
var
  Chain: TArray<TProcessNode>;
  I: Integer;
begin
  // Each node's ParentPid must equal the next node's Pid in the walked
  // chain (the walk follows ParentPid each step). Last node's ParentPid
  // is whatever toolhelp reported and may or may not have a successor;
  // skip it.
  Chain := GetAncestorChain(GetCurrentProcessId);
  for I := 0 to High(Chain) - 1 do
    Assert.IsTrue(Chain[I].ParentPid = Chain[I + 1].Pid,
      Format('Chain[%d].ParentPid (%d) must equal Chain[%d].Pid (%d)',
        [I, Chain[I].ParentPid, I + 1, Chain[I + 1].Pid]));
end;

procedure TProcessTreeTests.GetAncestorChain_StartPidZero_ReturnsEmpty;
var
  Chain: TArray<TProcessNode>;
begin
  // Same SystemPid=4 floor as GetAncestorPids — PID 0 short-circuits to
  // an empty chain.
  Chain := GetAncestorChain(0);
  Assert.IsTrue(Length(Chain) = 0,
    'StartPid=0 must yield an empty chain');
end;

procedure TProcessTreeTests.FindAncestorByName_FindsCurrentProcessByExeName;
var
  ExeName: string;
  Pid: DWORD;
begin
  // The walk is inclusive of StartPid, so searching for the current
  // process's own exe name should resolve back to its PID.
  ExeName := ExtractFileName(ParamStr(0));
  Pid := FindAncestorByName(GetCurrentProcessId, ExeName);
  Assert.IsTrue(Pid = GetCurrentProcessId,
    Format('expected PID %d for self lookup by name "%s", got %d',
      [GetCurrentProcessId, ExeName, Pid]));
end;

procedure TProcessTreeTests.FindAncestorByName_IsCaseInsensitive;
var
  ExeName: string;
  Pid: DWORD;
begin
  // Toolhelp reports szExeFile with mixed case; resolver callers will
  // search using literals like 'claude.exe'. Make the match case-blind.
  ExeName := UpperCase(ExtractFileName(ParamStr(0)));
  Pid := FindAncestorByName(GetCurrentProcessId, ExeName);
  Assert.IsTrue(Pid = GetCurrentProcessId,
    'uppercased name should still match');
end;

procedure TProcessTreeTests.FindAncestorByName_EmptyName_ReturnsZero;
begin
  Assert.IsTrue(FindAncestorByName(GetCurrentProcessId, '') = 0,
    'empty name should yield 0 (defensive against caller bugs)');
end;

procedure TProcessTreeTests.FindAncestorByName_NoMatch_ReturnsZero;
begin
  // No process should ever be named this. Guards against the function
  // accidentally returning the start PID on miss.
  Assert.IsTrue(
    FindAncestorByName(GetCurrentProcessId,
      'definitely-not-a-real-process-name.xyz') = 0,
    'bogus name should yield 0');
end;

procedure TProcessTreeTests.SelfChainCache_OneSnapshotForRepeatedSelfQueries;
var
  Before, AfterFirst, AfterMany: Integer;
  ExeName: string;
begin
  // Core perf contract: the shim takes exactly one toolhelp snapshot for
  // its entire lifetime to identify its ancestry, regardless of how many
  // self-targeted ancestor queries happen. Reset to a known state, run
  // the four self-query call sites, assert the snapshot counter went up
  // by exactly one across all of them.
  ResetSelfChainCache;
  Before := GetSnapshotBuildCount;

  // Trigger the cache build.
  GetAncestorChain(GetCurrentProcessId);
  AfterFirst := GetSnapshotBuildCount;
  Assert.AreEqual(Before + 1, AfterFirst,
    'first self query should build exactly one snapshot');

  // All subsequent self-targeted queries must use the cache.
  GetAncestorChain(GetCurrentProcessId);
  GetAncestorPids(GetCurrentProcessId);
  GetParentOfPid(GetCurrentProcessId);
  GetParentProcessId;
  ExeName := ExtractFileName(ParamStr(0));
  FindAncestorByName(GetCurrentProcessId, ExeName);

  AfterMany := GetSnapshotBuildCount;
  Assert.AreEqual(AfterFirst, AfterMany,
    'repeated self queries must not build additional snapshots');
end;

procedure TProcessTreeTests.SelfChainCache_ResetForcesRebuild;
var
  Before, AfterFirst, AfterReset: Integer;
begin
  // ResetSelfChainCache exists for tests that want a fresh walk. Verify
  // it actually invalidates the cache (the next self query rebuilds).
  ResetSelfChainCache;
  Before := GetSnapshotBuildCount;

  GetAncestorChain(GetCurrentProcessId);
  AfterFirst := GetSnapshotBuildCount;
  Assert.AreEqual(Before + 1, AfterFirst, 'first call builds one snapshot');

  ResetSelfChainCache;
  GetAncestorChain(GetCurrentProcessId);
  AfterReset := GetSnapshotBuildCount;
  Assert.AreEqual(AfterFirst + 1, AfterReset,
    'reset + next self query should build exactly one more snapshot');
end;

procedure TProcessTreeTests.SelfChainCache_OtherPidLookupTakesFreshSnapshot;
var
  ParentPid: DWORD;
  Before, AfterSelf, AfterOther: Integer;
begin
  // Non-self lookups intentionally bypass the cache (arbitrary PIDs
  // aren't stable). Prime the self cache, then query a different PID
  // and verify the counter increments.
  ResetSelfChainCache;

  GetAncestorChain(GetCurrentProcessId);
  AfterSelf := GetSnapshotBuildCount;

  // Pick a real other PID — our own parent will do.
  ParentPid := GetParentProcessId;
  if ParentPid = 0 then Exit; // unusual; skip rather than fail.

  Before := GetSnapshotBuildCount;
  GetParentOfPid(ParentPid);
  AfterOther := GetSnapshotBuildCount;
  Assert.AreEqual(Before + 1, AfterOther,
    'non-self lookup should take a fresh snapshot');
  Assert.IsTrue(AfterOther > AfterSelf,
    'non-self lookup must not be served from the self cache');
end;

initialization
  TDUnitX.RegisterTestFixture(TProcessTreeTests);

end.
