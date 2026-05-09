// Copyright (c) 2026 Jared Davison. Released under the MIT License (see LICENSE).
//
// AI-generated (Claude Code). Review before trusting in production.
//
// LSP wire-protocol framing.
//
// `TLspStream` reads/writes JSON-RPC messages with the Content-Length envelope
// the Language Server Protocol mandates:
//
//     Content-Length: <N>\r\n
//     \r\n
//     <N bytes of UTF-8 JSON>
//
// Originally lived inside delphi-lsp-shim.dpr coupled to OS pipe handles.
// Pulled out so the framing logic can be exercised with `TStringStream`
// fixtures in unit tests — the same code path the shim uses against pipes
// also handles in-memory byte buffers, since both are TStream subclasses.
//
// Constructor overloads:
//   * Create(AHandle: THandle) wraps the handle in a THandleStream and owns
//     the wrapper (the OS handle itself stays with the caller — THandleStream
//     never closes it).
//   * Create(AStream: TStream; AOwnsStream: Boolean) takes an existing stream;
//     test code passes a TStringStream and keeps ownership.

unit DelphiLsp.LspWire;

interface

uses
  Winapi.Windows,
  System.Classes;

type
  TLspStream = class
  private
    FStream: TStream;
    FOwnsStream: Boolean;
  public
    constructor Create(AHandle: THandle); overload;
    constructor Create(AStream: TStream; AOwnsStream: Boolean = False); overload;
    destructor Destroy; override;
    function ReadByte(out B: Byte): Boolean;
    function ReadExact(var Buf; Count: Integer): Boolean;
    function WriteExact(const Buf; Count: Integer): Boolean;
    function ReadMessage(out Json: string): Boolean;
    function WriteMessage(const Json: string): Boolean;
  end;

implementation

uses
  System.SysUtils,
  DelphiLsp.Logging;

constructor TLspStream.Create(AHandle: THandle);
begin
  inherited Create;
  FStream := THandleStream.Create(AHandle);
  FOwnsStream := True;
end;

constructor TLspStream.Create(AStream: TStream; AOwnsStream: Boolean);
begin
  inherited Create;
  FStream := AStream;
  FOwnsStream := AOwnsStream;
end;

destructor TLspStream.Destroy;
begin
  if FOwnsStream then
    FStream.Free;
  inherited;
end;

function TLspStream.ReadByte(out B: Byte): Boolean;
var
  Got: Integer;
begin
  Got := FStream.Read(B, 1);
  Result := Got = 1;
end;

function TLspStream.ReadExact(var Buf; Count: Integer): Boolean;
var
  P: PByte;
  Got: Integer;
  Remaining: Integer;
begin
  P := @Buf;
  Remaining := Count;
  while Remaining > 0 do
  begin
    Got := FStream.Read(P^, Remaining);
    if Got <= 0 then Exit(False);
    Inc(P, Got);
    Dec(Remaining, Got);
  end;
  Result := True;
end;

function TLspStream.WriteExact(const Buf; Count: Integer): Boolean;
var
  P: PByte;
  Wrote: Integer;
  Remaining: Integer;
begin
  P := @Buf;
  Remaining := Count;
  while Remaining > 0 do
  begin
    Wrote := FStream.Write(P^, Remaining);
    if Wrote <= 0 then Exit(False);
    Inc(P, Wrote);
    Dec(Remaining, Wrote);
  end;
  Result := True;
end;

function TLspStream.ReadMessage(out Json: string): Boolean;
var
  HeaderBytes: TBytes;
  B: Byte;
  HeaderStr: string;
  Lines: TArray<string>;
  Line: string;
  ColonIdx: Integer;
  ContentLen: Integer;
  BodyBytes: TBytes;
begin
  Json := '';
  SetLength(HeaderBytes, 0);
  ContentLen := -1;
  while True do
  begin
    if not ReadByte(B) then Exit(False);
    SetLength(HeaderBytes, Length(HeaderBytes) + 1);
    HeaderBytes[High(HeaderBytes)] := B;
    if (Length(HeaderBytes) >= 4) and
       (HeaderBytes[High(HeaderBytes) - 3] = 13) and
       (HeaderBytes[High(HeaderBytes) - 2] = 10) and
       (HeaderBytes[High(HeaderBytes) - 1] = 13) and
       (HeaderBytes[High(HeaderBytes)]     = 10) then
      Break;
    if Length(HeaderBytes) > 8192 then
    begin
      Diag('LSP header exceeded 8KB; aborting read');
      Exit(False);
    end;
  end;
  HeaderStr := TEncoding.ASCII.GetString(HeaderBytes);
  Lines := HeaderStr.Split([#13#10]);
  for Line in Lines do
  begin
    ColonIdx := Pos(':', Line);
    if (ColonIdx > 0) and
       SameText(Trim(Copy(Line, 1, ColonIdx - 1)), 'Content-Length') then
    begin
      if not TryStrToInt(Trim(Copy(Line, ColonIdx + 1, MaxInt)), ContentLen) then
        ContentLen := -1;
      Break;
    end;
  end;
  if ContentLen < 0 then
  begin
    Diag('No Content-Length header found');
    Exit(False);
  end;
  if ContentLen = 0 then Exit(True);
  SetLength(BodyBytes, ContentLen);
  if not ReadExact(BodyBytes[0], ContentLen) then Exit(False);
  Json := TEncoding.UTF8.GetString(BodyBytes);
  Result := True;
end;

function TLspStream.WriteMessage(const Json: string): Boolean;
var
  Bytes: TBytes;
  Header: RawByteString;
  HeaderBytes: TBytes;
begin
  Bytes := TEncoding.UTF8.GetBytes(Json);
  Header := UTF8Encode('Content-Length: ' + IntToStr(Length(Bytes)) + #13#10#13#10);
  SetLength(HeaderBytes, Length(Header));
  if Length(Header) > 0 then
    Move(Header[1], HeaderBytes[0], Length(Header));
  if not WriteExact(HeaderBytes[0], Length(HeaderBytes)) then Exit(False);
  if Length(Bytes) > 0 then
    Result := WriteExact(Bytes[0], Length(Bytes))
  else
    Result := True;
end;

end.
