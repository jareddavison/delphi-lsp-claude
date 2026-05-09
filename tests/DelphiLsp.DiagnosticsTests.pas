// Copyright (c) 2026 Jared Davison. Released under the MIT License (see LICENSE).
//
// AI-generated (Claude Code). Review before trusting in production.

unit DelphiLsp.DiagnosticsTests;

interface

uses
  DUnitX.TestFramework;

type
  [TestFixture]
  TDiagnosticsTests = class
  public
    // FilterClaudeEnvLines
    [Test] procedure Filter_KeepsClaudePrefix;
    [Test] procedure Filter_DropsNonClaudeEntries;
    [Test] procedure Filter_CaseInsensitivePrefix;
    [Test] procedure Filter_EntryWithoutEquals_PassesThrough;
    [Test] procedure Filter_EmptyInput_ReturnsEmpty;
    [Test] procedure Filter_EmptyValueAfterEquals_PreservesEquals;
    [Test] procedure Filter_PreservesOrder;

    // FormatArgvLines
    [Test] procedure Argv_HeaderExcludesArgv0;
    [Test] procedure Argv_OnePerArg;
    [Test] procedure Argv_EmptyArgs_HeaderZero;
    [Test] procedure Argv_HandlesSpacesAndPaths;

    // FormatProcessIdentityLine
    [Test] procedure ProcessId_FormatMatchesOriginal;
    [Test] procedure ProcessId_HandlesZero;

    // EnumerateEnvBlock
    [Test] procedure EnumEnvBlock_NilReturnsEmpty;
    [Test] procedure EnumEnvBlock_WalksDoubleNullTerminated;
  end;

implementation

uses
  Winapi.Windows,
  System.SysUtils,
  DelphiLsp.Diagnostics;

procedure TDiagnosticsTests.Filter_KeepsClaudePrefix;
var
  Lines: TArray<string>;
begin
  Lines := FilterClaudeEnvLines(['CLAUDE_CODE_SESSION_ID=abc']);
  Assert.IsTrue(Length(Lines) = 1, 'expected 1 line');
  Assert.AreEqual('env: CLAUDE_CODE_SESSION_ID=abc', Lines[0]);
end;

procedure TDiagnosticsTests.Filter_DropsNonClaudeEntries;
var
  Lines: TArray<string>;
begin
  Lines := FilterClaudeEnvLines(['PATH=c:\bin', 'CLAUDE_X=1', 'TEMP=foo']);
  Assert.IsTrue(Length(Lines) = 1, 'expected only the CLAUDE_X entry');
  Assert.AreEqual('env: CLAUDE_X=1', Lines[0]);
end;

procedure TDiagnosticsTests.Filter_CaseInsensitivePrefix;
var
  Lines: TArray<string>;
begin
  Lines := FilterClaudeEnvLines(['claude_lower=1', 'Claude_Mixed=2', 'CLAUDE_UPPER=3']);
  Assert.IsTrue(Length(Lines) = 3, 'expected all 3 cases to match');
  Assert.AreEqual('env: claude_lower=1', Lines[0]);
  Assert.AreEqual('env: Claude_Mixed=2', Lines[1]);
  Assert.AreEqual('env: CLAUDE_UPPER=3', Lines[2]);
end;

procedure TDiagnosticsTests.Filter_EntryWithoutEquals_PassesThrough;
var
  Lines: TArray<string>;
begin
  Lines := FilterClaudeEnvLines(['CLAUDE_NO_EQUALS']);
  Assert.IsTrue(Length(Lines) = 1, 'expected the no-equals entry to pass through');
  Assert.AreEqual('env: CLAUDE_NO_EQUALS', Lines[0]);
end;

procedure TDiagnosticsTests.Filter_EmptyInput_ReturnsEmpty;
var
  Lines: TArray<string>;
begin
  Lines := FilterClaudeEnvLines([]);
  Assert.IsTrue(Length(Lines) = 0, 'empty in -> empty out');
end;

procedure TDiagnosticsTests.Filter_EmptyValueAfterEquals_PreservesEquals;
var
  Lines: TArray<string>;
begin
  Lines := FilterClaudeEnvLines(['CLAUDE_EMPTY=']);
  Assert.IsTrue(Length(Lines) = 1, 'expected one line');
  Assert.AreEqual('env: CLAUDE_EMPTY=', Lines[0]);
