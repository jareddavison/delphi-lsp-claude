// Copyright (c) 2026 Jared Davison. Released under the MIT License (see LICENSE).
//
// AI-generated (Claude Code). Review before trusting in production.
//
// Tiny JSON helpers used across the codebase. The repeating boilerplate
//
//   Root := nil;
//   try
//     try
//       Root := TJSONObject.ParseJSONValue(Json);
//     except
//       Exit;
//     end;
//     if not (Root is TJSONObject) then Exit;
//     Obj := TJSONObject(Root);
//     // ... use Obj ...
//   finally
//     Root.Free;
//   end;
//
// reduces to:
//
//   Obj := TryParseJsonObject(Json);
//   if Obj = nil then Exit;
//   try
//     // ... use Obj ...
//   finally
//     Obj.Free;
//   end;

unit DelphiLsp.JsonUtils;

interface

uses
  System.JSON;

// Parse Json. Returns the root TJSONObject if Json parsed successfully
// AND its root is a JSON object. Returns nil on any of: empty input,
// parse failure (caught), or root that isn't an object (could be a
// JSON array or scalar). Caller owns the returned object — Free it
// when done.
//
// Silent on failure — the helper doesn't Diag because callers vary
// (some loop-Continue, some Exit, some want a custom log message).
// Wrap with your own logging if a specific failure matters.
function TryParseJsonObject(const Json: string): TJSONObject;

implementation

function TryParseJsonObject(const Json: string): TJSONObject;
var
  Root: TJSONValue;
begin
  Result := nil;
  if Json = '' then Exit;
  try
    Root := TJSONObject.ParseJSONValue(Json);
  except
    Exit;
  end;
  if Root = nil then Exit;
  if not (Root is TJSONObject) then
  begin
    Root.Free;
    Exit;
  end;
  Result := TJSONObject(Root);
end;

end.
