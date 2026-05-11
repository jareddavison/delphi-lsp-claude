// Copyright (c) 2026 Jared Davison. Released under the MIT License (see LICENSE).
//
// AI-generated (Claude Code). Review before trusting in production.
//
// Argv-mode handlers backing the slash commands. Each command does the
// work the slash-command markdown used to instruct the AI to do via
// model-generated bash — finding shim session dirs for the current cwd,
// resolving project paths, atomically writing sentinel files. Moving
// this into the shim binary means the slash command markdown can be a
// single deterministic invocation:
//
//   ${CLAUDE_PLUGIN_ROOT}/bin/delphi-lsp-shim.exe --status
//   ${CLAUDE_PLUGIN_ROOT}/bin/delphi-lsp-shim.exe --shim-reload
//   ${CLAUDE_PLUGIN_ROOT}/bin/delphi-lsp-shim.exe --reload
//   ${CLAUDE_PLUGIN_ROOT}/bin/delphi-lsp-shim.exe --set-project <arg>
//   ${CLAUDE_PLUGIN_ROOT}/bin/delphi-lsp-shim.exe --set-runtime <arg>
//   ${CLAUDE_PLUGIN_ROOT}/bin/delphi-lsp-shim.exe --clear-runtime
//
// Smaller models (e.g. Claude Haiku) on machines with restrictive bash
// implementations were crashing on the previously-instructed bash
// pipelines before the shim ever got signalled.
//
// Output is plain human-readable text on stdout (errors on stderr).
// ExitCode is set; the dpr dispatcher Halts after the handler returns.

unit DelphiLsp.CliCommands;

interface

procedure RunStatusCommand;
procedure RunShimReloadCommand;
procedure RunReloadCommand;
procedure RunSetProjectCommand(const ArgValue: string);
procedure RunSetRuntimeCommand(const ArgValue: string);
procedure RunClearRuntimeCommand;

// Pure: given a user-supplied argument (path or name) and a cwd, return
// the absolute path of a matching .delphilsp.json or '' on no match.
// Resolution rules (first match wins):
//   1. Absolute path that exists — return as-is.
//   2. Relative path under cwd that exists and ends in .delphilsp.json —
//      return absolute form.
//   3. Strip a .dproj/.dpr/.dpk/.delphilsp.json suffix from the arg to
//      get a base name; recursively scan cwd for files whose basename
//      contains the base name (case-insensitive) and ends in
//      .delphilsp.json. Pick the shallowest path (tied on depth: alpha).
function ResolveDelphilspJsonArg(const ArgValue, Cwd: string): string;

implementation

uses
  Winapi.Windows,
  System.SysUtils,
  System.IOUtils,
  System.Generics.Collections,
  System.Generics.Defaults,
  DelphiLsp.IO,
  DelphiLsp.SessionRegistry,
  DelphiLsp.SessionIdResolver,
  DelphiLsp.Walkers;

const
  ShimReloadFlag = 'shim-reload.flag';
  ReloadFlag = 'reload.flag';
  ActiveFile = 'active.txt';
  RuntimeFile = 'runtime.txt';

function WriteSentinelAtomic(const Dir, Name, Content: string): Boolean;
var
  Tmp, Target: string;
begin
  Target := IncludeTrailingPathDelimiter(Dir) + Name;
  Tmp := Target + '.tmp';
  try
    TFile.WriteAllText(Tmp, Content, TEncoding.UTF8);
  except
    Exit(False);
  end;
  Result := MoveFileEx(PChar(Tmp), PChar(Target), MOVEFILE_REPLACE_EXISTING);
end;

function StripKnownExtension(const Name: string): string;
const
  Exts: array[0..3] of string = ('.delphilsp.json', '.dproj', '.dpk', '.dpr');
var
  Lower, Ext: string;
  I: Integer;
begin
  Result := Name;
  Lower := LowerCase(Name);
  for I := Low(Exts) to High(Exts) do
  begin
    Ext := Exts[I];
    if (Length(Lower) > Length(Ext)) and
       (Copy(Lower, Length(Lower) - Length(Ext) + 1, Length(Ext)) = Ext) then
    begin
      Result := Copy(Name, 1, Length(Name) - Length(Ext));
      Exit;
    end;
  end;
end;

function ResolveDelphilspJsonArg(const ArgValue, Cwd: string): string;
var
  Candidate, Base, BaseLower, Lower: string;
  Acc: TList<string>;
  Best: string;
  BestDepth: Integer;
  I, Depth: Integer;
