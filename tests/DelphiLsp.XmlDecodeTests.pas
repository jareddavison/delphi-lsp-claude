// Copyright (c) 2026 Jared Davison. Released under the MIT License (see LICENSE).
//
// AI-generated (Claude Code). Review before trusting in production.

unit DelphiLsp.XmlDecodeTests;

interface

uses
  DUnitX.TestFramework;

type
  [TestFixture]
  TXmlDecodeTests = class
  public
    [Test]
    procedure NoEntities_ReturnsAsIs;
    [Test]
    procedure AmpEntity_DecodesToAmpersand;
    [Test]
    procedure AllNamedEntities_Decode;
    [Test]
    procedure DecimalNumericRef_Decodes;
    [Test]
    procedure HexNumericRef_Decodes;
    [Test]
    procedure StrayAmpersand_PassesThroughLiterally;
    [Test]
    procedure UnknownEntity_PassesThroughLiterally;
    [Test]
    procedure WindowsPathWithAmp_Decodes;
    [Test]
    procedure EmptyString_ReturnsEmpty;
    [Test]
    procedure MultipleAdjacentEntities_Decode;
  end;

implementation

uses
  DelphiLsp.XmlDecode;

procedure TXmlDecodeTests.NoEntities_ReturnsAsIs;
begin
  Assert.AreEqual('hello world', XmlDecode('hello world'));
end;

procedure TXmlDecodeTests.AmpEntity_DecodesToAmpersand;
begin
  Assert.AreEqual('a&b', XmlDecode('a&amp;b'));
end;

procedure TXmlDecodeTests.AllNamedEntities_Decode;
begin
  Assert.AreEqual('& " '' < >', XmlDecode('&amp; &quot; &apos; &lt; &gt;'));
end;

procedure TXmlDecodeTests.DecimalNumericRef_Decodes;
begin
  Assert.AreEqual('A', XmlDecode('&#65;'));
end;

procedure TXmlDecodeTests.HexNumericRef_Decodes;
begin
  Assert.AreEqual('A', XmlDecode('&#x41;'));
end;

procedure TXmlDecodeTests.StrayAmpersand_PassesThroughLiterally;
begin
  Assert.AreEqual('a&b', XmlDecode('a&b'));
end;

procedure TXmlDecodeTests.UnknownEntity_PassesThroughLiterally;
begin
  Assert.AreEqual('&unknown;', XmlDecode('&unknown;'));
end;

procedure TXmlDecodeTests.WindowsPathWithAmp_Decodes;
begin
  Assert.AreEqual('C:\Foo & Bar\Unit.pas',
    XmlDecode('C:\Foo &amp; Bar\Unit.pas'));
end;

procedure TXmlDecodeTests.EmptyString_ReturnsEmpty;
begin
  Assert.AreEqual('', XmlDecode(''));
end;

procedure TXmlDecodeTests.MultipleAdjacentEntities_Decode;
begin
  Assert.AreEqual('<<>>', XmlDecode('&lt;&lt;&gt;&gt;'));
end;

initialization
  TDUnitX.RegisterTestFixture(TXmlDecodeTests);

end.
