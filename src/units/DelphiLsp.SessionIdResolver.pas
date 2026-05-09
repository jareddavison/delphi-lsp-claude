// Copyright (c) 2026 Jared Davison. Released under the MIT License (see LICENSE).
//
// AI-generated (Claude Code). Review before trusting in production.
//
// Functions for discovering Claude Code's session id from inside the LSP
// subprocess. Claude Code 2.1.x doesn't propagate CLAUDE_CODE_SESSION_ID to
// LSP subprocess env and doesn't expand ${CLAUDE_CODE_SESSION_ID} in
// manifest args, so the shim has to find its session id another way. This
// unit provides the three discovery paths:
//
//   1. argv  — `--claude-session-id=<id>` from the manifest. Doesn't
//              currently work (substitution unsupported) but kept for
//              forward compatibility.
//   2. hook drop file — SessionStart hook deposits a JSON file in
//      claude-pid/. Two read forms: by-PID-key direct hit, or by-cwd
//      scan across by-id-*.json files (current default since MinGW bash
//      hooks have $PPID=1).
//   3. projects-dir scan — last resort, parses Claude Code's internal
//      conversation transcript dir layout.
//
// All functions take their inputs explicitly (Cwd, ClaudePidDir,
// ProjectsRoot) for testability against synthetic dirs.

unit DelphiLsp.SessionIdResolver;

interface

// Look for `--claude-session-id=<id>` in argv. Returns '' if absent or if
// the value still contains an unsubstituted ${...} placeholder. Reads
// ParamStr/ParamCount directly — caller doesn't pass argv.
function ParseSessionIdFromArgv: string;

// Read a session_id from claude-pid/<Key>.json. Returns '' if no file or
// no session_id field. ClaudePidDir is the parent dir
// (typically <plugin-data>/claude-pid).
function ReadSessionIdFromHookFile(const ClaudePidDir, Key: string): string;

// Scan claude-pid/by-id-*.json files for one whose `cwd` field canonically
// matches Cwd. Picks the most-recently-modified match. Returns '' if no
// match. Used when PID-keyed lookup misses (e.g. MinGW bash $PPID=1).
function ResolveSessionIdViaHookFiles(
  const ClaudePidDir, Cwd: string): string;

// Last-resort: scan ProjectsRoot/<encoded-cwd>/*.jsonl for the most
// recently-modified file. The basename (sans `.jsonl`) is the session id.
// EncodedCwd transforms `D:\Documents\TestDproj` into
// `D--Documents-TestDproj` (Claude Code's storage convention).
//
// Coupled to Claude Code's internal storage layout — re-verify if it
// stops working.
function DiscoverSessionIdFromProjectsDir(
  const ProjectsRoot, Cwd: string): string;

implementation

uses
  System.SysUtils,
  System.IOUtils,
  System.JSON,
  DelphiLsp.Logging,
  DelphiLsp.Paths;

function ParseSessionIdFromArgv: string;
const
  Prefix = '--claude-session-id=';
var
  I: Integer;
  Arg: string;
begin
  Result := '';
  for I := 1 to ParamCount do
  begin
    Arg := ParamStr(I);
    if (Length(Arg) > Length(Prefix)) and
       SameText(Copy(Arg, 1, Length(Prefix)), Prefix) then
    begin
      Result := Copy(Arg, Length(Prefix) + 1, MaxInt);
      // Guard against unsubstituted ${...} placeholder (Claude Code didn't
      // expand it — older client, env var missing, etc.).
      if (Pos('${', Result) > 0) or (Result = '${CLAUDE_CODE_SESSION_ID}') then
        Result := '';
      Exit;
    end;
  end;
end;

function ReadSessionIdFromHookFile(const ClaudePidDir, Key: string): string;
var
  Path, Content: string;
  Root, IdVal: TJSONValue;
begin
  Result := '';
  if (ClaudePidDir = '') or (Key = '') then Exit;
  Path := IncludeTrailingPathDelimiter(ClaudePidDir) + Key + '.json';
  if not FileExists(Path) then Exit;
  try
    Content := TFile.ReadAllText(Path, TEncoding.UTF8);
  except
    on E: Exception do
    begin
      Diag('Hook-file read failed: ' + E.Message);
      Exit;
    end;
  end;
  Root := nil;
  try
    try
      Root := TJSONObject.ParseJSONValue(Content);
    except
      on E: Exception do
      begin
        Diag('Hook-file parse failed: ' + E.Message);
        Exit;
      end;
    end;
    if not (Root is TJSONObject) then Exit;
    IdVal := TJSONObject(Root).GetValue('session_id');
    if (IdVal <> nil) and (IdVal is TJSONString) then
      Result := TJSONString(IdVal).Value;
  finally
    Root.Free;
  end;
