// Copyright (c) 2026 Jared Davison. Released under the MIT License (see LICENSE).
//
// AI-generated (Claude Code). Review before trusting in production.
//
// Decides which `.delphilsp.json` (if any) the shim should load at
// startup, given three pre-collected inputs:
//
//   ExplicitFromEnv  — DELPHI_LSP_SETTINGS env var, only set when the
//                      caller has already verified the file exists.
//   StickyFromState  — sticky pick read for the current cwd from
//                      session-state/<id>.json (or '' when no entry).
//   Candidates       — auto-discovered .delphilsp.json paths in cwd.
//
// Precedence: explicit > sticky > single auto-pick. With 0 candidates
// and no other input, the shim runs project-less. With >1 candidates
// and no other input, the resolver returns the full candidate list so
// the caller can log it; the SessionStart hook is responsible for the
// AskUserQuestion picker prompt — this resolver doesn't drive UI.
//
// All side effects (Diag, TActiveProject creation, sticky write-back)
// stay in the caller. Tests can cover the decision tree directly with
// no filesystem.

unit DelphiLsp.SettingsResolver;

interface

type
  TInitSettingsAction = (
    isaUseExplicit,        // ExplicitFromEnv won; ResolvedPath = explicit value
    isaUseSticky,          // StickyFromState won; ResolvedPath = sticky value
    isaUseSingleCandidate, // exactly one candidate; ResolvedPath = Candidates[0]
    isaNone,               // no candidates and no other input
    isaMultiCandidate      // >1 candidates; full list in Candidates
  );

  TInitSettingsResult = record
    Action: TInitSettingsAction;
    ResolvedPath: string;
    Candidates: TArray<string>;
  end;

// Pure decision function — no I/O.
function ResolveInitialSettings(
  const ExplicitFromEnv: string;
  const StickyFromState: string;
  const Candidates: TArray<string>): TInitSettingsResult;

implementation

function ResolveInitialSettings(
  const ExplicitFromEnv: string;
  const StickyFromState: string;
  const Candidates: TArray<string>): TInitSettingsResult;
begin
  Result.ResolvedPath := '';
  Result.Candidates := nil;

  if ExplicitFromEnv <> '' then
  begin
    Result.Action := isaUseExplicit;
    Result.ResolvedPath := ExplicitFromEnv;
    Exit;
  end;

  if StickyFromState <> '' then
  begin
    Result.Action := isaUseSticky;
    Result.ResolvedPath := StickyFromState;
    Exit;
  end;

  case Length(Candidates) of
    0: Result.Action := isaNone;
    1:
    begin
      Result.Action := isaUseSingleCandidate;
      Result.ResolvedPath := Candidates[0];
    end;
  else
    Result.Action := isaMultiCandidate;
    Result.Candidates := Candidates;
  end;
end;

end.
