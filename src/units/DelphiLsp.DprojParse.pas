// Copyright (c) 2026 Jared Davison. Released under the MIT License (see LICENSE).
//
// AI-generated (Claude Code). Review before trusting in production.
//
// Parsers and helpers for Delphi project artifacts:
//   - `.dproj` (XML, MSBuild-flavored): walks <DCCReference Include=".."/>
//     entries to determine which projects own a given source file.
//   - `.delphilsp.json` (JSON): pulls dccOptions, extracts -NU<path> for
//     the DCU output directory.
//   - DCU activity counting: walks a directory for *.dcu mtimes ≥ a cutoff.
//
// Used by --find-project-for and the SessionStart hook's multi-candidate
// picker enrichment (DCU mtimes are the strongest signal for "user is
// actively building this project").

unit DelphiLsp.DprojParse;

interface

// Pull a -XX flag's value out of a `dccOptions` string. Handles both quoted
// (`-NU"C:\Some Path"`) and unquoted (`-NU.\Win32\Debug`) forms. The flag
// must start the string or be preceded by whitespace — prevents
// `-FOOBAR-NU/path` substrings from false-matching. Returns '' if absent.
function ExtractDccFlagValue(const DccOptions, Flag: string): string;

// Read .delphilsp.json's settings.dccOptions and extract the `-NU<path>`
// flag — the project's DCU output directory for the IDE's currently-selected
// build target (Debug/Release × Win32/Win64). Path is resolved absolute
// relative to the .delphilsp.json's directory. Returns '' if the file is
// missing, not parseable, or doesn't contain a -NU flag.
function ResolveDcuOutputDir(const DelphilspPath: string): string;

// Count .dcu files directly under DcuDir whose mtime is ≥ CutoffEarliest.
// Each recent .dcu = a unit recently compiled into THIS project, including
// implicitly-used units pulled in via uses-clause + search paths.
function CountRecentDcus(const DcuDir: string;
  const CutoffEarliest: TDateTime): Integer;

// Find which .delphilsp.json files (if any) own the given .pas/.inc/.dpr/.dpk
// path via DCCReference scan. Walks every .dproj under the workspace root
// (CollectFilesByExt with depth/skip rules), regex-matches
// <DCCReference Include="..."/> entries, XML-decodes them, resolves relative
// to the .dproj's directory, compares to PasPath canonically. For each .dproj
// that owns the path, returns the sibling .delphilsp.json (basename match).
//
// Returns 0/1/N owners — caller decides whether to act on a unique match
// or treat ambiguity / no-match as fallback.
//
// Note: only catches EXPLICIT references in the .dproj. Units pulled in via
// `uses` + search paths aren't listed there. The DCU-mtime approach
// (CountRecentDcus) catches those implicit references.
function FindOwningDelphilspJsons(const Workspace, PasPath: string): TArray<string>;

implementation

uses
  System.SysUtils,
  System.Classes,
  System.IOUtils,
  System.JSON,
  System.RegularExpressions,
  System.Generics.Collections,
  DelphiLsp.XmlDecode,
  DelphiLsp.Walkers,
  DelphiLsp.Logging;

function ExtractDccFlagValue(const DccOptions, Flag: string): string;
var
  Match: TMatch;
begin
  Match := TRegEx.Match(DccOptions,
    '(?:^|\s)' + Flag + '(?:"([^"]+)"|(\S+))', [roIgnoreCase]);
  if not Match.Success then Exit('');
  if (Match.Groups.Count > 1) and Match.Groups[1].Success and
     (Match.Groups[1].Value <> '') then
    Result := Match.Groups[1].Value
  else if (Match.Groups.Count > 2) and Match.Groups[2].Success then
    Result := Match.Groups[2].Value
  else
    Result := '';
end;

function ResolveDcuOutputDir(const DelphilspPath: string): string;
var
  Content, DccOptions, RelPath: string;
  Root, SettingsVal, OptsVal: TJSONValue;
begin
  Result := '';
  if not FileExists(DelphilspPath) then Exit;
  try
    Content := TFile.ReadAllText(DelphilspPath, TEncoding.UTF8);
  except
    Exit;
  end;
  Root := nil;
  try
    try
      Root := TJSONObject.ParseJSONValue(Content);
    except
      Exit;
    end;
    if not (Root is TJSONObject) then Exit;
    SettingsVal := TJSONObject(Root).GetValue('settings');
    if not (SettingsVal is TJSONObject) then Exit;
    OptsVal := TJSONObject(SettingsVal).GetValue('dccOptions');
    if OptsVal = nil then Exit;
    DccOptions := OptsVal.Value;
    RelPath := ExtractDccFlagValue(DccOptions, '-NU');
    if RelPath = '' then Exit;
    Result := TPath.GetFullPath(
      TPath.Combine(ExtractFilePath(DelphilspPath), RelPath));
  finally
    Root.Free;
  end;
end;

function CountRecentDcus(const DcuDir: string;
  const CutoffEarliest: TDateTime): Integer;
var
  SR: TSearchRec;
begin
  Result := 0;
  if (DcuDir = '') or not DirectoryExists(DcuDir) then Exit;
  if FindFirst(IncludeTrailingPathDelimiter(DcuDir) + '*.dcu', faAnyFile, SR) = 0 then
  try
    repeat
      if (SR.Attr and faDirectory) <> 0 then Continue;
      if SR.TimeStamp >= CutoffEarliest then
        Inc(Result);
    until FindNext(SR) <> 0;
  finally
    FindClose(SR);
  end;
end;

function FindOwningDelphilspJsons(const Workspace, PasPath: string): TArray<string>;
var
  Dprojs: TList<string>;
  Owners: TList<string>;
  DprojPath, DprojDir, Content, RefPath, AbsRef, DelphilspPath: string;
  Matches: TMatchCollection;
  M: TMatch;
  TargetCanon, RefCanon: string;
  I: Integer;
begin
  Dprojs := TList<string>.Create;
  Owners := TList<string>.Create;
  try
    CollectFilesByExt(Workspace, '.dproj', 0, Dprojs);
    TargetCanon := LowerCase(StringReplace(PasPath, '\', '/', [rfReplaceAll]));
    for I := 0 to Dprojs.Count - 1 do
    begin
      DprojPath := Dprojs[I];
      DprojDir := ExtractFilePath(DprojPath);
      try
        Content := TFile.ReadAllText(DprojPath, TEncoding.UTF8);
      except
        on E: Exception do
        begin
          Diag(Format('FindOwning: read failed for %s: %s', [DprojPath, E.Message]));
          Continue;
        end;
      end;
      Matches := TRegEx.Matches(Content, '<DCCReference\s+Include="([^"]+)"', [roIgnoreCase]);
      for M in Matches do
      begin
        if M.Groups.Count < 2 then Continue;
        // XML-decode the Include value: third-party .dproj generators may
        // emit &amp; / &lt; etc. for paths the IDE would write verbatim.
        RefPath := XmlDecode(M.Groups[1].Value);
        AbsRef := TPath.GetFullPath(TPath.Combine(DprojDir, RefPath));
        RefCanon := LowerCase(StringReplace(AbsRef, '\', '/', [rfReplaceAll]));
        if RefCanon = TargetCanon then
        begin
          DelphilspPath := ChangeFileExt(DprojPath, '.delphilsp.json');
          if FileExists(DelphilspPath) and (Owners.IndexOf(DelphilspPath) < 0) then
            Owners.Add(DelphilspPath);
          Break; // one match per .dproj is enough
        end;
      end;
    end;
    Result := Owners.ToArray;
  finally
    Dprojs.Free;
    Owners.Free;
  end;
end;

end.
