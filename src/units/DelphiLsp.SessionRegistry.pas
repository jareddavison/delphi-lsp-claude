// Copyright (c) 2026 Jared Davison. Released under the MIT License (see LICENSE).
//
// AI-generated (Claude Code). Review based on the AI-generated note before
// trusting in production.
//
// Per-shim-process session directory under <plugin-data>/sessions/<pid>/.
// Contents:
//   workspace.txt     — single line: the cwd the shim was spawned in.
//                       Used by slash commands to find the right shim
//                       (each instance has a different cwd).
//   active.txt        — written by /delphi-project, read by the shim's
//                       sentinel watcher.
//   reload.flag       — /delphi-reload sentinel, consumed by the shim.
//   shim-reload.flag  — /delphi-shim-reload sentinel; presence triggers
//                       a process Halt(1).
//
// The session dir is created at startup and best-effort deleted on
// shutdown. If a previous shim crashed before cleanup, GcOrphanSessions
// (DelphiLsp.Gc) sweeps the leftover dirs by-PID liveness check.

unit DelphiLsp.SessionRegistry;

interface

uses
  Winapi.Windows;

type
  // Result of a register attempt. SessionDir is '' when registration
  // failed (no plugin-data base, or the FS operations failed). The
  // caller checks for the empty string before relying on the paths.
  TSessionRegistration = record
    SessionDir: string;
    ActiveSentinelPath: string;
  end;

// High-level: resolve <plugin-data> via ResolvePluginDataBase, run
// GcOrphanSessions on the sessions root, then create the per-pid dir
// + workspace.txt (+ claude-session.txt if ClaudeSessionId is given).
// Returns ('', '') on any failure. ClaudeSessionId disambiguates
// concurrent Claude Code sessions in the same cwd — argv-mode slash
// commands match on it.
function RegisterSession(const ClaudeSessionId: string): TSessionRegistration;

// Lower-level: caller supplies the parent SessionsRoot, the pid to use
// as the dir name, the cwd to record in workspace.txt, and the Claude
// session id to record in claude-session.txt (empty = skip the file).
// Doesn't call GcOrphanSessions or ResolvePluginDataBase — testable
// against a synthetic temp-dir fixture.
function RegisterSessionAt(const SessionsRoot: string; CurrentPid: DWORD;
  const Cwd, ClaudeSessionId: string): TSessionRegistration;

// Best-effort recursive delete of the session dir. Empty string is a
// no-op. Failures are swallowed — an orphaned dir is harmless and the
// next shim's GcOrphanSessions will sweep it.
procedure UnregisterSession(const SessionDir: string);

type
  // Snapshot of one registered shim session, populated by
  // FindShimSessionsForCwdAt. The Alive field flags zombies — callers
  // signaling reload should skip dead PIDs. ClaudeSessionId is read
  // from claude-session.txt; '' for older shim spawns that pre-date
  // the disambiguation file.
  TShimSession = record
    Pid: DWORD;
    Dir: string;             // <SessionsRoot>/<Pid>/
    ActiveProject: string;   // contents of active.txt, '' if missing
    RuntimeOverride: string; // contents of runtime.txt, '' if missing
    ClaudeSessionId: string; // contents of claude-session.txt, '' if missing
    Alive: Boolean;
  end;

// Walk SessionsRoot and return one TShimSession per pid-named subdir
// whose workspace.txt canonicalises to the same path as Cwd. Used by
// the argv-mode slash-command handlers (--status, --shim-reload,
// --set-project, etc.) to locate the shims they address.
//
// Inputs explicit for testability against synthetic fixtures; the
// production caller passes SessionsDir(ResolvePluginDataBase) and
// GetCurrentDir.
function FindShimSessionsForCwdAt(const SessionsRoot, Cwd: string): TArray<TShimSession>;

// High-level wrapper: resolves <plugin-data>/sessions and the current
// working directory, then calls FindShimSessionsForCwdAt. Returns an
// empty array when no plugin-data base is reachable.
function FindShimSessionsForCwd: TArray<TShimSession>;

implementation

uses
  System.SysUtils,
  System.IOUtils,
  System.Classes,
  System.Generics.Collections,
  DelphiLsp.Logging,
  DelphiLsp.PluginData,
  DelphiLsp.Gc,
  DelphiLsp.Paths,
  DelphiLsp.ProcessTree,
  DelphiLsp.Sentinels;

function RegisterSessionAt(const SessionsRoot: string; CurrentPid: DWORD;
  const Cwd, ClaudeSessionId: string): TSessionRegistration;
var
  WorkspaceFile, ClaudeSessionFile: string;
  WS: TStringList;
