// Path manipulation helpers used across the shim. All pure functions —
// no filesystem access, no global state.

unit DelphiLsp.Paths;

interface

// Convert a Windows path to a `file:///` URI. Replaces backslashes with
// forward slashes and percent-encodes any character outside the LSP-safe
// allowlist (`A-Za-z0-9/-_.~:`).
function PathToFileUri(const Path: string): string;

// Reverse of PathToFileUri. Strips the `file:///` prefix, decodes %xx
// sequences, replaces forward slashes with backslashes. Returns '' if the
// prefix doesn't match. Doesn't validate the rest — assumes well-formed
// input from `.delphilsp.json` or hook payloads.
function FileUriToPath(const Uri: string): string;

// Reduce a workspace cwd to a comparable form for sticky-bindings keying.
// Lowercase + ExcludeTrailingPathDelimiter. Two shim processes spawned in
// the same directory must produce the same hash regardless of casing or
// trailing slash.
function NormalizeCwd(const Cwd: string): string;

// Reduce a workspace cwd to a comparable form across Windows and MinGW
// formats. The shim sees `D:\Documents\TestDproj`; MinGW bash hooks emit
// `/d/Documents/TestDproj`. Both should compare equal:
//   D:\Documents\TestDproj    → d/documents/testdproj
//   /d/Documents/TestDproj    → d/documents/testdproj
// Lowercase + slash-normalize + strip drive colon + strip leading/trailing /.
function CanonicalizeCwd(const Cwd: string): string;

implementation

uses
  System.SysUtils;

function PathToFileUri(const Path: string): string;
var
  Normalized, Encoded: string;
  I: Integer;
  Ch: Char;
begin
  Normalized := StringReplace(Path, '\', '/', [rfReplaceAll]);
  Encoded := '';
  for I := 1 to Length(Normalized) do
  begin
    Ch := Normalized[I];
    case Ch of
      'A'..'Z', 'a'..'z', '0'..'9', '/', '-', '_', '.', '~', ':':
        Encoded := Encoded + Ch;
    else
      Encoded := Encoded + '%' + IntToHex(Ord(Ch), 2);
    end;
  end;
  Result := 'file:///' + Encoded;
end;

function FileUriToPath(const Uri: string): string;
const
  Prefix = 'file:///';
var
  Decoded: string;
  I, HexVal, Len: Integer;
begin
  Result := '';
  if Length(Uri) < Length(Prefix) then Exit;
  if not SameText(Copy(Uri, 1, Length(Prefix)), Prefix) then Exit;
  Decoded := Copy(Uri, Length(Prefix) + 1, MaxInt);
  Result := '';
  I := 1;
  Len := Length(Decoded);
  while I <= Len do
  begin
    if (Decoded[I] = '%') and (I + 2 <= Len) and
       TryStrToInt('$' + Copy(Decoded, I + 1, 2), HexVal) then
    begin
      Result := Result + Char(HexVal);
      Inc(I, 3);
    end
    else
    begin
      Result := Result + Decoded[I];
      Inc(I);
    end;
  end;
  Result := StringReplace(Result, '/', '\', [rfReplaceAll]);
end;

function NormalizeCwd(const Cwd: string): string;
begin
  Result := ExcludeTrailingPathDelimiter(LowerCase(Cwd));
end;

function CanonicalizeCwd(const Cwd: string): string;
begin
  Result := LowerCase(Cwd);
  Result := StringReplace(Result, '\', '/', [rfReplaceAll]);
  if (Length(Result) >= 2) and (Result[2] = ':') then
    Delete(Result, 2, 1);
  while (Length(Result) > 0) and (Result[1] = '/') do
    Delete(Result, 1, 1);
  while (Length(Result) > 0) and (Result[Length(Result)] = '/') do
    Delete(Result, Length(Result), 1);
end;

end.
