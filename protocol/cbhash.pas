{ cbhash.pas — Hashing MD5 para deduplicação de clipboard
  Wrapper sobre a unit md5 do FPC (FCL).
  Compilável em todos os alvos FPC 3.x. }

unit cbhash;

{$mode objfpc}{$H+}

interface

uses md5;

type
  { Alias explícito para clareza }
  TClipHash = TMDDigest;   { array[0..15] of Byte, 16 bytes }

{ Calcula hash MD5 de um buffer de bytes }
function HashBuffer(Data: Pointer; Len: Integer): TClipHash;

{ Calcula hash MD5 de um AnsiString }
function HashString(const S: AnsiString): TClipHash;

{ Calcula hash MD5 de um array of Byte }
function HashBytes(const B: array of Byte; Len: Integer): TClipHash;

{ Comparação }
function HashEqual(const A, B: TClipHash): Boolean;
function HashIsZero(const H: TClipHash): Boolean;

{ Formatação para log/debug }
function HashToHex(const H: TClipHash): string;
function HexToHash(const S: string; out H: TClipHash): Boolean;

{ Hash zero (indica "sem hash") }
function ZeroHash: TClipHash;

implementation

function HashBuffer(Data: Pointer; Len: Integer): TClipHash;
begin
  if (Data = nil) or (Len = 0) then
    Result := ZeroHash
  else
    Result := MD5Buffer(Data^, Len);
end;

function HashString(const S: AnsiString): TClipHash;
begin
  FillChar(Result, SizeOf(Result), 0);
  if S <> '' then
    Result := MD5String(S);
end;

function HashBytes(const B: array of Byte; Len: Integer): TClipHash;
var P: PByte;
begin
  FillChar(Result, SizeOf(Result), 0);
  if (Len = 0) or (Length(B) = 0) then Exit;
  P := @B[0];  { ponteiro evita passar 'const element' como untyped — FPC 2.6.4 compat }
  Result := HashBuffer(P, Len);
end;

function HashEqual(const A, B: TClipHash): Boolean;
var i: Integer;
begin
  Result := True;
  for i := 0 to 15 do
    if A[i] <> B[i] then begin
      Result := False;
      Exit;
    end;
end;

function HashIsZero(const H: TClipHash): Boolean;
var i: Integer;
begin
  Result := True;
  for i := 0 to 15 do
    if H[i] <> 0 then begin
      Result := False;
      Exit;
    end;
end;

function HashToHex(const H: TClipHash): string;
const HexChars: array[0..15] of Char =
  ('0','1','2','3','4','5','6','7','8','9','a','b','c','d','e','f');
var i: Integer;
begin
  SetLength(Result, 32);
  for i := 0 to 15 do begin
    Result[i*2+1] := HexChars[H[i] shr 4];
    Result[i*2+2] := HexChars[H[i] and $0F];
  end;
end;

function HexToHash(const S: string; out H: TClipHash): Boolean;
var i, hi, lo: Integer;

  function HVal(C: Char): Integer;
  begin
    case C of
      '0'..'9': Result := Ord(C) - Ord('0');
      'a'..'f': Result := Ord(C) - Ord('a') + 10;
      'A'..'F': Result := Ord(C) - Ord('A') + 10;
    else Result := -1;
    end;
  end;

begin
  Result := False;
  FillChar(H, SizeOf(H), 0);
  if Length(S) <> 32 then Exit;
  for i := 0 to 15 do begin
    hi := HVal(S[i*2+1]);
    lo := HVal(S[i*2+2]);
    if (hi < 0) or (lo < 0) then Exit;
    H[i] := Byte((hi shl 4) or lo);
  end;
  Result := True;
end;

function ZeroHash: TClipHash;
begin
  FillChar(Result, SizeOf(Result), 0);
end;

end.