end;

procedure TDiagnosticsTests.Filter_PreservesOrder;
var
  Lines: TArray<string>;
begin
  Lines := FilterClaudeEnvLines(['CLAUDE_A=1', 'PATH=skip', 'CLAUDE_B=2', 'CLAUDE_C=3']);
  Assert.IsTrue(Length(Lines) = 3, 'expected 3 CLAUDE_* entries');
  Assert.AreEqual('env: CLAUDE_A=1', Lines[0]);
  Assert.AreEqual('env: CLAUDE_B=2', Lines[1]);
  Assert.AreEqual('env: CLAUDE_C=3', Lines[2]);
end;

procedure TDiagnosticsTests.Argv_HeaderExcludesArgv0;
var
  Lines: TArray<string>;
begin
  // Args = [exe, arg1, arg2] -> "argv: 2 arg(s)" matching original ParamCount.
  Lines := FormatArgvLines(['shim.exe', '--hook-session-start', '--debug']);
  Assert.IsTrue(Length(Lines) = 4, 'expected header + 3 arg lines');
  Assert.AreEqual('argv: 2 arg(s)', Lines[0]);
end;

procedure TDiagnosticsTests.Argv_OnePerArg;
var
  Lines: TArray<string>;
begin
  Lines := FormatArgvLines(['shim.exe', '--foo', '--bar']);
  Assert.AreEqual('  argv[0]=shim.exe', Lines[1]);
  Assert.AreEqual('  argv[1]=--foo', Lines[2]);
  Assert.AreEqual('  argv[2]=--bar', Lines[3]);
end;

procedure TDiagnosticsTests.Argv_EmptyArgs_HeaderZero;
var
  Lines: TArray<string>;
begin
  Lines := FormatArgvLines([]);
  Assert.IsTrue(Length(Lines) = 1, 'expected just the header');
  Assert.AreEqual('argv: 0 arg(s)', Lines[0]);
end;

procedure TDiagnosticsTests.Argv_HandlesSpacesAndPaths;
var
  Lines: TArray<string>;
begin
  Lines := FormatArgvLines(['c:\Program Files (x86)\foo.exe', 'arg with spaces']);
  Assert.AreEqual('argv: 1 arg(s)', Lines[0]);
  Assert.AreEqual('  argv[0]=c:\Program Files (x86)\foo.exe', Lines[1]);
  Assert.AreEqual('  argv[1]=arg with spaces', Lines[2]);
end;

procedure TDiagnosticsTests.ProcessId_FormatMatchesOriginal;
begin
  Assert.AreEqual('shim pid=1234 ppid=5678',
    FormatProcessIdentityLine(1234, 5678));
end;

procedure TDiagnosticsTests.ProcessId_HandlesZero;
begin
  // Sanity: %d on a DWORD 0 stays 0, doesn't go negative or wrap.
  Assert.AreEqual('shim pid=0 ppid=0', FormatProcessIdentityLine(0, 0));
end;

procedure TDiagnosticsTests.EnumEnvBlock_NilReturnsEmpty;
var
  Entries: TArray<string>;
begin
  Entries := EnumerateEnvBlock(nil);
  Assert.IsTrue(Length(Entries) = 0, 'nil block -> empty');
end;

procedure TDiagnosticsTests.EnumEnvBlock_WalksDoubleNullTerminated;
var
  Buf: array of WideChar;
  Source: WideString;
  I: Integer;
  Entries: TArray<string>;
begin
  // Build: "A=1"#0 "B=2"#0 "CLAUDE_X=y"#0 #0
  Source := WideString('A=1') + WideChar(#0) + WideString('B=2') +
    WideChar(#0) + WideString('CLAUDE_X=y') + WideChar(#0) + WideChar(#0);
  SetLength(Buf, Length(Source));
  for I := 1 to Length(Source) do
    Buf[I - 1] := Source[I];

  Entries := EnumerateEnvBlock(PWideChar(@Buf[0]));
  Assert.IsTrue(Length(Entries) = 3, 'expected 3 entries before the terminator');
  Assert.AreEqual('A=1', Entries[0]);
  Assert.AreEqual('B=2', Entries[1]);
  Assert.AreEqual('CLAUDE_X=y', Entries[2]);
end;

initialization
  TDUnitX.RegisterTestFixture(TDiagnosticsTests);

end.
