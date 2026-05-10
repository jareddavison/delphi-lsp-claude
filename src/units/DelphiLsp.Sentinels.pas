// Copyright (c) 2026 Jared Davison. Released under the MIT License (see LICENSE).
//
// AI-generated (Claude Code). Review before trusting in production.
//
// Filesystem primitives the sentinel watcher uses to detect and apply
// the slash-command drop files under <session>/:
//
//   active.txt        — set by /delphi-project; first non-empty line is the
//                       absolute path to the active .delphilsp.json. Read,
//                       not consumed (persistent state across reloads).
//   reload.flag       — set by /delphi-reload; presence triggers a child
//                       recycle, then the file is deleted.
//   shim-reload.flag  — set by /delphi-shim-reload; presence triggers a
//                       process Halt(1), then the file is deleted before
//                       the halt so the next-spawned shim doesn't see it.
//
// Only the read/consume primitives live here; the binding to GSession /
// GActiveProject / SwitchToProject stays in the dpr because that machinery
// reaches into shim-process state.

unit DelphiLsp.Sentinels;

interface

// True if Path exists and at least one non-empty (after Trim) line was found.
// Out param Line is the first such line, trimmed. False on missing file,
// empty file, blank-only file, or read error. Read errors are silent at this
// layer — caller can Diag if it cares.
function ReadFirstNonEmptyTrimmedLine(const Path: string;
  out Line: string): Boolean;

// True if FlagPath existed (a best-effort delete is then attempted; failure
// to delete is silently ignored — caller can re-detect on next sweep). False
// when FlagPath is empty or the file does not exist; the file is not touched
// in the False case. Designed for one-shot 'flag' files: the caller acts on
// True, ignores False.
function ConsumeFlagFile(const FlagPath: string): Boolean;

implementation

uses
  System.SysUtils,
  System.Classes;

function ReadFirstNonEmptyTrimmedLine(const Path: string;
  out Line: string): Boolean;
var
  Lines: TStringList;
  I: Integer;
  Candidate: string;
begin
  Line := '';
  Result := False;
  if Path = '' then Exit;
  if not FileExists(Path) then Exit;
  Lines := TStringList.Create;
  try
    try
      Lines.LoadFromFile(Path, TEncoding.UTF8);
    except
      Exit;
    end;
    for I := 0 to Lines.Count - 1 do
    begin
      Candidate := Trim(Lines[I]);
      if Candidate <> '' then
      begin
        Line := Candidate;
        Result := True;
        Exit;
      end;
    end;
  finally
    Lines.Free;
  end;
end;

function ConsumeFlagFile(const FlagPath: string): Boolean;
begin
  Result := False;
  if FlagPath = '' then Exit;
  if not FileExists(FlagPath) then Exit;
  Result := True;
  try
    DeleteFile(FlagPath);
  except
    // Best-effort delete; if it fails, next sweep will retry. The caller
    // already saw True so will fire its action — at worst we get a duplicate
    // recycle on the next tick.
  end;
end;

end.
