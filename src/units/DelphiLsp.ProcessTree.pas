// Copyright (c) 2026 Jared Davison. Released under the MIT License (see LICENSE).
//
// AI-generated (Claude Code). Review before trusting in production.
//
// Win32 process-tree walking with a one-time self-ancestry cache.
//
// The shim's relationship to its ancestors is fixed for its lifetime:
// once we have a snapshot of the chain from the shim up to claude.exe,
// that chain is stable. If claude.exe died, the shim would die with it
// (Claude Code kills its LSP children at session end), so a cached
// chain can never refer to a dead-and-recycled claude.exe PID.
//
// Implementation: lazy-build a TProcessSnapshot the first time any
// ancestor function is called for GetCurrentProcessId, walk it, store
// the result in a unit-level cache. Every subsequent self-ancestry
// query — GetParentProcessId, GetAncestorPids(self),
// GetAncestorChain(self), FindAncestorByName(self, ...) — reads from
// the cache. One CreateToolhelp32Snapshot per shim lifetime.
//
// Lookups against other PIDs (e.g. the SessionEnd hook verifying that
// a correlation file's recorded session_id matches the right PID)
// still take a fresh snapshot, since arbitrary PIDs aren't stable.
// IsPidAlive uses OpenProcess and never touches the snapshot.

unit DelphiLsp.ProcessTree;

interface

uses
  Winapi.Windows;

type
  // One entry in a walked ancestor chain. Name is the executable basename
  // as toolhelp reports it in TProcessEntry32W.szExeFile (no path).
  TProcessNode = record
    Pid: DWORD;
    ParentPid: DWORD;
    Name: string;
  end;

// Win32 doesn't expose a one-call GetParentProcessId. Returns the
// parent PID of Pid, or 0 if not found / snapshot failed. For
// Pid = GetCurrentProcessId the answer is served from the self-ancestry
// cache; for any other Pid a fresh snapshot is taken.
function GetParentOfPid(Pid: DWORD): DWORD;

// Convenience: parent of the current process. Served from cache.
function GetParentProcessId: DWORD;

// Collect process ancestors by walking up via th32ParentProcessID. Returns
// [StartPid, parent, grandparent, ...]. Bounded at 20 levels with cycle
// detection. Stops at PID 4 (Windows System) or PID 0 (orphan / not found).
// For StartPid = GetCurrentProcessId the answer is cached.
function GetAncestorPids(StartPid: DWORD): TArray<DWORD>;

// Same walk as GetAncestorPids, but each entry carries the PID, parent
// PID, and executable basename. For StartPid = GetCurrentProcessId the
// answer is cached (one snapshot per shim lifetime).
function GetAncestorChain(StartPid: DWORD): TArray<TProcessNode>;

// First ancestor (inclusive of StartPid) whose executable basename
// matches Name case-insensitively. Returns 0 if no match within the
// MaxDepth=20 bound, or if Name is empty. For StartPid =
// GetCurrentProcessId the underlying chain is cached.
function FindAncestorByName(StartPid: DWORD; const Name: string): DWORD;

// True iff a process with this PID currently exists. Uses Win32
// OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION) — available since Vista,
// works against any user's process (including elevated ones) without
// needing access rights to its address space. Never touches the snapshot
// cache.
function IsPidAlive(Pid: DWORD): Boolean;

// Test seam: how many TProcessSnapshot instances have been built since
// the unit loaded. Tests use this to verify cache-hit behavior (counter
// stays flat across repeated self-ancestry queries). Not for production
// use.
function GetSnapshotBuildCount: Integer;

// Test seam: drop the cached self-ancestry chain so the next self query
// rebuilds. Production code never needs this — the cache is permanent
// for the shim's lifetime by design.
procedure ResetSelfChainCache;

implementation

uses
  Winapi.TlHelp32,
  System.SysUtils,
  System.Generics.Collections;

const
  MaxDepth = 20;
  SystemPid = 4;
  // Available since Vista; not in older Winapi.Windows headers.
  PROCESS_QUERY_LIMITED_INFORMATION = $1000;

type
  // In-memory view of one toolhelp snapshot. Built once per fresh walk
  // (or once per shim lifetime when serving self-ancestry queries),
  // queried O(1) per ancestor level.
  TProcessSnapshot = class
  strict private
    FPidToParent: TDictionary<DWORD, DWORD>;
    FPidToName: TDictionary<DWORD, string>;
  public
    constructor Create;
    destructor Destroy; override;
    function TryGetParent(Pid: DWORD; out Parent: DWORD): Boolean;
    function TryGetName(Pid: DWORD; out Name: string): Boolean;
  end;

var
  // Self-ancestry cache. Empty until the first self-targeting call; once
  // populated, stays for the lifetime of the unit (i.e. shim process).
  GCachedSelfChain: TArray<TProcessNode>;
  GCachedSelfPid: DWORD = 0;

  // Test-only instrumentation. Counts TProcessSnapshot.Create calls.
  GSnapshotBuildCount: Integer = 0;

constructor TProcessSnapshot.Create;
var
  H: THandle;
  Entry: TProcessEntry32W;
begin
  inherited Create;
  Inc(GSnapshotBuildCount);
  FPidToParent := TDictionary<DWORD, DWORD>.Create;
  FPidToName := TDictionary<DWORD, string>.Create;
  H := CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
  if H = INVALID_HANDLE_VALUE then Exit;
  try
    FillChar(Entry, SizeOf(Entry), 0);
    Entry.dwSize := SizeOf(Entry);
    if Process32FirstW(H, Entry) then
    begin
      repeat
        FPidToParent.AddOrSetValue(
          Entry.th32ProcessID, Entry.th32ParentProcessID);
        FPidToName.AddOrSetValue(
          Entry.th32ProcessID, string(Entry.szExeFile));
      until not Process32NextW(H, Entry);
    end;
  finally
    CloseHandle(H);
  end;
