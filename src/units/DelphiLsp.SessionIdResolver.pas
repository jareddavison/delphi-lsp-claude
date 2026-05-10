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

type
  TSessionIdSource = (
    ssNone,             // nothing resolved
    ssEnv,              // CLAUDE_CODE_SESSION_ID env var
    ssArgv,             // --claude-session-id=<id>
    ssHookAncestor,     // claude-pid/<ancestor-pid>.json
    ssHookByIdScan,     // claude-pid/by-id-*.json + cwd canonical match
    ssProjectsDirScan); // most-recent .jsonl in <projects>/<encoded-cwd>

  TSessionIdResolution = record
    SessionId: string;
    Source: TSessionIdSource;
  end;

// Strip a candidate session id of any unsubstituted manifest placeholder.
// Returns '' if Value is the literal `${CLAUDE_CODE_SESSION_ID}`, contains
// any embedded `${`, or is already empty. Otherwise returns Value
// unchanged.
//
// Background: Claude Code 2.1.x only substitutes the
// CLAUDE_PLUGIN_ROOT/CLAUDE_PLUGIN_DATA/user_config.* whitelist in
// lspServers.<n>.{args,env}. Arbitrary env names (incl. CLAUDE_CODE_SESSION_ID)
// pass through literally. Without this guard the shim accepts the literal
// placeholder as a session id and writes sticky to a bogus filename.
function FilterUnsubstitutedPlaceholder(const Value: string): string;

// Pure decision function — picks the highest-priority non-empty input
// across the discovery sources. Caller has done the I/O for each source
// and passes pre-resolved results. Result.Source identifies which won.
//
// Precedence (top wins):
//   1. FromEnv  (already filtered for placeholders)
//   2. FromArgv (already filtered for placeholders by ParseSessionIdFromArgv)
//   3. FromAncestor — first non-empty hit when caller walked ancestry
//   4. FromByIdScan
//   5. FromProjectsDirScan
function ResolveSessionId(const FromEnv, FromArgv, FromAncestor,
  FromByIdScan, FromProjectsDirScan: string): TSessionIdResolution;

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
  DelphiLsp.Paths,
  DelphiLsp.JsonUtils;

function FilterUnsubstitutedPlaceholder(const Value: string): string;
begin
  Result := Value;
  if Result = '' then Exit;
  if (Pos('${', Result) > 0) or
     (Result = '${CLAUDE_CODE_SESSION_ID}') then
    Result := '';
end;

function ResolveSessionId(const FromEnv, FromArgv, FromAncestor,
  FromByIdScan, FromProjectsDirScan: string): TSessionIdResolution;
begin
  if FromEnv <> '' then
  begin
    Result.SessionId := FromEnv;
    Result.Source := ssEnv;
    Exit;
  end;
  if FromArgv <> '' then
  begin
    Result.SessionId := FromArgv;
    Result.Source := ssArgv;
    Exit;
  end;
  if FromAncestor <> '' then
  begin
    Result.SessionId := FromAncestor;
    Result.Source := ssHookAncestor;
    Exit;
  end;
  if FromByIdScan <> '' then
  begin
    Result.SessionId := FromByIdScan;
    Result.Source := ssHookByIdScan;
    Exit;
  end;
  if FromProjectsDirScan <> '' then
  begin
    Result.SessionId := FromProjectsDirScan;
    Result.Source := ssProjectsDirScan;
    Exit;
  end;
  Result.SessionId := '';
  Result.Source := ssNone;
end;

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
  Obj: TJSONObject;
  IdVal: TJSONValue;
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
  Obj := TryParseJsonObject(Content);
  if Obj = nil then Exit;
  try
    IdVal := Obj.GetValue('session_id');
    if (IdVal <> nil) and (IdVal is TJSONString) then
      Result := TJSONString(IdVal).Value;
  finally
    Obj.Free;
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
  Obj: TJSONObject;
  IdVal, CwdVal: TJSONValue;
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
      Obj := TryParseJsonObject(Content);
      if Obj = nil then Continue;
      try
        IdVal := Obj.GetValue('session_id');
        CwdVal := Obj.GetValue('cwd');
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
        Obj.Free;
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
