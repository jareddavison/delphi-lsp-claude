// Copyright (c) 2026 Jared Davison. Released under the MIT License (see LICENSE).
//
// AI-generated (Claude Code). Review before trusting in production.
//
// Bounded recursive file collector with workspace-friendly skip rules.
// Replaces the duplicated CollectSettingsFiles / CollectDprojs / etc. that
// each had their own copy of the depth + skip logic.

unit DelphiLsp.Walkers;

interface

uses
  System.Generics.Collections;

const
  // Same default the previous walkers used. 6 levels handles typical
  // multi-project repo layouts (root/project/sub/component/...) without
  // recursing into deeply-nested vendor trees.
  DefaultMaxDepth = 6;

// Walk Dir recursively (bounded at MaxDepth), accumulating absolute paths
// of files whose lowercased name ends in ExtensionLower (must include the
// dot, e.g. '.dproj'). Skips:
//   - directory names starting with '.'  (e.g. .git, .vscode)
//   - node_modules, __history, __recovery
//   - Win32, Win64 (build output)
//   - .git, .svn (already covered by leading-dot, kept explicit)
// These match the workspace conventions of RAD Studio + typical Windows
// IDE setups so the walker doesn't drown in build artifacts.
procedure CollectFilesByExt(
  const Dir, ExtensionLower: string;
  Depth: Integer;
  Acc: TList<string>;
  MaxDepth: Integer = DefaultMaxDepth);

implementation

uses
  System.SysUtils;

procedure CollectFilesByExt(
  const Dir, ExtensionLower: string;
  Depth: Integer;
  Acc: TList<string>;
  MaxDepth: Integer);
var
  SR: TSearchRec;
  FullPath, NameLower: string;
  Skip: Boolean;
begin
  if Depth > MaxDepth then Exit;
  if FindFirst(IncludeTrailingPathDelimiter(Dir) + '*', faAnyFile, SR) = 0 then
  try
    repeat
      if (SR.Name = '.') or (SR.Name = '..') then Continue;
      NameLower := LowerCase(SR.Name);
      Skip := (Length(SR.Name) > 0) and (SR.Name[1] = '.');
      if not Skip then
        Skip := (NameLower = 'node_modules') or (NameLower = '__history') or
                (NameLower = '__recovery') or (NameLower = 'win32') or
                (NameLower = 'win64') or (NameLower = '.git') or (NameLower = '.svn');
      if Skip then Continue;
      FullPath := IncludeTrailingPathDelimiter(Dir) + SR.Name;
      if (SR.Attr and faDirectory) <> 0 then
        CollectFilesByExt(FullPath, ExtensionLower, Depth + 1, Acc, MaxDepth)
      else if NameLower.EndsWith(ExtensionLower) then
        Acc.Add(FullPath);
    until FindNext(SR) <> 0;
  finally
    FindClose(SR);
  end;
end;

end.
