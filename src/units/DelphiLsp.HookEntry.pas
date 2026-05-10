// Copyright (c) 2026 Jared Davison. Released under the MIT License (see LICENSE).
//
// AI-generated (Claude Code). Review before trusting in production.
//
// Entry points for the dual-mode shim binary's hook / utility argv modes.
// When the shim is invoked with --hook-session-start, --hook-session-end,
// or --find-project-for, the main dispatcher hands off to one of the
// procedures here and Halts. None of them return.
//
// Each procedure reads its own stdin (where applicable) and writes to
// stdout / stderr / the plugin-data dir. They share Diag for logging and
// the already-extracted helpers in DelphiLsp.* — no shim-process global
// state is touched, so this unit is a clean lift from the dpr.
//
// The pure JSON-parsing helpers (ParseSessionStartPayload,
// ParseSessionEndPayload) are exposed so tests can cover them directly.

unit DelphiLsp.HookEntry;

interface

uses
  System.Generics.Collections;

// Argv-mode entry: SessionStart hook. Reads JSON from stdin, writes
// claude-pid/<ancestor>.json + by-id-<session>.json correlation files,
// and emits a multi-candidate prompt to stdout when applicable.
procedure RunSessionStartHook;

// Argv-mode entry: SessionEnd hook. Cleans up the per-session
// correlation drop files written by SessionStart. Leaves the
// session-state/<session>.json sticky bindings alone.
procedure RunSessionEndHook;

// Argv-mode entry: --find-project-for <path>. Prints the unique
// owning .delphilsp.json to stdout (exit 0), or lists matches /
// reports none on stderr (exit 1). Halts internally.
procedure RunFindProjectForMode;

// Build and emit the multi-candidate picker prompt. Public so the
// SessionStart hook can call it; the body uses DCU mtimes to score
// candidates by recent build activity.
procedure EmitMultiCandidatePromptWithDcuActivity(Candidates: TList<string>);

// Pure helpers (exposed for tests).

// Parses the SessionStart hook stdin payload. Returns True if Json is a
// valid JSON object (whether or not the fields are present). On True,
// SessionId and Cwd are filled when the corresponding fields exist;
// otherwise they stay ''. On False (parse failure or non-object root),
// both stay ''.
function ParseSessionStartPayload(const Json: string;
  out SessionId, Cwd: string): Boolean;

// Same for the SessionEnd hook stdin payload (session_id + reason).
function ParseSessionEndPayload(const Json: string;
  out SessionId, Reason: string): Boolean;

implementation

uses
  Winapi.Windows,
  System.SysUtils,
  System.Classes,
  System.DateUtils,
  System.IOUtils,
  System.JSON,
  System.Hash,
  System.Generics.Defaults,
  DelphiLsp.Logging,
  DelphiLsp.Paths,
  DelphiLsp.Walkers,
  DelphiLsp.ProcessTree,
  DelphiLsp.DprojParse,
  DelphiLsp.PluginData,
  DelphiLsp.IO,
  DelphiLsp.StickyState,
  DelphiLsp.JsonUtils;

function ParseSessionStartPayload(const Json: string;
  out SessionId, Cwd: string): Boolean;
var
  Obj: TJSONObject;
  IdVal, CwdVal: TJSONValue;
begin
  SessionId := '';
  Cwd := '';
  Result := False;
  Obj := TryParseJsonObject(Json);
  if Obj = nil then Exit;
  try
    IdVal := Obj.GetValue('session_id');
    CwdVal := Obj.GetValue('cwd');
    if IdVal <> nil then SessionId := IdVal.Value;
    if CwdVal <> nil then Cwd := CwdVal.Value;
    Result := True;
  finally
    Obj.Free;
  end;
end;

function ParseSessionEndPayload(const Json: string;
  out SessionId, Reason: string): Boolean;
var
  Obj: TJSONObject;
  IdVal, ReasonVal: TJSONValue;