begin
  Result.SessionDir := '';
  Result.ActiveSentinelPath := '';
  if SessionsRoot = '' then Exit;
  Result.SessionDir := IncludeTrailingPathDelimiter(SessionsRoot) +
                       IntToStr(CurrentPid);
  Result.ActiveSentinelPath := IncludeTrailingPathDelimiter(Result.SessionDir) +
                               'active.txt';
  try
    if not ForceDirectories(Result.SessionDir) then
    begin
      Diag('ForceDirectories failed: ' + Result.SessionDir);
      Result.SessionDir := '';
      Result.ActiveSentinelPath := '';
      Exit;
    end;
    WorkspaceFile := IncludeTrailingPathDelimiter(Result.SessionDir) +
                     'workspace.txt';
    WS := TStringList.Create;
    try
      WS.Add(Cwd);
      WS.SaveToFile(WorkspaceFile, TEncoding.UTF8);
    finally
      WS.Free;
    end;
    if ClaudeSessionId <> '' then
    begin
      ClaudeSessionFile := IncludeTrailingPathDelimiter(Result.SessionDir) +
                          'claude-session.txt';
      WS := TStringList.Create;
      try
        WS.Add(ClaudeSessionId);
        WS.SaveToFile(ClaudeSessionFile, TEncoding.UTF8);
      finally
        WS.Free;
      end;
    end;
    Diag('Registered session at ' + Result.SessionDir);
  except
    on E: Exception do
    begin
      Diag('Session registration failed: ' + E.Message);
      Result.SessionDir := '';
      Result.ActiveSentinelPath := '';
    end;
  end;
end;

function RegisterSession(const ClaudeSessionId: string): TSessionRegistration;
var
  Base, SessionsRoot: string;
begin
  Result.SessionDir := '';
  Result.ActiveSentinelPath := '';
  Base := ResolvePluginDataBase;
  if Base = '' then
  begin
    Diag('No usable data dir; running without per-session sentinel');
    Exit;
  end;
  SessionsRoot := SessionsDir(Base);
  GcOrphanSessions(SessionsRoot, GetCurrentProcessId);
  Result := RegisterSessionAt(SessionsRoot, GetCurrentProcessId,
                              GetCurrentDir, ClaudeSessionId);
end;

procedure UnregisterSession(const SessionDir: string);
begin
  if SessionDir = '' then Exit;
  try
    TDirectory.Delete(SessionDir, True);
  except
    // Best-effort; orphaned dirs are harmless and GcOrphanSessions
    // sweeps them on the next shim's startup.
  end;
end;

function FindShimSessionsForCwdAt(const SessionsRoot, Cwd: string): TArray<TShimSession>;
var
  SR: TSearchRec;
  TargetCwd, FirstLine, Dir: string;
  Pid: UInt32;
  S: TShimSession;
  Acc: TList<TShimSession>;
begin
  Result := nil;
  Diag(Format('FindShimSessionsForCwdAt: root=%s cwd=%s', [SessionsRoot, Cwd]));
  if (SessionsRoot = '') or not DirectoryExists(SessionsRoot) then
  begin
    Diag('FindShimSessionsForCwdAt: root missing or empty - exit');
    Exit;
  end;
  TargetCwd := CanonicalizeCwd(Cwd);
  Diag('FindShimSessionsForCwdAt: target canonical=' + TargetCwd);
  if TargetCwd = '' then Exit;
  Acc := TList<TShimSession>.Create;
  try
    if FindFirst(IncludeTrailingPathDelimiter(SessionsRoot) + '*',
                 faDirectory, SR) = 0 then
    try
      repeat
        if (SR.Name = '.') or (SR.Name = '..') then Continue;
        if (SR.Attr and faDirectory) = 0 then Continue;
        if not TryStrToUInt(SR.Name, Pid) then Continue;
        Dir := IncludeTrailingPathDelimiter(SessionsRoot) + SR.Name;
        if not ReadFirstNonEmptyTrimmedLine(
                 IncludeTrailingPathDelimiter(Dir) + 'workspace.txt',
                 FirstLine) then
        begin
          Diag('  pid=' + SR.Name + ': no workspace.txt - skip');
          Continue;
        end;
        Diag(Format('  pid=%s workspace=%s canonical=%s',
          [SR.Name, FirstLine, CanonicalizeCwd(FirstLine)]));
        if CanonicalizeCwd(FirstLine) <> TargetCwd then
        begin
          Diag('  pid=' + SR.Name + ': canonical mismatch - skip');
          Continue;
        end;
        S.Pid := Pid;
        S.Dir := Dir;
        S.Alive := IsPidAlive(Pid);
        S.ActiveProject := '';
        ReadFirstNonEmptyTrimmedLine(
          IncludeTrailingPathDelimiter(Dir) + 'active.txt', S.ActiveProject);
        S.RuntimeOverride := '';
        ReadFirstNonEmptyTrimmedLine(
          IncludeTrailingPathDelimiter(Dir) + 'runtime.txt', S.RuntimeOverride);
        S.ClaudeSessionId := '';
        ReadFirstNonEmptyTrimmedLine(
          IncludeTrailingPathDelimiter(Dir) + 'claude-session.txt',
          S.ClaudeSessionId);
        Acc.Add(S);
      until FindNext(SR) <> 0;
    finally
      FindClose(SR);
    end;
    Result := Acc.ToArray;
  finally
    Acc.Free;
  end;
end;

function FindShimSessionsForCwd: TArray<TShimSession>;
var
  Base: string;
begin
  Result := nil;
  Base := ResolvePluginDataBase;
  if Base = '' then Exit;
  Result := FindShimSessionsForCwdAt(SessionsDir(Base), GetCurrentDir);
end;

end.