begin
  Result := '';
  if ArgValue = '' then Exit;

  // 1. Absolute path that exists.
  if TPath.IsPathRooted(ArgValue) and FileExists(ArgValue) and
     SameText(ExtractFileExt(ArgValue), '.json') then
    Exit(ArgValue);

  // 2. Relative path under cwd, must end in .delphilsp.json.
  if not TPath.IsPathRooted(ArgValue) then
  begin
    Candidate := TPath.Combine(Cwd, ArgValue);
    Candidate := TPath.GetFullPath(Candidate);
    Lower := LowerCase(Candidate);
    if FileExists(Candidate) and
       (Copy(Lower, Length(Lower) - Length('.delphilsp.json') + 1,
             Length('.delphilsp.json')) = '.delphilsp.json') then
      Exit(Candidate);
  end;

  // 3. Name match: strip known extensions, scan workspace for
  // *<base>*.delphilsp.json (case-insensitive), pick shallowest.
  Base := StripKnownExtension(ExtractFileName(ArgValue));
  if Base = '' then Exit;
  BaseLower := LowerCase(Base);
  Acc := TList<string>.Create;
  try
    CollectFilesByExt(Cwd, '.delphilsp.json', 0, Acc);
    Best := '';
    BestDepth := MaxInt;
    for I := 0 to Acc.Count - 1 do
    begin
      Lower := LowerCase(ExtractFileName(Acc[I]));
      if Pos(BaseLower, Lower) = 0 then Continue;
      Depth := Length(Acc[I].Split([PathDelim]));
      if (Depth < BestDepth) or
         ((Depth = BestDepth) and (CompareStr(Acc[I], Best) < 0)) then
      begin
        Best := Acc[I];
        BestDepth := Depth;
      end;
    end;
    Result := Best;
  finally
    Acc.Free;
  end;
end;

procedure ReportNoShim;
begin
  Writeln('No shim running for this workspace yet.');
  Writeln('Make any LSP query (hover, goToDefinition, etc.) on a .pas/.dpr file');
  Writeln('to spawn one. Once running, slash commands will find it.');
end;

// Filter the cwd-matching shims down to those owned by the current
// Claude Code instance (matching claude-session.txt). Two shims that
// share a cwd but belong to different Claude Code sessions must not
// interfere with each other.
//
// Returns OurId via out param so the caller can log it. If OurId is
// empty (env/argv/hooks all failed to resolve a session id), the
// function returns the input unfiltered AND sets Ambiguous = True,
// letting write-mode handlers refuse to touch anything they can't
// confidently claim.
function FilterByOwnClaudeSession(const Sessions: TArray<TShimSession>;
  out OurId: string; out Ambiguous: Boolean): TArray<TShimSession>;
var
  S: TShimSession;
  Acc: TList<TShimSession>;
begin
  OurId := ResolveCurrentClaudeSessionId;
  Ambiguous := OurId = '';
  if Ambiguous then Exit(Sessions);
  Acc := TList<TShimSession>.Create;
  try
    for S in Sessions do
      if S.ClaudeSessionId = OurId then
        Acc.Add(S);
    Result := Acc.ToArray;
  finally
    Acc.Free;
  end;
end;

procedure RunStatusCommand;
var
  AllSessions: TArray<TShimSession>;
  S: TShimSession;
  Acc: TList<string>;
  I, LiveCount: Integer;
  Liveness, OwnMarker, OurId: string;
