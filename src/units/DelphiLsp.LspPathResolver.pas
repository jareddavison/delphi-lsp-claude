// Copyright (c) 2026 Jared Davison. Released under the MIT License (see LICENSE).
//
// AI-generated (Claude Code). Review before trusting in production.
//
// Resolves which `DelphiLSP.exe` the shim should spawn for a given
// (active-`.delphilsp.json`, per-session-dir) pair. Five rules in
// priority order; the winning rule's name is returned via the `Source`
// out param so the spawn-time log line tells the user which one fired.
//
//   1. DELPHI_LSP_EXE env var          — explicit override (path or PATH name).
//   2. <session>/runtime.txt           — set by `/delphi-runtime`. Either
//                                        an absolute .exe path or a BDS
//                                        version string (e.g. "37.0").
//   3. Active .delphilsp.json hint     — the IDE that wrote it embeds its
//                                        version; resolve to that BDS install.
//   4. Highest installed BDS           — registry walk; pick the newest
//                                        install with a working DelphiLSP.exe.
//   5. Bare 'DelphiLSP.exe'            — relies on PATH.
//
// All registry / installation discovery is delegated to DelphiLsp.DelphiInstall
// helpers; this unit's job is just orchestration of the chain. The runtime.txt
// read is the only file I/O — passed in as a directory, so tests can use a
// synthetic <session>/ under TPath.GetTempPath.

unit DelphiLsp.LspPathResolver;

interface

// Resolution chain documented above. Inputs:
//   SettingsPath — absolute path to active .delphilsp.json (or '' if none picked).
//   SessionDir   — per-shim sentinel dir; runtime.txt is read from here. '' to skip.
// Outputs:
//   Result — path or PATH-name of the DelphiLSP.exe to spawn. Always non-empty.
//   Source — short label describing which rule won; for diagnostic logging.
function ResolveDelphiLspPath(const SettingsPath, SessionDir: string;
  out Source: string): string;

implementation

uses
  System.SysUtils,
  System.Classes,
  DelphiLsp.Env,
  DelphiLsp.Logging,
  DelphiLsp.DelphiInstall;

function ResolveDelphiLspPath(const SettingsPath, SessionDir: string;
  out Source: string): string;
var
  Override_, RuntimePath, RuntimeContent, VerHint, Root, HighestVer: string;
  Lines: TStringList;
begin
  Source := '';

  Override_ := GetEnv('DELPHI_LSP_EXE', '');
  if Override_ <> '' then
  begin
    Source := 'DELPHI_LSP_EXE';
    Exit(Override_);
  end;

  if SessionDir <> '' then
  begin
    RuntimePath := IncludeTrailingPathDelimiter(SessionDir) + 'runtime.txt';
    if FileExists(RuntimePath) then
    begin
      RuntimeContent := '';
      Lines := TStringList.Create;
      try
        try
          Lines.LoadFromFile(RuntimePath, TEncoding.UTF8);
          if Lines.Count > 0 then RuntimeContent := Trim(Lines[0]);
        except
          on E: Exception do Diag('runtime.txt read failed: ' + E.Message);
        end;
      finally
        Lines.Free;
      end;
      if RuntimeContent <> '' then
      begin
        if (Pos('\', RuntimeContent) > 0) or (Pos('/', RuntimeContent) > 0) or
           SameText(ExtractFileExt(RuntimeContent), '.exe') then
        begin
          Source := 'runtime.txt:path';
          Exit(RuntimeContent);
        end;
        Root := FindBdsRootDir(RuntimeContent);
        if Root <> '' then
        begin
          Result := FindDelphiLspExeUnder(Root);
          if Result <> '' then
          begin
            Source := 'runtime.txt:version=' + RuntimeContent;
            Exit;
          end;
        end;
        Diag('runtime.txt version not resolvable: ' + RuntimeContent);
      end;
    end;
  end;

  if SettingsPath <> '' then
  begin
    VerHint := ExtractBdsVersionFromSettings(SettingsPath);
    if VerHint <> '' then
    begin
      Root := FindBdsRootDir(VerHint);
      if Root <> '' then
      begin
        Result := FindDelphiLspExeUnder(Root);
        if Result <> '' then
        begin
          Source := Format('hinted by %s (BDS %s)',
            [ExtractFileName(SettingsPath), VerHint]);
          Exit;
        end;
      end;
      Diag(Format('Settings hinted BDS %s but DelphiLSP.exe not found',
        [VerHint]));
    end;
  end;

  HighestVer := FindHighestBdsVersion(Root);
  if (HighestVer <> '') and (Root <> '') then
  begin
    Result := FindDelphiLspExeUnder(Root);
    if Result <> '' then
    begin
      Source := Format('highest installed (BDS %s)', [HighestVer]);
      Exit;
    end;
  end;

  Source := 'PATH (no registry match)';
  Result := 'DelphiLSP.exe';
end;

end.