begin
  SessionId := '';
  Reason := '';
  Result := False;
  Obj := TryParseJsonObject(Json);
  if Obj = nil then Exit;
  try
    IdVal := Obj.GetValue('session_id');
    ReasonVal := Obj.GetValue('reason');
    if IdVal <> nil then SessionId := IdVal.Value;
    if ReasonVal <> nil then Reason := ReasonVal.Value;
    Result := True;
  finally
    Obj.Free;
  end;
end;

procedure EmitMultiCandidatePromptWithDcuActivity(Candidates: TList<string>);
const
  RecencyDays = 30;
type
  TCandidateScore = record
    Path: string;
    DcuDir: string;
    RecentDcus: Integer;
  end;
var
  Scores: array of TCandidateScore;
  I: Integer;
  Cutoff: TDateTime;
  TotalRecent: Integer;
  Annotation: string;
begin
  Cutoff := IncDay(Now, -RecencyDays);
  SetLength(Scores, Candidates.Count);
  TotalRecent := 0;
  for I := 0 to Candidates.Count - 1 do
  begin
    Scores[I].Path := Candidates[I];
    Scores[I].DcuDir := ResolveDcuOutputDir(Candidates[I]);
    Scores[I].RecentDcus := CountRecentDcus(Scores[I].DcuDir, Cutoff);
    Inc(TotalRecent, Scores[I].RecentDcus);
    Diag(Format('Hook: candidate %s dcuDir=%s recentDcus=%d',
      [ExtractFileName(Candidates[I]), Scores[I].DcuDir, Scores[I].RecentDcus]));
  end;

  // Sort by RecentDcus desc (stable: ties keep filesystem order).
  TArray.Sort<TCandidateScore>(Scores, TComparer<TCandidateScore>.Construct(
    function(const A, B: TCandidateScore): Integer
    begin
      Result := B.RecentDcus - A.RecentDcus;
    end));

  Writeln(Format(
    'The DelphiLSP plugin found %d .delphilsp.json projects in this workspace and no sticky project pick exists for this session yet. The LSP shim will run syntactic-only until a project is loaded.',
    [Candidates.Count]));
  Writeln('');
  if TotalRecent > 0 then
    Writeln(Format(
      'Recent activity (.dcu files modified in the last %d days under each project''s build output dir) is shown alongside each candidate — a strong signal for which project the user has been actively building. The compiler resolves implicit uses-clause references too, so this catches more than just files explicitly listed in the .dproj.',
      [RecencyDays]))
  else
    Writeln(Format(
      'No project has any .dcu file modified in the last %d days — no recent build activity to use as a hint. List below is unsorted.',
      [RecencyDays]));
  Writeln('');
  Writeln('Use AskUserQuestion to ask the user which project to load, then call /delphi-project <name>. Available projects (sorted by recent build activity desc):');
  Writeln('');

  for I := 0 to High(Scores) do
  begin
    if TotalRecent > 0 then
      Annotation := Format(' — %d .dcu(s) compiled in last %d days',
        [Scores[I].RecentDcus, RecencyDays])
    else
      Annotation := '';
    Writeln(Format('  - %s%s',
      [ExtractFileName(Scores[I].Path), Annotation]));
  end;
end;

procedure RunSessionStartHook;
var
  PayloadBytes: TBytes;
  Payload, SessionId, Cwd, EntryJson: string;
  Base, PidDir, PpidPath, ByIdPath: string;
  StickyFile, Content, CwdHash: string;
  Ppid: DWORD;
  HasSticky, Parsed: Boolean;
  Acc: TList<string>;
  I: Integer;
  EntryObj: TJSONObject;
  Ancestors: TArray<DWORD>;