begin
  AllSessions := FindShimSessionsForCwd;
  OurId := ResolveCurrentClaudeSessionId;
  LiveCount := 0;
  for S in AllSessions do
    if S.Alive then Inc(LiveCount);

  Writeln(Format('Workspace: %s', [GetCurrentDir]));
  if OurId <> '' then
    Writeln('My Claude session: ' + OurId)
  else
    Writeln('My Claude session: <could not resolve>');
  Writeln('');
  if Length(AllSessions) = 0 then
    Writeln('Shims: none registered for this workspace.')
  else
  begin
    Writeln(Format('Shims for this workspace (%d total, %d alive):',
      [Length(AllSessions), LiveCount]));
    for S in AllSessions do
    begin
      if S.Alive then Liveness := '[alive]'
      else Liveness := '[dead - will be GC''d]';
      if (OurId <> '') and (S.ClaudeSessionId = OurId) then
        OwnMarker := ' [MINE]'
      else
        OwnMarker := '';
      Writeln(Format('  PID %d %s%s', [S.Pid, Liveness, OwnMarker]));
      if S.ClaudeSessionId = '' then
        Writeln('    claude session: (unknown - older shim)')
      else
        Writeln('    claude session: ' + S.ClaudeSessionId);
      if S.ActiveProject = '' then
        Writeln('    active project: (none)')
      else
        Writeln('    active project: ' + S.ActiveProject);
      if S.RuntimeOverride <> '' then
        Writeln('    runtime override: ' + S.RuntimeOverride);
    end;
  end;

  Acc := TList<string>.Create;
  try
    CollectFilesByExt(GetCurrentDir, '.delphilsp.json', 0, Acc);
    Writeln('');
    if Acc.Count = 0 then
      Writeln('Available .delphilsp.json files: (none found in workspace)')
    else
    begin
      Writeln(Format('Available .delphilsp.json files (%d):', [Acc.Count]));
      for I := 0 to Acc.Count - 1 do
        Writeln('  - ' + Acc[I]);
    end;
  finally
    Acc.Free;
  end;

  if LiveCount = 0 then
  begin
    Writeln('');
    Writeln('Hint: no live shim. Make any LSP query (hover, goToDefinition,');
    Writeln('etc.) on a .pas/.dpr file to spawn one. The shim picks the active');
    Writeln('project from sticky bindings on its first start; /delphi-project');
    Writeln('overrides afterwards.');
  end;
end;

// Common abort message when the current Claude session id can't be
// resolved — write-mode handlers refuse to touch other Claude
// instances' shims.
procedure AbortAmbiguous(const Op: string);
begin
  Writeln(ErrOutput, Format(
    'Refusing to %s: could not resolve current Claude Code session id.', [Op]));
  Writeln(ErrOutput, 'Other Claude Code sessions may have shims in the same workspace');
  Writeln(ErrOutput, 'and the shim cannot tell which one is yours.');
  ExitCode := 2;
end;

procedure SignalLiveShims(const FlagName, OkMsg, NoneMsg, OpName: string);
var
  AllSessions, MySessions: TArray<TShimSession>;
  S: TShimSession;
  OurId: string;
  Ambiguous: Boolean;
  Signaled: Integer;
begin
  AllSessions := FindShimSessionsForCwd;
  MySessions := FilterByOwnClaudeSession(AllSessions, OurId, Ambiguous);
  if Ambiguous and (Length(AllSessions) > 0) then
  begin
    AbortAmbiguous(OpName);
    Exit;
  end;
  Signaled := 0;
  for S in MySessions do
  begin
    if not S.Alive then Continue;
    if WriteSentinelAtomic(S.Dir, FlagName, 'signal') then
      Inc(Signaled);
  end;
  if Signaled = 0 then
    Writeln(NoneMsg)
  else
    Writeln(Format(OkMsg, [Signaled]));
end;

procedure RunShimReloadCommand;
begin
  SignalLiveShims(ShimReloadFlag,
    'Signaled %d shim(s) to exit. Next LSP query will spawn a fresh one.',
    'No live shim to reload. The next LSP query will spawn one from the ' +
    'current binary on disk.',
    'reload shim');
end;

procedure RunReloadCommand;
begin
  SignalLiveShims(ReloadFlag,
    'Signaled %d shim(s) to recycle their DelphiLSP child.',
    'No live shim to reload — nothing to recycle.',
    'recycle DelphiLSP child');
end;

procedure RunSetProjectCommand(const ArgValue: string);
var
  Resolved, OurId: string;
  AllSessions, MySessions: TArray<TShimSession>;
  S: TShimSession;
  Updated: Integer;
  Ambiguous: Boolean;
