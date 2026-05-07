// Copyright (c) 2026 Jared Davison. Released under the MIT License (see LICENSE).
//
// AI-generated (Claude Code). Review before trusting in production.
//
// Diagnostic logger. Driven by the DELPHI_LSP_SHIM_LOG env var: when set
// to a writable file path, every Diag call appends one line. When unset
// (the default), Diag is a no-op so the shim stays silent.
//
// Format: `[YYYY-MM-DD HH:MM:SS.zzz] <message>` — easy to grep.
//
// Each Diag call opens the log, appends, and closes — there's no buffering.
// Trades throughput for crash-safety; if the shim dies, nothing is lost.

unit DelphiLsp.Logging;

interface

// Set the log file path. Called once at startup with the value of the
// DELPHI_LSP_SHIM_LOG env var. Pass '' to disable (default).
procedure SetLogPath(const Path: string);

// Append a line to the log file (timestamped). No-op when no log path is set.
procedure Diag(const Msg: string);

implementation

uses
  System.SysUtils;

var
  LogPath: string = '';

procedure SetLogPath(const Path: string);
begin
  LogPath := Path;
end;

procedure Diag(const Msg: string);
var
  F: TextFile;
  Line: string;
begin
  if LogPath = '' then Exit;
  Line := Format('[%s] %s', [FormatDateTime('yyyy-mm-dd hh:nn:ss.zzz', Now), Msg]);
  try
    AssignFile(F, LogPath);
    if FileExists(LogPath) then Append(F) else Rewrite(F);
    try
      Writeln(F, Line);
    finally
      CloseFile(F);
    end;
  except
    // best effort: silently swallow disk errors so logging can never crash the shim
  end;
end;

end.
