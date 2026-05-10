// Copyright (c) 2026 Jared Davison. Released under the MIT License (see LICENSE).
//
// AI-generated (Claude Code). Review before trusting in production.

unit DelphiLsp.LspSessionTests;

interface

uses
  DUnitX.TestFramework;

type
  [TestFixture]
  TLspSessionTests = class
  public
    // NextReplayId
    [Test] procedure NextReplayId_FirstCall_ReturnsLargeNegative;
    [Test] procedure NextReplayId_Monotonic;
    [Test] procedure NextReplayId_NoCollisionsAcrossManyCalls;
    [Test] procedure NextReplayId_MutatesCounterInPlace;

    // TLspSession (non-IO surface only — actual child spawning is
    // covered by manual integration testing of the shim binary).
    [Test] procedure Session_NewlyConstructed_HasNoChildAlive;
    [Test] procedure Session_DidFireConfig_DefaultsToFalse;
    [Test] procedure Session_DidFireConfig_RoundTrips;
    [Test] procedure Session_FreeWithoutStartChild_DoesNotBlock;
  end;

implementation

uses
  Winapi.Windows,
  System.SysUtils,
  DelphiLsp.LspSession;

procedure TLspSessionTests.NextReplayId_FirstCall_ReturnsLargeNegative;
var
  Counter: Integer;
  Id: Integer;
begin
  Counter := 0;
  Id := NextReplayId(Counter);
  // The id stream needs to live in a range that never collides with
  // the LSP client's positive-integer ids. -1000001 satisfies that.
  Assert.IsTrue(Id <= -1000001, 'first replay id should be < -1,000,000');
end;

procedure TLspSessionTests.NextReplayId_Monotonic;
var
  Counter: Integer;
  A, B, C: Integer;
begin
  Counter := 0;
  A := NextReplayId(Counter);
  B := NextReplayId(Counter);
  C := NextReplayId(Counter);
  Assert.IsTrue(B < A, 'B should be smaller (more negative) than A');
  Assert.IsTrue(C < B, 'C should be smaller (more negative) than B');
end;

procedure TLspSessionTests.NextReplayId_NoCollisionsAcrossManyCalls;
var
  Counter: Integer;
  I: Integer;
  Last, Cur: Integer;
begin
  Counter := 0;
  Last := NextReplayId(Counter);
  for I := 1 to 100 do
  begin
    Cur := NextReplayId(Counter);
    Assert.IsTrue(Cur <> Last, Format('collision at iter %d: %d', [I, Cur]));
    Last := Cur;
  end;
end;

procedure TLspSessionTests.NextReplayId_MutatesCounterInPlace;
var
  Counter: Integer;
begin
  Counter := 0;
  NextReplayId(Counter);
  Assert.IsTrue(Counter = 1, 'counter should advance to 1');
  NextReplayId(Counter);
  NextReplayId(Counter);
  Assert.IsTrue(Counter = 3, 'counter should advance to 3 after 3 calls');
end;

procedure TLspSessionTests.Session_NewlyConstructed_HasNoChildAlive;
var
  S: TLspSession;
begin
  // Construct with bogus handles — no I/O happens at construction
  // because TLspStream.Create just stores the handle.
  S := TLspSession.Create(0, 0);
  try
    Assert.IsFalse(S.ChildAlive,
      'a fresh session has not started a child yet');
  finally
    S.Free;
  end;
end;

procedure TLspSessionTests.Session_DidFireConfig_DefaultsToFalse;
var
  S: TLspSession;
begin
  S := TLspSession.Create(0, 0);
  try
    Assert.IsFalse(S.DidFireConfig);
  finally
    S.Free;
  end;
end;

procedure TLspSessionTests.Session_DidFireConfig_RoundTrips;
var
  S: TLspSession;
begin
  S := TLspSession.Create(0, 0);
  try
    S.DidFireConfig := True;
    Assert.IsTrue(S.DidFireConfig);
    S.DidFireConfig := False;
    Assert.IsFalse(S.DidFireConfig);
  finally
    S.Free;
  end;
end;

procedure TLspSessionTests.Session_FreeWithoutStartChild_DoesNotBlock;
var
  S: TLspSession;
  Started, Elapsed: Cardinal;
begin
  // Sanity check: destruction without ever calling StartChildConnection
  // should be near-instant. StopChildConnection's WaitForSingleObject
  // call MUST be guarded by FChildHandle <> 0 — otherwise this would
  // block 2s on a zero handle.
  Started := GetTickCount;
  S := TLspSession.Create(0, 0);
  S.Free;
  Elapsed := GetTickCount - Started;
  Assert.IsTrue(Elapsed < 500,
    Format('teardown took %d ms; expected < 500', [Elapsed]));
end;

initialization
  TDUnitX.RegisterTestFixture(TLspSessionTests);

end.
