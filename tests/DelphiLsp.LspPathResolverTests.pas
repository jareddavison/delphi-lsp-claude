// Copyright (c) 2026 Jared Davison. Released under the MIT License (see LICENSE).
//
// AI-generated (Claude Code). Review before trusting in production.

unit DelphiLsp.LspPathResolverTests;

interface

uses
  DUnitX.TestFramework;

type
  [TestFixture]
  TLspPathResolverTests = class
  private
    FRoot: string;
    FOldDelphiLspExe: string;
    FHadDelphiLspExe: Boolean;
    procedure ClearEnv(const Name: string);
    procedure SetEnv(const Name, Value: string);
    procedure WriteRuntime(const Content: string);
    procedure WriteSettings(const Name, Content: string; out FullPath: string);
  public
    [Setup] procedure Setup;
    [TearDown] procedure TearDown;

    // Rule 1: DELPHI_LSP_EXE
    [Test] procedure EnvOverride_WinsOverEverything;
    [Test] procedure EnvOverride_ReturnsExactValue;

    // Rule 2: <session>/runtime.txt
    [Test] procedure Runtime_PathLike_ForwardSlash;
    [Test] procedure Runtime_PathLike_BackSlash;
    [Test] procedure Runtime_PathLike_DotExe;
    [Test] procedure Runtime_TrimsWhitespace;
    [Test] procedure Runtime_EmptyFile_FallsThrough;
    [Test] procedure Runtime_UnresolvableVersion_FallsThrough;
    [Test] procedure Runtime_MissingFile_FallsThrough;
    [Test] procedure Runtime_EmptySessionDir_Skipped;

    // Rule 3: settings-hint version
    [Test] procedure Settings_NoVersion_FallsThrough;
    [Test] procedure Settings_EmptyPath_Skipped;

    // Rules 4 / 5: highest installed → PATH fallback
    [Test] procedure Fallback_AlwaysReturnsNonEmpty;
    [Test] procedure Fallback_SourceMatchesResult;
  end;

implementation

uses
  Winapi.Windows,
  System.SysUtils,
  System.IOUtils,
  System.Classes,
  DelphiLsp.LspPathResolver;

const
  ENV_DELPHI_LSP_EXE = 'DELPHI_LSP_EXE';

{ Helpers }

procedure TLspPathResolverTests.ClearEnv(const Name: string);
begin
  Winapi.Windows.SetEnvironmentVariable(PChar(Name), nil);
end;

procedure TLspPathResolverTests.SetEnv(const Name, Value: string);
begin
  Winapi.Windows.SetEnvironmentVariable(PChar(Name), PChar(Value));
end;

procedure TLspPathResolverTests.WriteRuntime(const Content: string);
begin
  TFile.WriteAllText(IncludeTrailingPathDelimiter(FRoot) + 'runtime.txt',
    Content, TEncoding.UTF8);
end;

procedure TLspPathResolverTests.WriteSettings(const Name, Content: string;
  out FullPath: string);
begin
  FullPath := IncludeTrailingPathDelimiter(FRoot) + Name;
  TFile.WriteAllText(FullPath, Content, TEncoding.UTF8);
end;

procedure TLspPathResolverTests.Setup;
var
  Buf: array[0..32767] of Char;
  Got: DWORD;
begin
  FRoot := TPath.Combine(TPath.GetTempPath, 'lsppathres-' +
    TGUID.NewGuid.ToString.Replace('{', '').Replace('}', ''));
  TDirectory.CreateDirectory(FRoot);

  // Snapshot DELPHI_LSP_EXE so tests don't pollute the dev's env.
  Got := Winapi.Windows.GetEnvironmentVariable(ENV_DELPHI_LSP_EXE,
    @Buf[0], Length(Buf));
  FHadDelphiLspExe := Got > 0;
  if FHadDelphiLspExe then
    FOldDelphiLspExe := string(Buf)
  else
    FOldDelphiLspExe := '';
  ClearEnv(ENV_DELPHI_LSP_EXE);
end;

