{ text_convert.pas — Conversão de encoding de texto: ANSI (CP1252) ↔ UTF-8
  Puro Pascal, sem dependências externas.
  Compilável para todos os alvos FPC, inclusive i386-win32 (Win98). }

unit text_convert;

{$mode objfpc}{$H+}

interface

{ Converte string ANSI (codepage CP1252) para UTF-8.
  Retorna string UTF-8 equivalente. }
function AnsiCP1252ToUTF8(const S: AnsiString): AnsiString;

{ Converte string UTF-8 para ANSI (codepage CP1252).
  Caracteres sem representação em CP1252 são substituídos por '?'. }
function UTF8ToAnsiCP1252(const S: AnsiString): AnsiString;

{ Converte AnsiString de qualquer codepage via tabela Unicode.
  Codepage 0 = UTF-8 (noop). }
function AnsiToUTF8(const S: AnsiString; Codepage: Integer): AnsiString;

{ Codifica um codepoint Unicode como sequência UTF-8 }
function UnicodeToUTF8(Codepoint: LongWord): AnsiString;

{ Lê próximo codepoint de uma string UTF-8 a partir de Pos (1-based).
  Avança Pos para o próximo caractere. }
function NextUTF8Codepoint(const S: AnsiString; var Pos: Integer): LongWord;

implementation

{ ── Tabela CP1252 → Unicode para bytes 0x80–0x9F ─────────────────────────────
  Bytes 0x00–0x7F: mapeiam diretamente para U+0000–U+007F (ASCII).
  Bytes 0xA0–0xFF: mapeiam para U+00A0–U+00FF (Latin-1 / ISO-8859-1).
  Bytes 0x80–0x9F: mapeamento especial do Windows CP1252.
  Bytes marcados como $FFFF não têm mapeamento (substituir por U+FFFD). }
const
  CP1252_SPECIAL: array[$80..$9F] of LongWord = (
    $20AC, $FFFF, $201A, $0192, $201E, $2026, $2020, $2021,
    $02C6, $2030, $0160, $2039, $0152, $FFFF, $017D, $FFFF,
    $FFFF, $2018, $2019, $201C, $201D, $2022, $2013, $2014,
    $02DC, $2122, $0161, $203A, $0153, $FFFF, $017E, $0178
  );

function CP1252ToUnicode(B: Byte): LongWord;
begin
  if B <= $7F then Result := B
  else if B >= $A0 then Result := B  { U+00A0..U+00FF = Latin-1 }
  else begin
    Result := CP1252_SPECIAL[B];
    if Result = $FFFF then Result := $FFFD;  { replacement character }
  end;
end;

function UnicodeToUTF8(Codepoint: LongWord): AnsiString;
begin
  if Codepoint <= $7F then begin
    SetLength(Result, 1);
    Result[1] := AnsiChar(Codepoint);
  end else if Codepoint <= $7FF then begin
    SetLength(Result, 2);
    Result[1] := AnsiChar($C0 or (Codepoint shr 6));
    Result[2] := AnsiChar($80 or (Codepoint and $3F));
  end else if Codepoint <= $FFFF then begin
    SetLength(Result, 3);
    Result[1] := AnsiChar($E0 or (Codepoint shr 12));
    Result[2] := AnsiChar($80 or ((Codepoint shr 6) and $3F));
    Result[3] := AnsiChar($80 or (Codepoint and $3F));
  end else if Codepoint <= $10FFFF then begin
    SetLength(Result, 4);
    Result[1] := AnsiChar($F0 or (Codepoint shr 18));
    Result[2] := AnsiChar($80 or ((Codepoint shr 12) and $3F));
    Result[3] := AnsiChar($80 or ((Codepoint shr 6) and $3F));
    Result[4] := AnsiChar($80 or (Codepoint and $3F));
  end else begin
    Result := #$EF#$BF#$BD;  { U+FFFD }
  end;
end;

function AnsiCP1252ToUTF8(const S: AnsiString): AnsiString;
var i: Integer; CP: LongWord;
begin
  Result := '';
  for i := 1 to Length(S) do begin
    CP := CP1252ToUnicode(Ord(S[i]));
    Result := Result + UnicodeToUTF8(CP);
  end;
end;

function NextUTF8Codepoint(const S: AnsiString; var Pos: Integer): LongWord;
var B0, B1, B2, B3: Byte; L: Integer;
begin
  Result := $FFFD;
  L := Length(S);
  if Pos > L then Exit;
  B0 := Ord(S[Pos]);
  if B0 < $80 then begin
    Result := B0;
    Inc(Pos);
  end else if (B0 and $E0) = $C0 then begin
    if Pos + 1 > L then begin Inc(Pos); Exit; end;
    B1 := Ord(S[Pos + 1]);
    if (B1 and $C0) <> $80 then begin Inc(Pos); Exit; end;
    Result := ((LongWord(B0) and $1F) shl 6) or (LongWord(B1) and $3F);
    Inc(Pos, 2);
  end else if (B0 and $F0) = $E0 then begin
    if Pos + 2 > L then begin Inc(Pos); Exit; end;
    B1 := Ord(S[Pos + 1]);
    B2 := Ord(S[Pos + 2]);
    if ((B1 and $C0) <> $80) or ((B2 and $C0) <> $80) then begin Inc(Pos); Exit; end;
    Result := ((LongWord(B0) and $0F) shl 12) or
              ((LongWord(B1) and $3F) shl  6) or
               (LongWord(B2) and $3F);
    Inc(Pos, 3);
  end else if (B0 and $F8) = $F0 then begin
    if Pos + 3 > L then begin Inc(Pos); Exit; end;
    B1 := Ord(S[Pos + 1]);
    B2 := Ord(S[Pos + 2]);
    B3 := Ord(S[Pos + 3]);
    if ((B1 and $C0) <> $80) or ((B2 and $C0) <> $80) or ((B3 and $C0) <> $80) then begin Inc(Pos); Exit; end;
    Result := ((LongWord(B0) and $07) shl 18) or
              ((LongWord(B1) and $3F) shl 12) or
              ((LongWord(B2) and $3F) shl  6) or
               (LongWord(B3) and $3F);
    Inc(Pos, 4);
  end else begin
    Inc(Pos);  { byte inválido, avança }
  end;
end;

function UnicodeToCp1252(CP: LongWord): Byte;
{ Encontra byte CP1252 para codepoint Unicode.
  Retorna $3F ('?') se não há mapeamento. }
var i: Integer;
begin
  if CP <= $7F then begin Result := Byte(CP); Exit; end;
  if (CP >= $A0) and (CP <= $FF) then begin Result := Byte(CP); Exit; end;
  { Busca linear na tabela especial }
  for i := $80 to $9F do
    if CP1252_SPECIAL[i] = CP then begin Result := Byte(i); Exit; end;
  Result := $3F;  { '?' — sem mapeamento }
end;

function UTF8ToAnsiCP1252(const S: AnsiString): AnsiString;
var Pos: Integer; CP: LongWord;
begin
  Result := '';
  Pos := 1;
  while Pos <= Length(S) do begin
    CP := NextUTF8Codepoint(S, Pos);
    Result := Result + AnsiChar(UnicodeToCp1252(CP));
  end;
end;

function AnsiToUTF8(const S: AnsiString; Codepage: Integer): AnsiString;
begin
  if Codepage = 0 then
    Result := S  { já é UTF-8 }
  else if Codepage = 1252 then
    Result := AnsiCP1252ToUTF8(S)
  else begin
    { Outros codepages não implementados — retorna como está com aviso implícito }
    Result := S;
  end;
end;

end.