end;

function ResolveSessionIdViaHookFiles(
  const ClaudePidDir, Cwd: string): string;
const
  Pattern = 'by-id-*.json';
var
  FullPath, Content, EntryCwd, EntrySid, TargetCwd: string;
  SR: TSearchRec;
  BestSid: string;
  BestAge: TDateTime;
  Root, IdVal, CwdVal: TJSONValue;
begin
  Result := '';
  if (ClaudePidDir = '') or not DirectoryExists(ClaudePidDir) then Exit;

  TargetCwd := CanonicalizeCwd(Cwd);
  if TargetCwd = '' then Exit;

  BestSid := '';
  BestAge := 0;
  if FindFirst(IncludeTrailingPathDelimiter(ClaudePidDir) + Pattern,
               faAnyFile, SR) = 0 then
  try
    repeat
      FullPath := IncludeTrailingPathDelimiter(ClaudePidDir) + SR.Name;
      try
        Content := TFile.ReadAllText(FullPath, TEncoding.UTF8);
      except
        on E: Exception do
        begin
          Diag('Hook by-id read failed for ' + SR.Name + ': ' + E.Message);
          Continue;
        end;
      end;
      Root := nil;
      try
        try
          Root := TJSONObject.ParseJSONValue(Content);
        except
          Continue;
        end;
        if not (Root is TJSONObject) then Continue;
        IdVal := TJSONObject(Root).GetValue('session_id');
        CwdVal := TJSONObject(Root).GetValue('cwd');
        if (IdVal = nil) or (CwdVal = nil) then Continue;
        EntrySid := IdVal.Value;
        EntryCwd := CwdVal.Value;
        if CanonicalizeCwd(EntryCwd) <> TargetCwd then Continue;
        if (BestSid = '') or (SR.TimeStamp > BestAge) then
        begin
          BestSid := EntrySid;
          BestAge := SR.TimeStamp;
        end;
      finally
        Root.Free;
      end;
    until FindNext(SR) <> 0;
  finally
    FindClose(SR);
  end;

  if BestSid <> '' then
    Diag('Hook by-id scan: matched session ' + BestSid + ' for cwd ' + Cwd);
  Result := BestSid;
end;

function DiscoverSessionIdFromProjectsDir(
  const ProjectsRoot, Cwd: string): string;
const
  Suffix = '.jsonl';
var
  EncodedCwd, ProjectDir, BestName: string;
  SR: TSearchRec;
  BestAge: TDateTime;
begin
  Result := '';
  if (ProjectsRoot = '') or not DirectoryExists(ProjectsRoot) then Exit;

  EncodedCwd := StringReplace(Cwd, ':', '-', [rfReplaceAll]);
  EncodedCwd := StringReplace(EncodedCwd, '\', '-', [rfReplaceAll]);
  EncodedCwd := StringReplace(EncodedCwd, '/', '-', [rfReplaceAll]);
  ProjectDir := IncludeTrailingPathDelimiter(ProjectsRoot) + EncodedCwd;
  if not DirectoryExists(ProjectDir) then
  begin
    Diag('Projects-dir scan: no dir for ' + EncodedCwd);
    Exit;
  end;

  BestName := '';
  BestAge := 0;
  if FindFirst(IncludeTrailingPathDelimiter(ProjectDir) + '*' + Suffix,
               faAnyFile, SR) = 0 then
  try
    repeat
      if (BestName = '') or (SR.TimeStamp > BestAge) then
      begin
        BestName := SR.Name;
        BestAge := SR.TimeStamp;
      end;
    until FindNext(SR) <> 0;
  finally
    FindClose(SR);
  end;

  if BestName <> '' then
  begin
    Result := Copy(BestName, 1, Length(BestName) - Length(Suffix));
    Diag(Format('Projects-dir scan: most-recent %s in %s -> session id %s',
      [BestName, ProjectDir, Result]));
  end
  else
    Diag('Projects-dir scan: no .jsonl in ' + ProjectDir);
end;

end.
