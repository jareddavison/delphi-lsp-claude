// Copyright (c) 2026 Jared Davison. Released under the MIT License (see LICENSE).
//
// AI-generated (Claude Code). Review before trusting in production.

unit DelphiLsp.JsonUtilsTests;

interface

uses
  DUnitX.TestFramework;

type
  [TestFixture]
  TJsonUtilsTests = class
  public
    [Test] procedure ValidObject_ReturnsObject;
    [Test] procedure EmptyString_ReturnsNil;
    [Test] procedure InvalidJson_ReturnsNil;
    [Test] procedure JsonArray_ReturnsNil;
    [Test] procedure JsonScalar_ReturnsNil;
    [Test] procedure ObjectWithFields_FieldsAccessible;
    [Test] procedure NestedObject_ParsedCorrectly;
    [Test] procedure CallerOwnsResult_FreeReleasesIt;
  end;

implementation

uses
  System.SysUtils,
  System.JSON,
  DelphiLsp.JsonUtils;

procedure TJsonUtilsTests.ValidObject_ReturnsObject;
var
  Obj: TJSONObject;
begin
  Obj := TryParseJsonObject('{"k":"v"}');
  try
    Assert.IsNotNull(Obj);
  finally
    Obj.Free;
  end;
end;

procedure TJsonUtilsTests.EmptyString_ReturnsNil;
begin
  Assert.IsNull(TryParseJsonObject(''));
end;

procedure TJsonUtilsTests.InvalidJson_ReturnsNil;
begin
  Assert.IsNull(TryParseJsonObject('{ not valid'));
  Assert.IsNull(TryParseJsonObject('garbage'));
end;

procedure TJsonUtilsTests.JsonArray_ReturnsNil;
begin
  // Caller wanted an object; arrays aren't objects, return nil so the
  // type assertion `Obj := TryParseJsonObject(...)` is always safe.
  Assert.IsNull(TryParseJsonObject('[1,2,3]'));
end;

procedure TJsonUtilsTests.JsonScalar_ReturnsNil;
begin
  Assert.IsNull(TryParseJsonObject('"a string"'));
  Assert.IsNull(TryParseJsonObject('42'));
  Assert.IsNull(TryParseJsonObject('true'));
  Assert.IsNull(TryParseJsonObject('null'));
end;

procedure TJsonUtilsTests.ObjectWithFields_FieldsAccessible;
var
  Obj: TJSONObject;
begin
  Obj := TryParseJsonObject('{"name":"foo","count":3}');
  try
    Assert.IsNotNull(Obj);
    Assert.AreEqual('foo', Obj.GetValue('name').Value);
    Assert.AreEqual('3', Obj.GetValue('count').Value);
  finally
    Obj.Free;
  end;
end;

procedure TJsonUtilsTests.NestedObject_ParsedCorrectly;
var
  Obj: TJSONObject;
  Inner: TJSONValue;
begin
  Obj := TryParseJsonObject('{"outer":{"inner":"value"}}');
  try
    Assert.IsNotNull(Obj);
    Inner := Obj.GetValue('outer');
    Assert.IsTrue(Inner is TJSONObject);
    Assert.AreEqual('value',
      TJSONObject(Inner).GetValue('inner').Value);
  finally
    Obj.Free;
  end;
end;

procedure TJsonUtilsTests.CallerOwnsResult_FreeReleasesIt;
var
  Obj: TJSONObject;
begin
  // Sanity: the caller owns the returned object, so Free should not
  // raise and should not require any wrapper. (If TryParseJsonObject
  // returned a borrowed reference, freeing would double-free
  // somewhere downstream.)
  Obj := TryParseJsonObject('{"x":1}');
  Assert.IsNotNull(Obj);
  Obj.Free; // no exception, no leak — DUnitX would flag a leaked TJSONObject
  Assert.Pass('Free on returned object is safe and complete');
end;

initialization
  TDUnitX.RegisterTestFixture(TJsonUtilsTests);

end.
