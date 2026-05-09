// Copyright (c) 2026 Jared Davison. Released under the MIT License (see LICENSE).
//
// AI-generated (Claude Code). Review before trusting in production.

unit DelphiLsp.LspWireTests;

interface

uses
  DUnitX.TestFramework;

type
  [TestFixture]
  TLspWireTests = class
  public
    // WriteMessage
    [Test] procedure WriteMessage_EmitsContentLengthAndJson;
    [Test] procedure WriteMessage_EmptyJson;
    [Test] procedure WriteMessage_Utf8MultiByteCountedInBytes;
    [Test] procedure WriteMessage_NoExtraTrailingBytes;

    // ReadMessage
    [Test] procedure ReadMessage_ParsesSimpleFrame;
    [Test] procedure ReadMessage_HandlesExtraHeaderLines;
    [Test] procedure ReadMessage_CaseInsensitiveHeaderName;
    [Test] procedure ReadMessage_MissingContentLengthFails;
    [Test] procedure ReadMessage_NonNumericContentLengthFails;
    [Test] procedure ReadMessage_HeaderOver8KBAborts;
    [Test] procedure ReadMessage_ZeroLengthBody;
    [Test] procedure ReadMessage_TruncatedBodyFails;
    [Test] procedure ReadMessage_RestoresUtf8MultiByte;

    // Round-trip
    [Test] procedure RoundTrip_PreservesPayload;
    [Test] procedure RoundTrip_TwoSequentialMessages;
  end;

implementation

uses
  System.SysUtils,
  System.Classes,
  DelphiLsp.LspWire;

{ Helpers }

function MakeWriteStream: TStringStream;
begin
  // Stream defaults to UTF-8 but TLspStream writes raw bytes via WriteBuffer,
  // so encoding only matters when we read DataString back via Bytes.
  Result := TStringStream.Create('', TEncoding.UTF8);
end;

function MakeReadStream(const Wire: RawByteString): TStringStream;
var
  Bytes: TBytes;
begin
  SetLength(Bytes, Length(Wire));
  if Length(Wire) > 0 then
    Move(Wire[1], Bytes[0], Length(Wire));
  Result := TStringStream.Create('', TEncoding.UTF8);
  if Length(Bytes) > 0 then
    Result.WriteBuffer(Bytes[0], Length(Bytes));
  Result.Position := 0;
end;

function StreamBytes(SS: TStringStream): TBytes;
begin
  Result := SS.Bytes;
  // SS.Bytes returns the buffer with capacity-padding; trim to Size.
  SetLength(Result, SS.Size);
end;

function BytesAsAscii(const B: TBytes): string;
begin
  Result := TEncoding.ASCII.GetString(B);
end;

{ TLspWireTests }

procedure TLspWireTests.WriteMessage_EmitsContentLengthAndJson;
var
  SS: TStringStream;
  Wire: TLspStream;
  Got: string;