begin
  if ArgValue = '' then
  begin
    Writeln(ErrOutput, 'Usage: delphi-lsp-shim.exe --set-project <path-or-name>');
    ExitCode := 1;
    Exit;
  end;

  Resolved := ResolveDelphilspJsonArg(ArgValue, GetCurrentDir);
  if Resolved = '' then
  begin
    Writeln(ErrOutput, 'Could not resolve to a .delphilsp.json: ' + ArgValue);
    Writeln(ErrOutput, '');
    Writeln(ErrOutput, 'Try one of:');
    Writeln(ErrOutput, '  - absolute path to a .delphilsp.json');
    Writeln(ErrOutput, '  - relative path to a .delphilsp.json (under cwd)');
    Writeln(ErrOutput, '  - project name (matches *<name>*.delphilsp.json)');
    Writeln(ErrOutput, '');
    Writeln(ErrOutput, 'Run --status to list available projects.');
    ExitCode := 1;
    Exit;
  end;

  AllSessions := FindShimSessionsForCwd;
  MySessions := FilterByOwnClaudeSession(AllSessions, OurId, Ambiguous);
  if Ambiguous and (Length(AllSessions) > 0) then
  begin
    AbortAmbiguous('set active project');
    Exit;
  end;

  Updated := 0;
  for S in MySessions do
  begin
    if not S.Alive then Continue;
    if WriteSentinelAtomic(S.Dir, ActiveFile, Resolved) then
      Inc(Updated);
  end;

  Writeln('Resolved: ' + Resolved);
  if Updated = 0 then
  begin
    Writeln('');
    Writeln('No live shim yet — pick will apply when one spawns.');
    Writeln('(For now, kick off any LSP query to spawn a shim. After that,');
    Writeln(' re-run --set-project so it picks up the override.)');
  end
  else
    Writeln(Format('Active project sentinel written to %d shim(s).', [Updated]));
end;

procedure RunSetRuntimeCommand(const ArgValue: string);
var
  Trimmed, OurId: string;
  AllSessions, MySessions: TArray<TShimSession>;
  S: TShimSession;
  Updated: Integer;
  Ambiguous: Boolean;
begin
  Trimmed := Trim(ArgValue);
  if Trimmed = '' then
  begin
    Writeln(ErrOutput, 'Usage: delphi-lsp-shim.exe --set-runtime <bds-version|abs-path>');
    Writeln(ErrOutput, '  Examples: --set-runtime 37.0');
    Writeln(ErrOutput, '            --set-runtime "C:\Program Files (x86)\Embarcadero\Studio\37.0\bin\DelphiLSP.exe"');
    ExitCode := 1;
    Exit;
  end;

  AllSessions := FindShimSessionsForCwd;
  MySessions := FilterByOwnClaudeSession(AllSessions, OurId, Ambiguous);
  if Ambiguous and (Length(AllSessions) > 0) then
  begin
    AbortAmbiguous('set runtime override');
    Exit;
  end;

  Updated := 0;
  for S in MySessions do
  begin
    if not S.Alive then Continue;
    if WriteSentinelAtomic(S.Dir, RuntimeFile, Trimmed) then
      Inc(Updated);
  end;

  if Updated = 0 then
    Writeln('No live shim — runtime override deferred until one spawns.')
  else
    Writeln(Format('Runtime override = %s. Signalling %d shim(s) to recycle DelphiLSP.',
      [Trimmed, Updated]));

  // The shim re-reads runtime.txt at next StartChildConnection, which
  // happens on a /delphi-reload. Auto-trigger that so the override is
  // effective without a second slash command.
  for S in MySessions do
  begin
    if not S.Alive then Continue;
    WriteSentinelAtomic(S.Dir, ReloadFlag, 'signal');
  end;
end;

procedure RunClearRuntimeCommand;
var
  OurId, Path: string;
  AllSessions, MySessions: TArray<TShimSession>;
  S: TShimSession;
  Cleared: Integer;
  Ambiguous: Boolean;
begin
  AllSessions := FindShimSessionsForCwd;
  MySessions := FilterByOwnClaudeSession(AllSessions, OurId, Ambiguous);
  if Ambiguous and (Length(AllSessions) > 0) then
  begin
    AbortAmbiguous('clear runtime override');
    Exit;
  end;

  Cleared := 0;
  for S in MySessions do
  begin
    if not S.Alive then Continue;
    Path := IncludeTrailingPathDelimiter(S.Dir) + RuntimeFile;
    if FileExists(Path) and DeleteFile(PChar(Path)) then
    begin
      Inc(Cleared);
      // Recycle so the cleared override takes effect immediately.
      WriteSentinelAtomic(S.Dir, ReloadFlag, 'signal');
    end;
  end;

  if Cleared = 0 then
    Writeln('No runtime override to clear (or no live shim).')
  else
    Writeln(Format('Runtime override cleared on %d shim(s); recycled.',
      [Cleared]));
end;

end.
