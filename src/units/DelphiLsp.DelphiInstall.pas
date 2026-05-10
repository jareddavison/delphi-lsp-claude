// Copyright (c) 2026 Jared Davison. Released under the MIT License (see LICENSE).
//
// AI-generated (Claude Code). Review before trusting in production.
//
// Discovery and selection of Embarcadero RAD Studio (BDS) installations
// and their bundled DelphiLSP.exe. RAD Studio is a 32-bit installer, so
// its registry entries land under HKLM\SOFTWARE\Wow6432Node\Embarcadero\BDS
// on 64-bit Windows; HKLM (bare) and HKCU are fallbacks for unusual
// installs. Each version's `RootDir` value gives the install root, under
// which `bin\DelphiLSP.exe` (32-bit) or `bin64\DelphiLSP.exe` (64-bit,
// higher-tier SKUs) lives.

unit DelphiLsp.DelphiInstall;

interface

uses
  Winapi.Windows,
  System.Classes;

// Pick which DelphiLSP.exe to spawn under a given BDS install root.
// Default behaviour: prefer 64-bit, fall back to 32-bit. Override via
// the DELPHI_LSP_BITS env var:
//   DELPHI_LSP_BITS=32  — only consider 32-bit (bin\DelphiLSP.exe)
//   DELPHI_LSP_BITS=64  — only consider 64-bit (bin64\DelphiLSP.exe);
//                         fail loudly via Diag if missing
//   (unset/empty/other) — 64-then-32 fallback
// Returns '' if no candidate satisfies the preference.
function FindDelphiLspExeUnder(const BdsRoot: string): string;

// Compare two BDS version strings ("major.minor" form, e.g. "37.0" vs "23.1").
// Negative = A<B, 0 = equal, positive = A>B. Each side parses to integers
// (major, minor); non-numeric segments treat as 0. Pure function.
function CompareBdsVersions(const A, B: string): Integer;

// Read the registry to find the install root for a specific BDS version.
// Tries HKLM\Wow6432Node\Embarcadero\BDS\<Version>, then HKLM, then HKCU.
// Returns '' if no key has a `RootDir` value. Trailing path-delimiter
// stripped.
function FindBdsRootDir(const Version: string): string;

// Enumerate subkey names under a registry path and append them to Acc.
// Used to find every installed BDS version under one of the three roots.
procedure CollectBdsVersionsFrom(Root: HKEY; const KeyPath: string; Acc: TStringList);

// Walk every BDS version registered on this machine; return the highest
// version that has both a resolvable RootDir and a DelphiLSP.exe under it.
// RootDir out param is the install root (trailing delimiter stripped).
// Returns '' / RootDir='' if no install qualifies.
function FindHighestBdsVersion(out RootDir: string): string;

// Scan a `.delphilsp.json` file for any embedded BDS version reference
// (e.g. paths containing `studio/37.0/` or `BDS\37.0\`). Returns the
// X.Y form, or '' if no match. The IDE that wrote the .delphilsp.json
// embeds its install version in numerous places; any one will do.
function ExtractBdsVersionFromSettings(const Path: string): string;

implementation

uses
  System.SysUtils,
  System.IOUtils,
  System.RegularExpressions,
  System.Win.Registry,
  DelphiLsp.Env,
  DelphiLsp.Logging;

function FindDelphiLspExeUnder(const BdsRoot: string): string;
var
  Bin64Path, Bin32Path, Pref: string;
begin
  Result := '';
  if BdsRoot = '' then Exit;
  Bin64Path := IncludeTrailingPathDelimiter(BdsRoot) + 'bin64\DelphiLSP.exe';
  Bin32Path := IncludeTrailingPathDelimiter(BdsRoot) + 'bin\DelphiLSP.exe';
  Pref := Trim(GetEnv('DELPHI_LSP_BITS', ''));
  if Pref = '32' then
  begin
    if FileExists(Bin32Path) then
      Exit(Bin32Path)
    else
      Diag('DELPHI_LSP_BITS=32 but 32-bit DelphiLSP.exe not found under ' + BdsRoot);
    Exit;
  end;
  if Pref = '64' then
  begin
    if FileExists(Bin64Path) then
      Exit(Bin64Path)
    else
      Diag('DELPHI_LSP_BITS=64 but 64-bit DelphiLSP.exe not found under ' + BdsRoot);
    Exit;
  end;
  if FileExists(Bin64Path) then Exit(Bin64Path);
  if FileExists(Bin32Path) then Exit(Bin32Path);
end;