end;

destructor TProcessSnapshot.Destroy;
begin
  FPidToParent.Free;
  FPidToName.Free;
  inherited;
end;

function TProcessSnapshot.TryGetParent(Pid: DWORD;
  out Parent: DWORD): Boolean;
begin
  Result := FPidToParent.TryGetValue(Pid, Parent);
end;

function TProcessSnapshot.TryGetName(Pid: DWORD;
  out Name: string): Boolean;
begin
  Result := FPidToName.TryGetValue(Pid, Name);
end;

// Walk ancestors against a pre-built snapshot. Matches the historical
// GetAncestorPids behavior precisely: every PID added to the chain is
// the one we just visited (so even a StartPid not in the snapshot
// produces a single-entry chain with ParentPid=0 — same as before, when
// GetParentOfPid would have returned 0 on the dict miss and the next
// iteration's `Current > SystemPid` guard would have exited the loop).
function WalkAncestors(const Snap: TProcessSnapshot;
  StartPid: DWORD): TArray<TProcessNode>;
var
  Acc: TList<TProcessNode>;
  Seen: TList<DWORD>;
  Current, Parent: DWORD;
  Name: string;
  Node: TProcessNode;
begin
  Acc := TList<TProcessNode>.Create;
  Seen := TList<DWORD>.Create;
  try
    Current := StartPid;
    while (Current > SystemPid) and (Acc.Count < MaxDepth) do
    begin
      if Seen.IndexOf(Current) >= 0 then Break; // cycle guard
      Seen.Add(Current);

      if not Snap.TryGetName(Current, Name) then Name := '';
      if not Snap.TryGetParent(Current, Parent) then Parent := 0;
      Node.Pid := Current;
      Node.ParentPid := Parent;
      Node.Name := Name;
      Acc.Add(Node);

      Current := Parent;
      if Current = 0 then Break;
    end;
    Result := Acc.ToArray;
  finally
    Acc.Free;
    Seen.Free;
  end;
end;

// Lazy-initialize the self-ancestry cache. Idempotent. The PID check
// guards the (theoretical) fork case: if the unit somehow ends up in a
// process with a different PID, the cache rebuilds for the new self
// rather than serving stale data.
procedure EnsureSelfChainCached;
var
  SelfPid: DWORD;
  Snap: TProcessSnapshot;
begin
  SelfPid := GetCurrentProcessId;
  if (GCachedSelfPid = SelfPid) and (Length(GCachedSelfChain) > 0) then Exit;
  Snap := TProcessSnapshot.Create;
  try
    GCachedSelfChain := WalkAncestors(Snap, SelfPid);
    GCachedSelfPid := SelfPid;
  finally
    Snap.Free;
  end;
end;

procedure ResetSelfChainCache;
begin
  GCachedSelfChain := nil;
  GCachedSelfPid := 0;
end;

function GetSnapshotBuildCount: Integer;
begin
  Result := GSnapshotBuildCount;
end;

function GetAncestorChain(StartPid: DWORD): TArray<TProcessNode>;
var
  Snap: TProcessSnapshot;
begin
  if StartPid = GetCurrentProcessId then
  begin
    EnsureSelfChainCached;
    Result := GCachedSelfChain;
    Exit;
  end;
  Snap := TProcessSnapshot.Create;
  try
    Result := WalkAncestors(Snap, StartPid);
  finally
    Snap.Free;
  end;
end;

function GetAncestorPids(StartPid: DWORD): TArray<DWORD>;
var
  Chain: TArray<TProcessNode>;
  I: Integer;
begin
  Chain := GetAncestorChain(StartPid);
  SetLength(Result, Length(Chain));
  for I := 0 to High(Chain) do
    Result[I] := Chain[I].Pid;
end;

function GetParentOfPid(Pid: DWORD): DWORD;
var
  Snap: TProcessSnapshot;
  Parent: DWORD;
begin
  Result := 0;
  // Serve self-targeted lookups from the cache. The first entry of the
  // cached chain is GetCurrentProcessId; its ParentPid is the answer.
  if Pid = GetCurrentProcessId then
  begin
    EnsureSelfChainCached;
    if Length(GCachedSelfChain) > 0 then
      Result := GCachedSelfChain[0].ParentPid;
    Exit;
  end;
  Snap := TProcessSnapshot.Create;
  try
    if Snap.TryGetParent(Pid, Parent) then
      Result := Parent;
  finally
    Snap.Free;
  end;
end;

function GetParentProcessId: DWORD;
begin
  Result := GetParentOfPid(GetCurrentProcessId);
end;

function FindAncestorByName(StartPid: DWORD; const Name: string): DWORD;
var
  Snap: TProcessSnapshot;
  Chain: TArray<TProcessNode>;
  I: Integer;
begin
  Result := 0;
  if Name = '' then Exit;
  if StartPid = GetCurrentProcessId then
  begin
    EnsureSelfChainCached;
    Chain := GCachedSelfChain;
  end
  else
  begin
    Snap := TProcessSnapshot.Create;
    try
      Chain := WalkAncestors(Snap, StartPid);
    finally
      Snap.Free;
    end;
  end;
  for I := 0 to High(Chain) do
    if SameText(Chain[I].Name, Name) then
    begin
      Result := Chain[I].Pid;
      Exit;
    end;
end;

function IsPidAlive(Pid: DWORD): Boolean;
var
  H: THandle;
begin
  if Pid = 0 then Exit(False);
  H := OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, False, Pid);
  if H = 0 then Exit(False);
  CloseHandle(H);
  Result := True;
end;

end.
