// Copyright (c) 2026 Jared Davison. Released under the MIT License (see LICENSE).
//
// AI-generated (Claude Code). Review before trusting in production.
//
// Read/write sticky project bindings — the per-(claude-session-id, cwd)
// `.delphilsp.json` pick that survives shim death and Claude Code restart.
//
// Storage: a single JSON file per Claude session id (path provided by the
// caller, typically `<plugin-data>/session-state/<session-id>.json`). The
// file is a top-level object whose keys are sha256 hashes of the canonical
// cwd, mapping to entries `{ settingsFile, cwd, lastUsed }`. Atomic writes
// via tmp + MoveFileEx so a concurrent reader never sees a half-written file.

unit DelphiLsp.StickyState;

interface

// Build the conventional sticky-state file path for a given Claude
// Code session id. Convention: <PluginDataBase>/session-state/<id>.json.
// Returns '' if either input is empty so callers can guard with a
// single non-empty check before reading/writing.
function BuildStickyStatePath(const PluginDataBase, SessionId: string): string;

// Read the sticky pick for the given cwd from StatePath. Returns the
// absolute .delphilsp.json path if a valid entry exists AND the file still
// exists on disk; '' otherwise. Returns '' if StatePath is empty or doesn't
// exist (no error logged — that's just the "no sticky yet" case).
function ReadStickyForCwd(const StatePath, Cwd: string): string;

// Persist a sticky pick at StatePath for the given cwd. Atomic via
// tmp + MoveFileEx. No-op if StatePath, Cwd, or SettingsPath is empty.
// Creates the parent directory if it doesn't exist.
procedure WriteStickyForCwd(const StatePath, Cwd, SettingsPath: string);

implementation

uses
  Winapi.Windows,
  System.SysUtils,
  System.Classes,
  System.IOUtils,
  System.JSON,
  System.Hash,
  DelphiLsp.Paths,
  DelphiLsp.Logging,
  DelphiLsp.JsonUtils,
  DelphiLsp.IO,
  DelphiLsp.PluginData;

function BuildStickyStatePath(const PluginDataBase, SessionId: string): string;
begin
  if (PluginDataBase = '') or (SessionId = '') then Exit('');
  Result := IncludeTrailingPathDelimiter(SessionStateDir(PluginDataBase)) +
            SessionId + '.json';
end;

function ReadStickyForCwd(const StatePath, Cwd: string): string;
var
  Content, CwdHash, Path: string;
  Root: TJSONObject;
  EntryVal, PathVal: TJSONValue;
  Entry: TJSONObject;
begin
  Result := '';
  if not TryReadAllText(StatePath, 'Sticky read failed', Content) then Exit;
  CwdHash := THashSHA2.GetHashString(NormalizeCwd(Cwd), SHA256);
  Root := TryParseJsonObject(Content);
  if Root = nil then Exit;
  try
    EntryVal := Root.GetValue(CwdHash);
    if not (EntryVal is TJSONObject) then Exit;
    Entry := TJSONObject(EntryVal);
    PathVal := Entry.GetValue('settingsFile');
    if (PathVal = nil) then Exit;
    Path := PathVal.Value;
    if (Path <> '') and FileExists(Path) then
      Result := Path
    else if Path <> '' then
      Diag('Sticky pick references missing file (ignored): ' + Path);
  finally
    Root.Free;
  end;
end;

procedure WriteStickyForCwd(const StatePath, Cwd, SettingsPath: string);
var
  Root: TJSONObject;
  ExistingPair: TJSONPair;
  Entry: TJSONObject;
  CwdHash, Content, Dir, TmpPath, Json: string;
  Bytes: TBytes;
  FS: TFileStream;
begin
  if (StatePath = '') or (Cwd = '') or (SettingsPath = '') then Exit;
  CwdHash := THashSHA2.GetHashString(NormalizeCwd(Cwd), SHA256);

  Root := nil;
  try
    if TryReadAllText(StatePath, 'Sticky read-for-update failed',
                      Content) then
      Root := TryParseJsonObject(Content);
    if Root = nil then Root := TJSONObject.Create;

    ExistingPair := Root.RemovePair(CwdHash);
    if ExistingPair <> nil then ExistingPair.Free;
    Entry := TJSONObject.Create;
    Entry.AddPair('settingsFile', SettingsPath);
    Entry.AddPair('cwd', Cwd);
    Entry.AddPair('lastUsed', FormatDateTime('yyyy-mm-dd"T"hh:nn:ss"Z"', Now));
    Root.AddPair(CwdHash, Entry);

    Dir := ExtractFilePath(StatePath);
    try
      ForceDirectories(Dir);
    except
      on E: Exception do
      begin
        Diag('Sticky dir create failed: ' + E.Message);
        Exit;
      end;
    end;

    Json := Root.ToJSON;
    TmpPath := StatePath + '.tmp';
    try
      Bytes := TEncoding.UTF8.GetBytes(Json);
      FS := TFileStream.Create(TmpPath, fmCreate);
      try
        if Length(Bytes) > 0 then
          FS.WriteBuffer(Bytes[0], Length(Bytes));
      finally
        FS.Free;
      end;
    except
      on E: Exception do
      begin
        Diag('Sticky tmp write failed: ' + E.Message);
        Exit;
      end;
    end;
    if not MoveFileEx(PChar(TmpPath), PChar(StatePath),
                      MOVEFILE_REPLACE_EXISTING) then
      Diag(Format('Sticky MoveFileEx failed: %d', [GetLastError]))
    else
      Diag(Format('Sticky pick saved: cwd=%s settings=%s', [Cwd, SettingsPath]));
  finally
    Root.Free;
  end;
end;

end.
