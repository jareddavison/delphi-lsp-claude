// Copyright (c) 2026 Jared Davison. Released under the MIT License (see LICENSE).
//
// AI-generated (Claude Code). Review before trusting in production.
//
// Startup diagnostic dumps. Each Dump* procedure is a thin wrapper that
// reads from the OS (env block, argv, process ids) and feeds the result
// through a pure formatter, then logs each formatted line via Diag.
// Splitting it this way keeps the formatters unit-testable while leaving
// the OS-side calls in one place.

unit DelphiLsp.Diagnostics;

interface

uses
  Winapi.Windows;

// Side-effecting wrappers — call Diag for each line they produce.
procedure DumpClaudeEnv;
procedure DumpArgv;
procedure DumpProcessIdentity;

// Pure formatters (exposed for testing).

// Filters environment entries to those whose name starts with 'CLAUDE_'
// (case-insensitive) and prepends 'env: ' to each. Entries without a
// '=' separator pass through with the prefix and no further parsing —
// matches the original DumpClaudeEnv behaviour for the special drive
// vars (=C:, =ExitCode, etc.) Windows surfaces in env blocks.
function FilterClaudeEnvLines(const Entries: TArray<string>): TArray<string>;

// Formats argv as a header line ('argv: N arg(s)') followed by one
// indented line per arg ('  argv[i]=<value>'). Args is expected to
// include argv[0] (the exe path), so N is reported as Length(Args)-1
// to match Delphi's ParamCount convention. Empty Args -> 'argv: 0 arg(s)'
// with no per-arg lines.
function FormatArgvLines(const Args: TArray<string>): TArray<string>;

// Single-line formatter for the process identity dump.
function FormatProcessIdentityLine(Pid, Ppid: DWORD): string;

// Walks a Win32 environment block (double-NUL-terminated UTF-16 string
// produced by GetEnvironmentStringsW) and returns one element per entry.
// Returns an empty array for nil. Exposed mainly so DumpClaudeEnv has
// one place to handle the OS edge cases.
function EnumerateEnvBlock(Block: PWideChar): TArray<string>;

implementation

uses
  System.SysUtils,
  DelphiLsp.Logging,
  DelphiLsp.ProcessTree;

function EnumerateEnvBlock(Block: PWideChar): TArray<string>;
var
  P: PWideChar;
  Entry: string;
  Count: Integer;
begin
  Result := nil;
  if Block = nil then Exit;
  Count := 0;
  P := Block;
  while P^ <> #0 do
  begin
    Entry := P;
    if Length(Result) <= Count then
      SetLength(Result, (Count + 1) * 2);
    Result[Count] := Entry;
    Inc(Count);
    Inc(P, Length(Entry) + 1);
  end;
  SetLength(Result, Count);
end;

function FilterClaudeEnvLines(const Entries: TArray<string>): TArray<string>;
var
  Entry: string;
  EqIdx, Count: Integer;
begin
  Result := nil;
  Count := 0;
  for Entry in Entries do
  begin
    if (Length(Entry) >= 7) and SameText(Copy(Entry, 1, 7), 'CLAUDE_') then
    begin
      if Length(Result) <= Count then
        SetLength(Result, (Count + 1) * 2);
      EqIdx := Pos('=', Entry);
      if EqIdx > 0 then
        Result[Count] := 'env: ' + Copy(Entry, 1, EqIdx - 1) + '=' +
          Copy(Entry, EqIdx + 1, MaxInt)
      else
        Result[Count] := 'env: ' + Entry;
      Inc(Count);
    end;
  end;
  SetLength(Result, Count);
end;

function FormatArgvLines(const Args: TArray<string>): TArray<string>;
var
  I, Reported: Integer;
begin
  SetLength(Result, Length(Args) + 1);
  if Length(Args) = 0 then
    Reported := 0
  else
    Reported := Length(Args) - 1;
  Result[0] := Format('argv: %d arg(s)', [Reported]);
  for I := 0 to High(Args) do
    Result[I + 1] := Format('  argv[%d]=%s', [I, Args[I]]);
end;

function FormatProcessIdentityLine(Pid, Ppid: DWORD): string;
begin
  Result := Format('shim pid=%d ppid=%d', [Pid, Ppid]);
end;

procedure DumpClaudeEnv;
var
  Block: PWideChar;
  Line: string;
begin
  Block := GetEnvironmentStringsW;
  if Block = nil then Exit;
  try
    for Line in FilterClaudeEnvLines(EnumerateEnvBlock(Block)) do
      Diag(Line);
  finally
    FreeEnvironmentStringsW(Block);
  end;
end;

procedure DumpArgv;
var
  Args: TArray<string>;
  Line: string;
  I: Integer;
begin
  SetLength(Args, ParamCount + 1);
  for I := 0 to ParamCount do
    Args[I] := ParamStr(I);
  for Line in FormatArgvLines(Args) do
    Diag(Line);
end;

procedure DumpProcessIdentity;
begin
  Diag(FormatProcessIdentityLine(GetCurrentProcessId, GetParentProcessId));
end;

end.
