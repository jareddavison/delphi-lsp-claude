// Copyright (c) 2026 Jared Davison. Released under the MIT License (see LICENSE).
//
// AI-generated (Claude Code). Review before trusting in production.

unit DelphiLsp.EnvTests;

interface

uses
  DUnitX.TestFramework;

type
  [TestFixture]
  TEnvTests = class
  private
    const TestVar = 'DELPHI_LSP_ENV_TESTS_TMP';
    procedure ClearVar;
    procedure SetVar(const Value: string);
  public
    [Setup] procedure Setup;
    [TearDown] procedure TearDown;

    [Test] procedure UnsetVar_ReturnsDefault;
    [Test] procedure SetVar_ReturnsValue;
    [Test] procedure SetVarToEmpty_ReturnsDefault;
    [Test] procedure EmptyDefault_AndUnset_ReturnsEmpty;
    [Test] procedure WhitespaceValue_PreservedNotTrimmed;
  end;

implementation

uses
  Winapi.Windows,
  System.SysUtils,
  DelphiLsp.Env;

procedure TEnvTests.ClearVar;
begin
  Winapi.Windows.SetEnvironmentVariable(PChar(TestVar), nil);
end;

procedure TEnvTests.SetVar(const Value: string);
begin
  Winapi.Windows.SetEnvironmentVariable(PChar(TestVar), PChar(Value));
end;

procedure TEnvTests.Setup;
begin
  ClearVar;
end;

procedure TEnvTests.TearDown;
begin
  ClearVar;
end;

procedure TEnvTests.UnsetVar_ReturnsDefault;
begin
  Assert.AreEqual('fallback', GetEnv(TestVar, 'fallback'));
end;

procedure TEnvTests.SetVar_ReturnsValue;
begin
  SetVar('actual-value');
  Assert.AreEqual('actual-value', GetEnv(TestVar, 'fallback'));
end;

procedure TEnvTests.SetVarToEmpty_ReturnsDefault;
begin
  // An explicitly-empty env var ('') is treated as "unset" — the shim
  // never consumes empty strings as meaningful.
  SetVar('');
  Assert.AreEqual('fallback', GetEnv(TestVar, 'fallback'));
end;

procedure TEnvTests.EmptyDefault_AndUnset_ReturnsEmpty;
begin
  Assert.AreEqual('', GetEnv(TestVar, ''));
end;

procedure TEnvTests.WhitespaceValue_PreservedNotTrimmed;
begin
  // The wrapper only swaps in the default for empty; leading/trailing
  // whitespace is the caller's problem (DELPHI_LSP_BITS for example
  // does its own Trim downstream).
  SetVar('  spaced  ');
  Assert.AreEqual('  spaced  ', GetEnv(TestVar, 'fallback'));
end;

initialization
  TDUnitX.RegisterTestFixture(TEnvTests);

end.
