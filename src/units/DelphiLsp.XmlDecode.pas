// Copyright (c) 2026 Jared Davison. Released under the MIT License (see LICENSE).
//
// AI-generated (Claude Code). Review before trusting in production.
//
// Decodes the five named XML entities (&amp; &lt; &gt; &quot; &apos;) plus
// numeric character references (&#NN; / &#xNN;). Stray ampersands and
// unknown entities pass through literally.
//
// Used by the dproj parser (FindOwningDelphilspJsons) to handle paths in
// `<DCCReference Include="..."/>` attributes when a third-party .dproj
// generator emits strict XML. The IDE rarely needs entities since typical
// Windows paths don't contain `&` `<` `>`, but generators may encode them.

unit DelphiLsp.XmlDecode;

interface

function XmlDecode(const S: string): string;

implementation

uses
  System.SysUtils, System.Classes;

function XmlDecode(const S: string): string;
const
  Names: array[0..4] of string =
    ('&amp;', '&quot;', '&apos;', '&lt;', '&gt;');
  DecodedChars: array[0..4] of string =
    ('&',     '"',      '''',     '<',    '>');
var
  I, J, SemiPos, CodePoint: Integer;
  EntityStr: string;
  Buf: TStringBuilder;
  Matched: Boolean;
begin
  if Pos('&', S) = 0 then Exit(S); // fast path: no entities possible
  Buf := TStringBuilder.Create;
  try
    I := 1;
    while I <= Length(S) do
    begin
      if S[I] <> '&' then
      begin
        Buf.Append(S[I]);
        Inc(I);
        Continue;
      end;
      // Find ';' within a 12-char window (longest standard entity is &quot; = 6).
      SemiPos := 0;
      J := I + 1;
      while (J <= Length(S)) and (J - I <= 12) do
      begin
        if S[J] = ';' then
        begin
          SemiPos := J;
          Break;
        end;
        Inc(J);
      end;
      if SemiPos = 0 then
      begin
        Buf.Append(S[I]);
        Inc(I);
        Continue;
      end;
      EntityStr := Copy(S, I, SemiPos - I + 1);
      Matched := False;
      // Numeric: &#123; (decimal) or &#xAB; (hex)
      if (Length(EntityStr) >= 4) and (EntityStr[2] = '#') then
      begin
        if (EntityStr[3] = 'x') or (EntityStr[3] = 'X') then
        begin
          if TryStrToInt('$' + Copy(EntityStr, 4, Length(EntityStr) - 4),
                         CodePoint) then
          begin
            Buf.Append(Char(CodePoint));
            Matched := True;
          end;
        end
        else if TryStrToInt(Copy(EntityStr, 3, Length(EntityStr) - 3),
                            CodePoint) then
        begin
          Buf.Append(Char(CodePoint));
          Matched := True;
        end;
      end;
      // Named: 5 standard XML entities
      if not Matched then
      begin
        for J := Low(Names) to High(Names) do
          if Names[J] = EntityStr then
          begin
            Buf.Append(DecodedChars[J]);
            Matched := True;
            Break;
          end;
      end;
      if Matched then
        I := SemiPos + 1
      else
      begin
        Buf.Append(S[I]);
        Inc(I);
      end;
    end;
    Result := Buf.ToString;
  finally
    Buf.Free;
  end;
end;

end.
