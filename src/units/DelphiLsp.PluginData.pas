// Copyright (c) 2026 Jared Davison. Released under the MIT License (see LICENSE).
//
// AI-generated (Claude Code). Review before trusting in production.
//
// Discovery helpers for Claude Code's data directories. The plugin needs
// two distinct paths:
//
//   - "Plugin data base" = the per-plugin data dir Claude Code passes via
//     CLAUDE_PLUGIN_DATA. The shim writes session-state, claude-pid, and
//     per-PID sessions/ subdirs there. Slash commands resolve this with
//     the same fallback chain so both sides agree.
//
//   - "Projects root" = where Claude Code stores per-session transcript
//     .jsonl files. Walking up from CLAUDE_PLUGIN_DATA gets us
//     <claude-data-dir>, and <data-dir>/projects/ is the answer.
//
// IsClaudeSessionAlive ties the two together: a session is "alive" if its
// .jsonl is still in the projects root.

unit DelphiLsp.PluginData;

interface

// Resolve <plugin-data>/ — where the shim writes its persistent state.
// Strategy:
//   1. CLAUDE_PLUGIN_DATA env var (set by Claude Code on LSP spawn)
//   2. %LOCALAPPDATA%/delphi-lsp-claude as fallback (when slash commands
//      run without CLAUDE_PLUGIN_DATA in their env)
// Returns '' if neither yields a path. Both shim and slash commands use
// this fallback chain so they agree on the storage location.
function ResolvePluginDataBase: string;

// Resolve <claude-data-dir>/projects/ — where Claude Code stores per-
// session conversation transcripts. Strategy:
//   1. Walk up 3 dirs from CLAUDE_PLUGIN_DATA (which is reliably
//      <data-dir>/plugins/data/<plugin-id>/), then append /projects.
//      Authoritative for non-standard installs.
//   2. Fall back to %USERPROFILE%/.claude/projects (the documented default).
function ResolveProjectsRoot: string;

// Is the given Claude Code session still resumable? True iff a transcript
// .jsonl exists in the projects-root for that session id (Claude Code
// keeps the .jsonl while the session is in conversation history). Pass
// in ProjectsRoot explicitly for testability against synthetic dirs;
// production callers pass ResolveProjectsRoot. Returns False on '' input
// or missing root.
function IsClaudeSessionAlive(const ProjectsRoot, SessionId: string): Boolean;

implementation

uses
  System.SysUtils;

function GetEnv(const Name, Default: string): string;
begin
  Result := GetEnvironmentVariable(Name);
  if Result = '' then Result := Default;
end;

function ResolvePluginDataBase: string;
begin
  Result := GetEnv('CLAUDE_PLUGIN_DATA', '');
  if Result = '' then
  begin
    Result := GetEnv('LOCALAPPDATA', '');
    if Result <> '' then
      Result := IncludeTrailingPathDelimiter(Result) + 'delphi-lsp-claude';
  end;
end;

function ResolveProjectsRoot: string;
var
  PluginData, DataDir: string;
begin
  Result := '';
  PluginData := GetEnv('CLAUDE_PLUGIN_DATA', '');
  if PluginData <> '' then
  begin
    DataDir := ExtractFileDir(ExtractFileDir(ExtractFileDir(
      ExcludeTrailingPathDelimiter(PluginData))));
    if (DataDir <> '') and DirectoryExists(DataDir) then
    begin
      Result := IncludeTrailingPathDelimiter(DataDir) + 'projects';
      if DirectoryExists(Result) then Exit;
    end;
  end;
  Result := IncludeTrailingPathDelimiter(GetEnv('USERPROFILE', '')) +
            '.claude' + PathDelim + 'projects';
end;

function IsClaudeSessionAlive(const ProjectsRoot, SessionId: string): Boolean;
var
  ProjDir, JsonlPath: string;
  SR: TSearchRec;
begin
  Result := False;
  if (SessionId = '') or (ProjectsRoot = '') then Exit;
  if not DirectoryExists(ProjectsRoot) then Exit;
  if FindFirst(IncludeTrailingPathDelimiter(ProjectsRoot) + '*', faDirectory, SR) = 0 then
  try
    repeat
      if (SR.Name = '.') or (SR.Name = '..') then Continue;
      if (SR.Attr and faDirectory) = 0 then Continue;
      ProjDir := IncludeTrailingPathDelimiter(ProjectsRoot) + SR.Name;
      JsonlPath := IncludeTrailingPathDelimiter(ProjDir) + SessionId + '.jsonl';
      if FileExists(JsonlPath) then
      begin
        Result := True;
        Exit;
      end;
    until FindNext(SR) <> 0;
  finally
    FindClose(SR);
  end;
end;

end.
