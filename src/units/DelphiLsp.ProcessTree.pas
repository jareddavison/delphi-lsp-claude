// Copyright (c) 2026 Jared Davison. Released under the MIT License (see LICENSE).
//
// AI-generated (Claude Code). Review before trusting in production.
//
// Win32 process-tree walking. Critical to the race-free hook ↔ shim
// correlation: hook drops a file per ancestor PID, shim walks its own
// ancestry looking for a match. They share Claude Code's main PID (or
// higher) as a common ancestor — race-free per Claude Code instance.

unit DelphiLsp.ProcessTree;

interface

uses
  Winapi.Windows;

// Win32 doesn't expose a one-call GetParentProcessId. Walk the toolhelp
// snapshot looking for Pid and return its th32ParentProcessID. Returns 0 if
// the snapshot fails or Pid isn't found.
function GetParentOfPid(Pid: DWORD): DWORD;

// Convenience: parent of the current process.
function GetParentProcessId: DWORD;

// Collect process ancestors by walking up via th32ParentProcessID. Returns
// [StartPid, parent, grandparent, ...]. Bounded at 20 levels with cycle
// detection. Stops at PID 4 (Windows System) or PID 0 (orphan / not found).
// In practice Claude Code's process tree is 3-5 levels.
function GetAncestorPids(StartPid: DWORD): TArray<DWORD>;

implementation

uses
  Winapi.TlHelp32,
  System.Generics.Collections;

function GetParentOfPid(Pid: DWORD): DWORD;
var
  Snapshot: THandle;
  Entry: TProcessEntry32W;
begin
  Result := 0;
  Snapshot := CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
  if Snapshot = INVALID_HANDLE_VALUE then Exit;
  try
    FillChar(Entry, SizeOf(Entry), 0);
    Entry.dwSize := SizeOf(Entry);
    if Process32FirstW(Snapshot, Entry) then
    begin
      repeat
        if Entry.th32ProcessID = Pid then
        begin
          Result := Entry.th32ParentProcessID;
          Exit;
        end;
      until not Process32NextW(Snapshot, Entry);
    end;
  finally
    CloseHandle(Snapshot);
  end;
end;

function GetParentProcessId: DWORD;
begin
  Result := GetParentOfPid(GetCurrentProcessId);
end;

function GetAncestorPids(StartPid: DWORD): TArray<DWORD>;
const
  MaxDepth = 20;
  SystemPid = 4;
var
  Acc: TList<DWORD>;
  Current: DWORD;
begin
  Acc := TList<DWORD>.Create;
  try
    Current := StartPid;
    while (Current > SystemPid) and (Acc.Count < MaxDepth) do
    begin
      if Acc.IndexOf(Current) >= 0 then Break; // cycle guard
      Acc.Add(Current);
      Current := GetParentOfPid(Current);
      if Current = 0 then Break;
    end;
    Result := Acc.ToArray;
  finally
    Acc.Free;
  end;
end;

end.