procedure TLspPathResolverTests.TearDown;
begin
  if FHadDelphiLspExe then
    SetEnv(ENV_DELPHI_LSP_EXE, FOldDelphiLspExe)
  else
    ClearEnv(ENV_DELPHI_LSP_EXE);
  if (FRoot <> '') and TDirectory.Exists(FRoot) then
    TDirectory.Delete(FRoot, True);
end;

{ Rule 1 — DELPHI_LSP_EXE env override }

procedure TLspPathResolverTests.EnvOverride_WinsOverEverything;
var
  Got, Source: string;
begin
  // Set every other input as well; env should still win.
  SetEnv(ENV_DELPHI_LSP_EXE, 'C:\override\DelphiLSP.exe');
  WriteRuntime('C:\runtimepath\DelphiLSP.exe');
  Got := ResolveDelphiLspPath('', FRoot, Source);
  Assert.AreEqual('C:\override\DelphiLSP.exe', Got);
  Assert.AreEqual('DELPHI_LSP_EXE', Source);
end;

procedure TLspPathResolverTests.EnvOverride_ReturnsExactValue;
var
  Got, Source: string;
begin
  // Bare name (relies on PATH) is also a valid override value.
  SetEnv(ENV_DELPHI_LSP_EXE, 'DelphiLSP.exe');
  Got := ResolveDelphiLspPath('', '', Source);
  Assert.AreEqual('DelphiLSP.exe', Got);
  Assert.AreEqual('DELPHI_LSP_EXE', Source);
end;

{ Rule 2 — runtime.txt }

procedure TLspPathResolverTests.Runtime_PathLike_ForwardSlash;
var
  Got, Source: string;
begin
  WriteRuntime('C:/Tools/DelphiLSP.exe');
  Got := ResolveDelphiLspPath('', FRoot, Source);
  Assert.AreEqual('C:/Tools/DelphiLSP.exe', Got);
  Assert.AreEqual('runtime.txt:path', Source);
end;

procedure TLspPathResolverTests.Runtime_PathLike_BackSlash;
var
  Got, Source: string;
begin
  WriteRuntime('C:\Tools\DelphiLSP.exe');
  Got := ResolveDelphiLspPath('', FRoot, Source);
  Assert.AreEqual('C:\Tools\DelphiLSP.exe', Got);
  Assert.AreEqual('runtime.txt:path', Source);
end;

procedure TLspPathResolverTests.Runtime_PathLike_DotExe;
var
  Got, Source: string;
begin
  // No slash but ends in .exe — still treated as a path (heuristic in resolver).
  WriteRuntime('DelphiLSP.exe');
  Got := ResolveDelphiLspPath('', FRoot, Source);
  Assert.AreEqual('DelphiLSP.exe', Got);
  Assert.AreEqual('runtime.txt:path', Source);
end;

procedure TLspPathResolverTests.Runtime_TrimsWhitespace;
var
  Got, Source: string;
