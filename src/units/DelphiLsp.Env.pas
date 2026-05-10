// Copyright (c) 2026 Jared Davison. Released under the MIT License (see LICENSE).
//
// AI-generated (Claude Code). Review before trusting in production.
//
// Tiny env-var helper. The Delphi RTL's GetEnvironmentVariable returns
// '' on missing — this wrapper adds a fallback Default for the common
// "use this if the var is unset" pattern, replacing five identical
// 4-line duplicates that had been spreading across the codebase.

unit DelphiLsp.Env;

interface

// Read environment variable Name. Returns Default if the variable is
// unset OR is set to an empty string. (The two cases are merged
// deliberately; the shim never wants to use an explicitly-empty env
// value as a meaningful signal.)
function GetEnv(const Name, Default: string): string;

implementation

uses
  System.SysUtils;

function GetEnv(const Name, Default: string): string;
begin
  Result := GetEnvironmentVariable(Name);
  if Result = '' then Result := Default;
end;

end.
