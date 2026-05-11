// Copyright (c) 2026 Jared Davison. Released under the MIT License (see LICENSE).
//
// AI-generated (Claude Code). Review before trusting in production.
//
// Garbage collection of stale plugin-data files. Runs at shim startup so
// the persistent state directories don't accumulate forever:
//
//   sessions/<dead-pid>/             — orphan dirs from crashed/killed shims
//   session-state/<dead-session>.json — sticky bindings for unresumable sessions
//   claude-pid/<dead-pid>.json        — hook ancestor drops with dead PIDs
//   claude-pid/by-id-<dead-session>.json — hook session drops for unresumable sessions
//
// All functions take their inputs explicitly (paths, current-self IDs) so
// they're testable against synthetic temp dirs without touching real
// plugin-data. The shim wires them together via ResolvePluginDataBase /
// ResolveProjectsRoot / GClaudeSessionId at the call site.

unit DelphiLsp.Gc;

interface

uses
  Winapi.Windows;

// Walk PID-named subdirs under SessionsRoot; remove any whose PID is no
// longer running. SelfPid is excluded so the current shim's dir isn't
// nuked. Used to clean up after crashed/killed shims.
procedure GcOrphanSessions(const SessionsRoot: string; SelfPid: DWORD);

// Sweep SessionStateDir/*.json — each filename is a Claude session id.
// Skip the current session (CurrentSessionId). Delete any whose .jsonl
// is no longer in ProjectsRoot (= session is unresumable). Conservative;
// keeps anything that might still be resumed.
procedure GcStaleSessionState(const SessionStateDir, ProjectsRoot,
  CurrentSessionId: string);

// Sweep ClaudePidDir/*.json. Two file shapes:
//   <pid>.json            — delete if PID is dead (PID-reuse safety)
//   by-id-<session>.json  — delete if .jsonl is gone (session unresumable)
procedure GcStaleClaudePidFiles(const ClaudePidDir, ProjectsRoot: string);

implementation

uses
  System.SysUtils,
  System.IOUtils,
  DelphiLsp.Logging,
  DelphiLsp.PluginData,
  DelphiLsp.ProcessTree;

const
  ByIdPrefix = 'by-id-';

procedure GcOrphanSessions(const SessionsRoot: string; SelfPid: DWORD);
var
  SR: TSearchRec;
  Pid: UInt32;
  ChildDir: string;
  Removed: Integer;
begin
  Removed := 0;
  if not DirectoryExists(SessionsRoot) then Exit;
  if FindFirst(IncludeTrailingPathDelimiter(SessionsRoot) + '*', faDirectory, SR) <> 0 then
    Exit;
  try
    repeat
      if (SR.Name = '.') or (SR.Name = '..') then Continue;
      if (SR.Attr and faDirectory) = 0 then Continue;
      if not TryStrToUInt(SR.Name, Pid) then Continue;
      if Pid = SelfPid then Continue;
      if IsPidAlive(Pid) then Continue;
      // Process gone; reap the dir.
      ChildDir := IncludeTrailingPathDelimiter(SessionsRoot) + SR.Name;
      try
        TDirectory.Delete(ChildDir, True);
        Inc(Removed);
      except
        on E: Exception do
          Diag(Format('Orphan GC: failed to delete %s: %s', [ChildDir, E.Message]));
      end;
    until FindNext(SR) <> 0;
  finally
    FindClose(SR);
  end;
  if Removed > 0 then
    Diag(Format('Orphan GC: removed %d stale session dir(s)', [Removed]));
end;

procedure GcStaleSessionState(const SessionStateDir, ProjectsRoot,
  CurrentSessionId: string);
var
  FullPath, SessionId: string;
  SR: TSearchRec;
  Removed: Integer;
begin
  if (SessionStateDir = '') or not DirectoryExists(SessionStateDir) then Exit;
  Removed := 0;
  if FindFirst(IncludeTrailingPathDelimiter(SessionStateDir) + '*.json',
               faAnyFile, SR) = 0 then
  try
    repeat
      if (SR.Attr and faDirectory) <> 0 then Continue;
      SessionId := ChangeFileExt(SR.Name, '');
      if SameText(SessionId, CurrentSessionId) then Continue;
      if IsClaudeSessionAlive(ProjectsRoot, SessionId) then Continue;
      FullPath := IncludeTrailingPathDelimiter(SessionStateDir) + SR.Name;
      if DeleteFile(PChar(FullPath)) then
        Inc(Removed)
      else
        Diag(Format('GC sticky delete failed: %s (gle=%d)', [SR.Name, GetLastError]));
    until FindNext(SR) <> 0;
  finally
    FindClose(SR);
  end;
  if Removed > 0 then
    Diag(Format('GC: removed %d stale session-state file(s)', [Removed]));
end;

procedure GcStaleClaudePidFiles(const ClaudePidDir, ProjectsRoot: string);
var
  FullPath, BaseName, SessionId: string;
  SR: TSearchRec;
  Pid: UInt32;
  Removed: Integer;
begin
  if (ClaudePidDir = '') or not DirectoryExists(ClaudePidDir) then Exit;
  Removed := 0;
  if FindFirst(IncludeTrailingPathDelimiter(ClaudePidDir) + '*.json',
               faAnyFile, SR) = 0 then
  try
    repeat
      if (SR.Attr and faDirectory) <> 0 then Continue;
      BaseName := ChangeFileExt(SR.Name, '');
      FullPath := IncludeTrailingPathDelimiter(ClaudePidDir) + SR.Name;
      if (Length(BaseName) > Length(ByIdPrefix)) and
         SameText(Copy(BaseName, 1, Length(ByIdPrefix)), ByIdPrefix) then
      begin
        SessionId := Copy(BaseName, Length(ByIdPrefix) + 1, MaxInt);
        if IsClaudeSessionAlive(ProjectsRoot, SessionId) then Continue;
        if DeleteFile(PChar(FullPath)) then
          Inc(Removed)
        else
          Diag(Format('GC by-id delete failed: %s (gle=%d)', [SR.Name, GetLastError]));
      end
      else if TryStrToUInt(BaseName, Pid) then
      begin
        if IsPidAlive(Pid) then Continue;
        if DeleteFile(PChar(FullPath)) then
          Inc(Removed)
        else
          Diag(Format('GC pid-keyed delete failed: %s (gle=%d)', [SR.Name, GetLastError]));
      end;
    until FindNext(SR) <> 0;
  finally
    FindClose(SR);
  end;
  if Removed > 0 then
    Diag(Format('GC: removed %d stale claude-pid file(s)', [Removed]));
end;

end.