begin
  // Slash present so the path-heuristic fires; covers the Trim() path
  // around the first line of runtime.txt (mixed whitespace + CRLF).
  WriteRuntime('  C:\Tools\DelphiLSP.exe  '#13#10);
  Got := ResolveDelphiLspPath('', FRoot, Source);
  Assert.AreEqual('C:\Tools\DelphiLSP.exe', Got);
  Assert.AreEqual('runtime.txt:path', Source);
end;

procedure TLspPathResolverTests.Runtime_EmptyFile_FallsThrough;
var
  Got, Source: string;
begin
  WriteRuntime('');
  Got := ResolveDelphiLspPath('', FRoot, Source);
  // Empty content is ignored — falls through to rule 4/5. We don't care
  // exactly which (depends on whether BDS is installed) but the source
  // must NOT be a runtime.txt label.
  Assert.IsFalse(Source.StartsWith('runtime.txt'),
    'empty runtime.txt must not win the resolution chain, source=' + Source);
  Assert.IsTrue(Got <> '', 'fallback always returns a non-empty result');
end;

procedure TLspPathResolverTests.Runtime_UnresolvableVersion_FallsThrough;
var
  Got, Source: string;
begin
  // Version-like content with no slash and no .exe — treated as a BDS
  // version. Pick one that almost certainly isn't installed (very high)
  // so the registry lookup fails on every machine.
  WriteRuntime('999.0');
  Got := ResolveDelphiLspPath('', FRoot, Source);
  Assert.IsFalse(Source.StartsWith('runtime.txt'),
    'unresolvable version must fall through, source=' + Source);
  Assert.IsTrue(Got <> '');
end;

procedure TLspPathResolverTests.Runtime_MissingFile_FallsThrough;
var
  Got, Source: string;
begin
  // No runtime.txt under FRoot.
  Got := ResolveDelphiLspPath('', FRoot, Source);
  Assert.IsFalse(Source.StartsWith('runtime.txt'),
    'missing runtime.txt must not register, source=' + Source);
  Assert.IsTrue(Got <> '');
end;

procedure TLspPathResolverTests.Runtime_EmptySessionDir_Skipped;
var
  Got, Source: string;
begin
  // Empty SessionDir — runtime.txt rule must not fire even if a stray file
  // exists somewhere with that name.
  WriteRuntime('C:\Tools\DelphiLSP.exe');
  Got := ResolveDelphiLspPath('', '', Source);
  Assert.IsFalse(Source.StartsWith('runtime.txt'),
    'empty SessionDir disables the runtime.txt rule, source=' + Source);
  Assert.IsTrue(Got <> '');
end;

{ Rule 3 — settings hint }

procedure TLspPathResolverTests.Settings_NoVersion_FallsThrough;
var
  SettingsPath, Got, Source: string;
begin
  // Settings file with no embedded BDS version — ExtractBdsVersionFromSettings
  // returns ''. Resolver must fall through to highest installed / PATH.
  WriteSettings('a.delphilsp.json', '{"unrelated":"content"}', SettingsPath);
  Got := ResolveDelphiLspPath(SettingsPath, FRoot, Source);
  Assert.IsFalse(Source.StartsWith('hinted by'),
    'no embedded version => settings hint must not win, source=' + Source);
  Assert.IsTrue(Got <> '');
end;

procedure TLspPathResolverTests.Settings_EmptyPath_Skipped;
var
  Got, Source: string;
begin
  Got := ResolveDelphiLspPath('', FRoot, Source);
  Assert.IsFalse(Source.StartsWith('hinted by'),
    'empty SettingsPath disables the hint rule, source=' + Source);
  Assert.IsTrue(Got <> '');
end;

{ Rules 4 / 5 — highest installed → PATH fallback }

procedure TLspPathResolverTests.Fallback_AlwaysReturnsNonEmpty;
var
  Got, Source: string;
begin
  // No env, no SessionDir, no SettingsPath: the function MUST still return
  // something — either a registry-resolved path or the bare PATH name.
  Got := ResolveDelphiLspPath('', '', Source);
  Assert.IsTrue(Got <> '', 'resolver always returns a non-empty result');
  Assert.IsTrue(Source <> '', 'source label always set');
end;

procedure TLspPathResolverTests.Fallback_SourceMatchesResult;
var
  Got, Source: string;
begin
  Got := ResolveDelphiLspPath('', '', Source);
  // Two valid outcomes:
  //   - Real BDS install on this machine: source like 'highest installed (BDS X.Y)',
  //     result is an absolute path to DelphiLSP.exe.
  //   - No BDS install: source = 'PATH (no registry match)', result = 'DelphiLSP.exe'.
  if Source = 'PATH (no registry match)' then
    Assert.AreEqual('DelphiLSP.exe', Got)
  else
  begin
    Assert.IsTrue(Source.StartsWith('highest installed'),
      'unexpected source label: ' + Source);
    Assert.IsTrue(Got.EndsWith('DelphiLSP.exe', True),
      'result must point at DelphiLSP.exe, got: ' + Got);
  end;
end;

initialization
  TDUnitX.RegisterTestFixture(TLspPathResolverTests);

end.