begin
  PayloadBytes := ReadAllStdin;
  Payload := TEncoding.UTF8.GetString(PayloadBytes);
  Diag('Hook: payload bytes=' + IntToStr(Length(PayloadBytes)));

  Parsed := ParseSessionStartPayload(Payload, SessionId, Cwd);
  if not Parsed then
    Diag('Hook payload parse failed');

  if SessionId = '' then
  begin
    Diag('Hook: no session_id in payload, bailing out');
    Exit;
  end;
  if Cwd = '' then Cwd := GetCurrentDir;

  Ppid := GetParentProcessId;
  Diag(Format('Hook: pid=%d ppid=%d session=%s cwd=%s',
    [GetCurrentProcessId, Ppid, SessionId, Cwd]));

  Base := ResolvePluginDataBase;
  if Base = '' then
  begin
    Diag('Hook: no plugin-data base; cannot persist');
    Exit;
  end;

  PidDir := ClaudePidDir(Base);
  try
    ForceDirectories(PidDir);
  except
    on E: Exception do
    begin
      Diag('Hook: ForceDirectories failed: ' + E.Message);
      Exit;
    end;
  end;

  // Build the entry JSON used in both drop files.
  EntryObj := TJSONObject.Create;
  try
    EntryObj.AddPair('session_id', SessionId);
    EntryObj.AddPair('cwd', Cwd);
    EntryObj.AddPair('hook_pid', TJSONNumber.Create(GetCurrentProcessId));
    EntryObj.AddPair('hook_ppid', TJSONNumber.Create(Ppid));
    EntryObj.AddPair('timestamp',
      FormatDateTime('yyyy-mm-dd"T"hh:nn:ss"Z"', Now));
    EntryJson := EntryObj.ToJSON;
  finally
    EntryObj.Free;
  end;

  // Write a file for each ancestor PID. The shim walks its own ancestry
  // looking for any matching file — they share Claude Code's main PID (or
  // higher) as a common ancestor, even though hook PPID and shim PPID
  // differ (Claude Code spawns them from different subprocess parents).
  // Writing one file per ancestor instead of just PPID makes the lookup
  // race-free regardless of which intermediate subprocess spawned each.
  Ancestors := GetAncestorPids(GetCurrentProcessId);
  for I := 0 to High(Ancestors) do
  begin
    PpidPath := IncludeTrailingPathDelimiter(PidDir) +
                IntToStr(Ancestors[I]) + '.json';
    WriteFileAtomic(PpidPath, EntryJson);
  end;

  // Fallback: by-id-<session>.json keyed by session id. The shim's by-id+cwd
  // scan uses this if no ancestor file matches (shouldn't happen, defensive).
  ByIdPath := IncludeTrailingPathDelimiter(PidDir) +
              'by-id-' + SessionId + '.json';
  WriteFileAtomic(ByIdPath, EntryJson);

  Diag(Format('Hook: wrote ancestor files for %d ancestors + by-id file',
    [Length(Ancestors)]));
  for I := 0 to High(Ancestors) do
    Diag(Format('  ancestor[%d]=%d', [I, Ancestors[I]]));

  // Multi-candidate prompt: only if no sticky AND >1 .delphilsp.json files.
  StickyFile := BuildStickyStatePath(Base, SessionId);
  CwdHash := ComputeCwdHash(Cwd);
  HasSticky := False;
  if TryReadAllText(StickyFile, 'Hook sticky-check failed', Content) then
    HasSticky := Pos('"' + CwdHash + '"', Content) > 0;

  if HasSticky then
  begin
    Diag('Hook: sticky exists for this cwd, staying silent');
    Exit;
  end;

  Acc := TList<string>.Create;
  try
    CollectFilesByExt(Cwd, '.delphilsp.json', 0, Acc);
    Diag(Format('Hook: sticky=no candidates=%d', [Acc.Count]));
    if Acc.Count > 1 then
    begin
      // Compute recent-DCU count per candidate. DCU mtimes indicate when a
      // unit was last compiled into THIS project — catches both explicit
      // and implicit (uses-clause) ownership. Sort candidates by count desc
      // so Claude's AskUserQuestion can recommend the most-actively-built one.
      EmitMultiCandidatePromptWithDcuActivity(Acc);
    end;
  finally
    Acc.Free;
  end;
end;

procedure RunFindProjectForMode;
var
  Query: string;
  Owners: TArray<string>;
  I: Integer;
