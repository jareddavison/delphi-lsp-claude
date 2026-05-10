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
// + workspace.txt. Returns ('', '') on any failure.
function RegisterSession: TSessionRegistration;

// Lower-level: caller supplies the parent SessionsRoot, the pid to use
// as the dir name, and the cwd to record in workspace.txt. Doesn't
// call GcOrphanSessions or ResolvePluginDataBase — testable against a
// synthetic temp-dir fixture.
function RegisterSessionAt(const SessionsRoot: string; CurrentPid: DWORD;
  const Cwd: string): TSessionRegistration;

// Best-effort recursive delete of the session dir. Empty string is a
// no-op. Failures are swallowed — an orphaned dir is harmless and the
// next shim's GcOrphanSessions will sweep it.
procedure UnregisterSession(const SessionDir: string);

implementation

uses
  System.SysUtils,
  System.IOUtils,
  System.Classes,
  DelphiLsp.Logging,
  DelphiLsp.PluginData,
  DelphiLsp.Gc;

function RegisterSessionAt(const SessionsRoot: string; CurrentPid: DWORD;
  const Cwd: string): TSessionRegistration;
var
  WorkspaceFile: string;
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

function RegisterSession: TSessionRegistration;
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
                              GetCurrentDir);
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

end.
