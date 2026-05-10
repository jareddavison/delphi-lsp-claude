// Copyright (c) 2026 Jared Davison. Released under the MIT License (see LICENSE).
//
// AI-generated (Claude Code). Review before trusting in production.

unit DelphiLsp.SettingsResolverTests;

interface

uses
  DUnitX.TestFramework;

type
  [TestFixture]
  TSettingsResolverTests = class
  public
    // Single-input outcomes
    [Test] procedure Explicit_Only_WinsAsExplicit;
    [Test] procedure Sticky_Only_WinsAsSticky;
    [Test] procedure ZeroCandidates_NoOtherInput_IsNone;
    [Test] procedure SingleCandidate_NoOtherInput_IsSingle;
    [Test] procedure MultiCandidate_NoOtherInput_ReturnsAllCandidates;

    // Precedence
    [Test] procedure Explicit_BeatsSticky;
    [Test] procedure Explicit_BeatsCandidates;
    [Test] procedure Explicit_BeatsBoth;
    [Test] procedure Sticky_BeatsSingleCandidate;
    [Test] procedure Sticky_BeatsMultiCandidate;

    // Defaults
    [Test] procedure ResolvedPath_EmptyForNoneAndMulti;
    [Test] procedure Candidates_EmptyForNonMulti;
  end;

implementation

uses
  DelphiLsp.SettingsResolver;

procedure TSettingsResolverTests.Explicit_Only_WinsAsExplicit;
var
  R: TInitSettingsResult;
begin
  R := ResolveInitialSettings('D:\explicit.json', '', nil);
  Assert.IsTrue(R.Action = isaUseExplicit);
  Assert.AreEqual('D:\explicit.json', R.ResolvedPath);
end;

procedure TSettingsResolverTests.Sticky_Only_WinsAsSticky;
var
  R: TInitSettingsResult;
begin
  R := ResolveInitialSettings('', 'D:\sticky.json', nil);
  Assert.IsTrue(R.Action = isaUseSticky);
  Assert.AreEqual('D:\sticky.json', R.ResolvedPath);
end;

procedure TSettingsResolverTests.ZeroCandidates_NoOtherInput_IsNone;
var
  R: TInitSettingsResult;
begin
  R := ResolveInitialSettings('', '', nil);
  Assert.IsTrue(R.Action = isaNone);
  Assert.AreEqual('', R.ResolvedPath);
end;

procedure TSettingsResolverTests.SingleCandidate_NoOtherInput_IsSingle;
var
  R: TInitSettingsResult;
begin
  R := ResolveInitialSettings('', '', TArray<string>.Create('D:\only.json'));
  Assert.IsTrue(R.Action = isaUseSingleCandidate);
  Assert.AreEqual('D:\only.json', R.ResolvedPath);
end;

procedure TSettingsResolverTests.MultiCandidate_NoOtherInput_ReturnsAllCandidates;
var
  R: TInitSettingsResult;
begin
  R := ResolveInitialSettings('', '',
    TArray<string>.Create('D:\a.json', 'D:\b.json', 'D:\c.json'));
  Assert.IsTrue(R.Action = isaMultiCandidate);
  Assert.IsTrue(Length(R.Candidates) = 3, 'expected all 3 candidates returned');
  Assert.AreEqual('D:\a.json', R.Candidates[0]);
  Assert.AreEqual('D:\b.json', R.Candidates[1]);
  Assert.AreEqual('D:\c.json', R.Candidates[2]);
end;

procedure TSettingsResolverTests.Explicit_BeatsSticky;
var
  R: TInitSettingsResult;
begin
  R := ResolveInitialSettings('D:\explicit.json', 'D:\sticky.json', nil);
  Assert.IsTrue(R.Action = isaUseExplicit);
  Assert.AreEqual('D:\explicit.json', R.ResolvedPath);
end;

procedure TSettingsResolverTests.Explicit_BeatsCandidates;
var
  R: TInitSettingsResult;
begin
  R := ResolveInitialSettings('D:\explicit.json', '',
    TArray<string>.Create('D:\a.json', 'D:\b.json'));
  Assert.IsTrue(R.Action = isaUseExplicit);
  Assert.AreEqual('D:\explicit.json', R.ResolvedPath);
end;

procedure TSettingsResolverTests.Explicit_BeatsBoth;
var
  R: TInitSettingsResult;
begin
  R := ResolveInitialSettings('D:\explicit.json', 'D:\sticky.json',
    TArray<string>.Create('D:\a.json', 'D:\b.json'));
  Assert.IsTrue(R.Action = isaUseExplicit);
end;

procedure TSettingsResolverTests.Sticky_BeatsSingleCandidate;
var
  R: TInitSettingsResult;
begin
  R := ResolveInitialSettings('', 'D:\sticky.json',
    TArray<string>.Create('D:\auto.json'));
  Assert.IsTrue(R.Action = isaUseSticky);
  Assert.AreEqual('D:\sticky.json', R.ResolvedPath);
end;

procedure TSettingsResolverTests.Sticky_BeatsMultiCandidate;
var
  R: TInitSettingsResult;
begin
  R := ResolveInitialSettings('', 'D:\sticky.json',
    TArray<string>.Create('D:\a.json', 'D:\b.json', 'D:\c.json'));
  Assert.IsTrue(R.Action = isaUseSticky);
  Assert.AreEqual('D:\sticky.json', R.ResolvedPath);
end;

procedure TSettingsResolverTests.ResolvedPath_EmptyForNoneAndMulti;
var
  RNone, RMulti: TInitSettingsResult;
begin
  RNone := ResolveInitialSettings('', '', nil);
  Assert.AreEqual('', RNone.ResolvedPath);
  RMulti := ResolveInitialSettings('', '',
    TArray<string>.Create('D:\a.json', 'D:\b.json'));
  Assert.AreEqual('', RMulti.ResolvedPath);
end;

procedure TSettingsResolverTests.Candidates_EmptyForNonMulti;
var
  R: TInitSettingsResult;
begin
  // Single-candidate / sticky / explicit / none paths should not populate
  // R.Candidates — that field is reserved for the multi-candidate logging case.
  R := ResolveInitialSettings('', '', TArray<string>.Create('D:\only.json'));
  Assert.IsTrue(Length(R.Candidates) = 0,
    'single-candidate result should leave Candidates empty');

  R := ResolveInitialSettings('D:\x.json', '',
    TArray<string>.Create('D:\a.json', 'D:\b.json'));
  Assert.IsTrue(Length(R.Candidates) = 0,
    'explicit-path result should not propagate the candidate list');

  R := ResolveInitialSettings('', 'D:\s.json',
    TArray<string>.Create('D:\a.json', 'D:\b.json'));
  Assert.IsTrue(Length(R.Candidates) = 0,
    'sticky-path result should not propagate the candidate list');
end;

initialization
  TDUnitX.RegisterTestFixture(TSettingsResolverTests);

end.