begin
  if ParamCount < 2 then
  begin
    Writeln(ErrOutput, 'Usage: delphi-lsp-shim.exe --find-project-for <path-to-pas-file>');
    Halt(1);
  end;
  Query := ParamStr(2);
  if not TPath.IsPathRooted(Query) then
    Query := TPath.Combine(GetCurrentDir, Query);
  Query := TPath.GetFullPath(Query);
  Diag(Format('FindProjectFor: query=%s cwd=%s', [Query, GetCurrentDir]));

  Owners := FindOwningDelphilspJsons(GetCurrentDir, Query);
  Diag(Format('FindProjectFor: %d match(es)', [Length(Owners)]));

  if Length(Owners) = 1 then
  begin
    Writeln(Owners[0]);
    Halt(0);
  end;
  if Length(Owners) > 1 then
  begin
    Writeln(ErrOutput, Format('Ambiguous: %d projects reference %s:',
      [Length(Owners), Query]));
    for I := 0 to High(Owners) do
      Writeln(ErrOutput, '  ' + Owners[I]);
  end
  else
    Writeln(ErrOutput, 'No project references ' + Query);
  Halt(1);
end;

procedure RunSessionEndHook;
var
  PayloadBytes: TBytes;
  Payload, SessionId, Reason: string;
  Base, PidDir, FullPath, FileSessionId, Content: string;
  Ancestors: TArray<DWORD>;
  AncIdx: Integer;
  Removed: Integer;
  Obj: TJSONObject;
  IdVal: TJSONValue;
  Parsed: Boolean;
begin
  PayloadBytes := ReadAllStdin;
  Payload := TEncoding.UTF8.GetString(PayloadBytes);
  Diag('SessionEnd: payload bytes=' + IntToStr(Length(PayloadBytes)));

  Parsed := ParseSessionEndPayload(Payload, SessionId, Reason);
  if not Parsed then
    Diag('SessionEnd parse failed');

  if SessionId = '' then
  begin
    Diag('SessionEnd: no session_id in payload, bailing out');
    Exit;
  end;
  Diag(Format('SessionEnd: session=%s reason=%s', [SessionId, Reason]));

  Base := ResolvePluginDataBase;
  if Base = '' then Exit;
  PidDir := ClaudePidDir(Base);
  if not DirectoryExists(PidDir) then Exit;

  Removed := 0;

  // Delete the by-id drop file — keyed directly by our session.
  FullPath := IncludeTrailingPathDelimiter(PidDir) + 'by-id-' + SessionId + '.json';
  if FileExists(FullPath) then
  begin
    if DeleteFile(PChar(FullPath)) then Inc(Removed)
    else Diag(Format('SessionEnd by-id delete failed: gle=%d', [GetLastError]));
  end;

  // Walk our own ancestors and delete each PID-keyed drop file whose
  // recorded session_id matches ours. The session_id check is defensive:
  // ensures we never accidentally delete another concurrent session's
  // ancestor files even if PIDs happened to overlap (shouldn't, but cheap
  // to verify).
  Ancestors := GetAncestorPids(GetCurrentProcessId);
  for AncIdx := 0 to High(Ancestors) do
  begin
    FullPath := IncludeTrailingPathDelimiter(PidDir) +
                IntToStr(Ancestors[AncIdx]) + '.json';
    if not TryReadAllText(FullPath, 'SessionEnd ancestor-file read failed',
                          Content) then Continue;
    FileSessionId := '';
    Obj := TryParseJsonObject(Content);
    if Obj <> nil then
    try
      IdVal := Obj.GetValue('session_id');
      if IdVal <> nil then FileSessionId := IdVal.Value;
    finally
      Obj.Free;
    end;
    if FileSessionId <> SessionId then Continue;
    if DeleteFile(PChar(FullPath)) then
      Inc(Removed)
    else
      Diag(Format('SessionEnd ancestor delete failed: %d (gle=%d)',
        [Ancestors[AncIdx], GetLastError]));
  end;

  Diag(Format('SessionEnd: removed %d correlation file(s)', [Removed]));
end;

end.