function CompareBdsVersions(const A, B: string): Integer;
var
  AParts, BParts: TArray<string>;
  AMaj, AMin, BMaj, BMin: Integer;
begin
  AParts := A.Split(['.']);
  BParts := B.Split(['.']);
  AMaj := 0; AMin := 0; BMaj := 0; BMin := 0;
  if Length(AParts) > 0 then AMaj := StrToIntDef(AParts[0], 0);
  if Length(AParts) > 1 then AMin := StrToIntDef(AParts[1], 0);
  if Length(BParts) > 0 then BMaj := StrToIntDef(BParts[0], 0);
  if Length(BParts) > 1 then BMin := StrToIntDef(BParts[1], 0);
  if AMaj <> BMaj then Exit(AMaj - BMaj);
  Result := AMin - BMin;
end;

function FindBdsRootDir(const Version: string): string;
var
  Reg: TRegistry;

  function TryRead(Root: HKEY; const KeyPath: string): string;
  begin
    Result := '';
    Reg.RootKey := Root;
    if Reg.OpenKeyReadOnly(KeyPath) then
    try
      if Reg.ValueExists('RootDir') then
        Result := Reg.ReadString('RootDir');
    finally
      Reg.CloseKey;
    end;
  end;

begin
  Result := '';
  Reg := TRegistry.Create(KEY_READ);
  try
    Result := TryRead(HKEY_LOCAL_MACHINE, 'SOFTWARE\Wow6432Node\Embarcadero\BDS\' + Version);
    if Result = '' then
      Result := TryRead(HKEY_LOCAL_MACHINE, 'SOFTWARE\Embarcadero\BDS\' + Version);
    if Result = '' then
      Result := TryRead(HKEY_CURRENT_USER, 'Software\Embarcadero\BDS\' + Version);
  finally
    Reg.Free;
  end;
  if Result <> '' then
    Result := ExcludeTrailingPathDelimiter(Result);
end;

procedure CollectBdsVersionsFrom(Root: HKEY; const KeyPath: string; Acc: TStringList);
var
  Reg: TRegistry;
begin
  Reg := TRegistry.Create(KEY_READ);
  try
    Reg.RootKey := Root;
    if Reg.OpenKeyReadOnly(KeyPath) then
    try
      Reg.GetKeyNames(Acc);
    finally
      Reg.CloseKey;
    end;
  finally
    Reg.Free;
  end;
end;

function FindHighestBdsVersion(out RootDir: string): string;
var
  Versions: TStringList;
  I: Integer;
  V, BestVer, ThisRoot, ExePath: string;
begin
  Result := '';
  RootDir := '';
  Versions := TStringList.Create;
  try
    Versions.Sorted := True;
    Versions.Duplicates := dupIgnore;
    CollectBdsVersionsFrom(HKEY_LOCAL_MACHINE, 'SOFTWARE\Wow6432Node\Embarcadero\BDS', Versions);
    CollectBdsVersionsFrom(HKEY_LOCAL_MACHINE, 'SOFTWARE\Embarcadero\BDS', Versions);
    CollectBdsVersionsFrom(HKEY_CURRENT_USER, 'Software\Embarcadero\BDS', Versions);
    BestVer := '';
    for I := 0 to Versions.Count - 1 do
    begin
      V := Versions[I];
      // Skip non-version subkeys (e.g. 'Globals')
      if not TRegEx.IsMatch(V, '^\d+\.\d+$') then Continue;
      ThisRoot := FindBdsRootDir(V);
      if ThisRoot = '' then Continue;
      ExePath := FindDelphiLspExeUnder(ThisRoot);
      if ExePath = '' then Continue;
      if (BestVer = '') or (CompareBdsVersions(V, BestVer) > 0) then
      begin
        BestVer := V;
        RootDir := ThisRoot;
      end;
    end;
    Result := BestVer;
  finally
    Versions.Free;
  end;
end;

function ExtractBdsVersionFromSettings(const Path: string): string;
var
  Content: string;
  Match: TMatch;
begin
  Result := '';
  if (Path = '') or (not FileExists(Path)) then Exit;
  try
    Content := TFile.ReadAllText(Path, TEncoding.UTF8);
  except
    on E: Exception do
    begin
      Diag('ExtractBdsVersionFromSettings read failed: ' + E.Message);
      Exit;
    end;
  end;
  Match := TRegEx.Match(Content, '(?i)(?:studio|bds)[/\\]+(\d+\.\d+)');
  if Match.Success then
    Result := Match.Groups[1].Value;
end;

end.
