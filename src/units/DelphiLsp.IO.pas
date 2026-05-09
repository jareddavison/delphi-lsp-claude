// Copyright (c) 2026 Jared Davison. Released under the MIT License (see LICENSE).
//
// AI-generated (Claude Code). Review before trusting in production.
//
// Small I/O utilities used by the shim and its hook-mode entry points:
//
//   - ReadAllStdin: drain the process's stdin pipe into a byte buffer.
//     Used by SessionStart/SessionEnd hooks to read the JSON payload
//     Claude Code passes them.
//
//   - WriteFileAtomic: write text to a path via tmp + MoveFileEx so a
//     concurrent reader never sees a half-written file. Same pattern the
//     sticky bindings use; pulled into a unit so multiple call sites
//     (claude-pid drops, sticky bindings, etc.) share one implementation.

unit DelphiLsp.IO;

interface

uses
  System.SysUtils;

// Drain stdin into a byte buffer (UTF-8 / arbitrary). Returns whatever the
// caller's stdin handle yields up to EOF. Empty array if stdin is closed
// or no data was sent. Reads in 4 KB chunks.
function ReadAllStdin: TBytes;

// Atomic UTF-8 file write via tmp + MoveFileEx(MOVEFILE_REPLACE_EXISTING).
// Errors are logged via DelphiLsp.Logging.Diag and silently swallowed —
// the caller doesn't get a success indicator (best-effort semantics
// matching the dpr's earlier behavior).
procedure WriteFileAtomic(const Path, Content: string);

implementation

uses
  Winapi.Windows,
  System.Classes,
  DelphiLsp.Logging;

function ReadAllStdin: TBytes;
const
  BufSize = 4096;
var
  StdinH: THandle;
  Buf: array[0..BufSize - 1] of Byte;
  Got: DWORD;
  Total: Integer;
begin
  Total := 0;
  SetLength(Result, 0);
  StdinH := GetStdHandle(STD_INPUT_HANDLE);
  while ReadFile(StdinH, Buf[0], BufSize, Got, nil) and (Got > 0) do
  begin
    SetLength(Result, Total + Integer(Got));
    Move(Buf[0], Result[Total], Got);
    Inc(Total, Integer(Got));
  end;
end;

procedure WriteFileAtomic(const Path, Content: string);
var
  TmpPath: string;
  Bytes: TBytes;
  FS: TFileStream;
begin
  TmpPath := Path + '.tmp';
  Bytes := TEncoding.UTF8.GetBytes(Content);
  try
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
      Diag('WriteFileAtomic tmp write failed: ' + E.Message);
      Exit;
    end;
  end;
  if not MoveFileEx(PChar(TmpPath), PChar(Path), MOVEFILE_REPLACE_EXISTING) then
    Diag(Format('WriteFileAtomic MoveFileEx failed: %d', [GetLastError]));
end;

end.