begin
  SS := MakeWriteStream;
  try
    Wire := TLspStream.Create(SS);
    try
      Assert.IsTrue(Wire.WriteMessage('{"x":1}'));
    finally
      Wire.Free;
    end;
    Got := BytesAsAscii(StreamBytes(SS));
    Assert.AreEqual('Content-Length: 7'#13#10#13#10'{"x":1}', Got);
  finally
    SS.Free;
  end;
end;

procedure TLspWireTests.WriteMessage_EmptyJson;
var
  SS: TStringStream;
  Wire: TLspStream;
  Got: string;
begin
  SS := MakeWriteStream;
  try
    Wire := TLspStream.Create(SS);
    try
      Assert.IsTrue(Wire.WriteMessage(''));
    finally
      Wire.Free;
    end;
    Got := BytesAsAscii(StreamBytes(SS));
    Assert.AreEqual('Content-Length: 0'#13#10#13#10, Got);
  finally
    SS.Free;
  end;
end;

procedure TLspWireTests.WriteMessage_Utf8MultiByteCountedInBytes;
var
  SS: TStringStream;
  Wire: TLspStream;
  Got: string;
  Payload: string;
begin
  // Build via explicit code point (U+00E9 = 'é') so the source file's encoding
  // doesn't muddy the test. UTF-8 of é is two bytes (0xC3, 0xA9).
  Payload := '"caf' + Char($00E9) + '"';
  SS := MakeWriteStream;
  try
    Wire := TLspStream.Create(SS);
    try
      Assert.IsTrue(Wire.WriteMessage(Payload));
    finally
      Wire.Free;
    end;
    Got := BytesAsAscii(StreamBytes(SS));
    // Header reports BYTES not chars: '"' + c + a + f + é (2 bytes) + '"' = 7 bytes
    Assert.IsTrue(Got.StartsWith('Content-Length: 7'#13#10#13#10),
      'header must count UTF-8 bytes, got: ' + Got);
  finally
    SS.Free;
  end;
end;

procedure TLspWireTests.WriteMessage_NoExtraTrailingBytes;
var
  SS: TStringStream;
  Wire: TLspStream;
const
  Payload = '{"a":42}';
begin
  SS := MakeWriteStream;
  try
    Wire := TLspStream.Create(SS);
    try
      Wire.WriteMessage(Payload);
    finally
      Wire.Free;
    end;
    // header (Content-Length: 8\r\n\r\n = 21 bytes) + 8 body bytes = 29 total
    Assert.AreEqual(Int64(29), SS.Size);
  finally
    SS.Free;
  end;
end;

procedure TLspWireTests.ReadMessage_ParsesSimpleFrame;
var
  SS: TStringStream;
  Wire: TLspStream;
  Json: string;
begin
  SS := MakeReadStream('Content-Length: 7'#13#10#13#10'{"x":1}');
  try
    Wire := TLspStream.Create(SS);
    try
      Assert.IsTrue(Wire.ReadMessage(Json));
      Assert.AreEqual('{"x":1}', Json);
    finally
      Wire.Free;
    end;
  finally
    SS.Free;
  end;
end;

procedure TLspWireTests.ReadMessage_HandlesExtraHeaderLines;
var
  SS: TStringStream;
  Wire: TLspStream;
  Json: string;
begin
  // The LSP spec also allows Content-Type before/after Content-Length.
  SS := MakeReadStream(
    'Content-Type: application/vscode-jsonrpc; charset=utf-8'#13#10 +
    'Content-Length: 5'#13#10 +
    #13#10 +
    '"hi!"');
  try
    Wire := TLspStream.Create(SS);
    try
      Assert.IsTrue(Wire.ReadMessage(Json));
      Assert.AreEqual('"hi!"', Json);
    finally
      Wire.Free;
    end;
  finally
    SS.Free;
  end;
end;

procedure TLspWireTests.ReadMessage_CaseInsensitiveHeaderName;
var
  SS: TStringStream;
  Wire: TLspStream;
  Json: string;
begin
  SS := MakeReadStream('content-length: 3'#13#10#13#10'{}'#10);
  try
    Wire := TLspStream.Create(SS);
    try
      Assert.IsTrue(Wire.ReadMessage(Json));
      Assert.AreEqual('{}'#10, Json);
    finally
      Wire.Free;
    end;
  finally
    SS.Free;
  end;
end;

procedure TLspWireTests.ReadMessage_MissingContentLengthFails;
var
  SS: TStringStream;
  Wire: TLspStream;
  Json: string;
begin
  SS := MakeReadStream('X-Other: 1'#13#10#13#10'{}');
  try
    Wire := TLspStream.Create(SS);
    try
      Assert.IsFalse(Wire.ReadMessage(Json),
        'must reject a frame with no Content-Length header');
    finally
      Wire.Free;
    end;
  finally
    SS.Free;
  end;
end;

procedure TLspWireTests.ReadMessage_NonNumericContentLengthFails;
var
  SS: TStringStream;
  Wire: TLspStream;
  Json: string;
begin
  SS := MakeReadStream('Content-Length: abc'#13#10#13#10'{}');
  try
    Wire := TLspStream.Create(SS);
    try
      Assert.IsFalse(Wire.ReadMessage(Json));
    finally
      Wire.Free;
    end;
  finally
    SS.Free;
  end;
end;

procedure TLspWireTests.ReadMessage_HeaderOver8KBAborts;
var
  SS: TStringStream;
  Wire: TLspStream;
  Big: RawByteString;
  Json: string;
  I: Integer;
begin
  // Build a header line that grows past the 8 KB cap with no terminating CRLFCRLF.
  Big := 'X-Pad: ';
  for I := 1 to 9000 do
    Big := Big + 'a';
  Big := Big + #13#10;
  SS := MakeReadStream(Big);
  try
    Wire := TLspStream.Create(SS);
    try
      Assert.IsFalse(Wire.ReadMessage(Json),
        'must abort once the header buffer exceeds 8 KB');
    finally
      Wire.Free;
    end;
  finally
    SS.Free;
  end;
end;

procedure TLspWireTests.ReadMessage_ZeroLengthBody;
var
  SS: TStringStream;
  Wire: TLspStream;
  Json: string;
begin
  // Pathological but legal — Content-Length: 0 means an empty body.
  SS := MakeReadStream('Content-Length: 0'#13#10#13#10);
  try
    Wire := TLspStream.Create(SS);
    try
      Assert.IsTrue(Wire.ReadMessage(Json));
      Assert.AreEqual('', Json);
    finally
      Wire.Free;
    end;
  finally
    SS.Free;
  end;
end;

procedure TLspWireTests.ReadMessage_TruncatedBodyFails;
var
  SS: TStringStream;
  Wire: TLspStream;
  Json: string;
begin
  // Header advertises 10 bytes but only 3 follow.
  SS := MakeReadStream('Content-Length: 10'#13#10#13#10'abc');
  try
    Wire := TLspStream.Create(SS);
    try
      Assert.IsFalse(Wire.ReadMessage(Json),
        'must fail when body is shorter than Content-Length advertises');
    finally
      Wire.Free;
    end;
  finally
    SS.Free;
  end;
end;

procedure TLspWireTests.ReadMessage_RestoresUtf8MultiByte;
var
  SS: TStringStream;
  Wire: TLspStream;
  Json: string;
  Expected: string;
begin
  // Body wire bytes: " c a f 0xC3 0xA9 " (UTF-8 encoding of "café"). The
  // RawByteString cast in MakeReadStream preserves these bytes verbatim;
  // the expected string is built from an explicit code point so the source
  // file's encoding doesn't muddy the comparison.
  Expected := '"caf' + Char($00E9) + '"';
  SS := MakeReadStream('Content-Length: 7'#13#10#13#10'"caf' + #$C3#$A9 + '"');
  try
    Wire := TLspStream.Create(SS);
    try
      Assert.IsTrue(Wire.ReadMessage(Json));
      Assert.AreEqual(Expected, Json);
    finally
      Wire.Free;
    end;
  finally
    SS.Free;
  end;
end;

procedure TLspWireTests.RoundTrip_PreservesPayload;
var
  SS: TStringStream;
  Writer, Reader: TLspStream;
  RoundTripped: string;
const
  Payload = '{"jsonrpc":"2.0","id":1,"method":"hello","params":{"x":42,"y":"héllo"}}';
begin
  SS := MakeWriteStream;
  try
    Writer := TLspStream.Create(SS);
    try
      Writer.WriteMessage(Payload);
    finally
      Writer.Free;
    end;
    SS.Position := 0;
    Reader := TLspStream.Create(SS);
    try
      Assert.IsTrue(Reader.ReadMessage(RoundTripped));
      Assert.AreEqual(Payload, RoundTripped);
    finally
      Reader.Free;
    end;
  finally
    SS.Free;
  end;
end;

procedure TLspWireTests.RoundTrip_TwoSequentialMessages;
var
  SS: TStringStream;
  Writer, Reader: TLspStream;
  Got1, Got2: string;
begin
  SS := MakeWriteStream;
  try
    Writer := TLspStream.Create(SS);
    try
      Writer.WriteMessage('"first"');
      Writer.WriteMessage('"second"');
    finally
      Writer.Free;
    end;
    SS.Position := 0;
    Reader := TLspStream.Create(SS);
    try
      Assert.IsTrue(Reader.ReadMessage(Got1));
      Assert.IsTrue(Reader.ReadMessage(Got2));
      Assert.AreEqual('"first"', Got1);
      Assert.AreEqual('"second"', Got2);
    finally
      Reader.Free;
    end;
  finally
    SS.Free;
  end;
end;

initialization
  TDUnitX.RegisterTestFixture(TLspWireTests);

end.
