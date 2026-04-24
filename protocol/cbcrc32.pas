{ cbcrc32.pas — Implementação CRC32 (polinômio IEEE 802.3)
  Puro Pascal, sem dependências. Compilável em todos os alvos FPC. }

unit cbcrc32;

{$mode objfpc}{$H+}

interface

{ Calcula CRC32 de um buffer de bytes.
  Init = valor inicial (padrão $FFFFFFFF para CRC32 padrão).
  Para calcular incremental: passe o resultado anterior como Init. }
function CRC32Buffer(Data: Pointer; Len: Integer): LongWord;
function CRC32Update(CRC: LongWord; Data: Pointer; Len: Integer): LongWord;
function CRC32Finalize(CRC: LongWord): LongWord; inline;

{ Conveniência: calcula CRC32 de um TBytes }
function CRC32Bytes(const Data: array of Byte; Len: Integer): LongWord;

implementation

var
  CRC32Table: array[0..255] of LongWord;
  TableBuilt: Boolean = False;

procedure BuildTable;
var i, j: Integer; C: LongWord;
begin
  for i := 0 to 255 do begin
    C := LongWord(i);
    for j := 0 to 7 do begin
      if (C and 1) <> 0 then
        C := $EDB88320 xor (C shr 1)
      else
        C := C shr 1;
    end;
    CRC32Table[i] := C;
  end;
  TableBuilt := True;
end;

function CRC32Update(CRC: LongWord; Data: Pointer; Len: Integer): LongWord;
var P: PByte; i: Integer;
begin
  if not TableBuilt then BuildTable;
  P := PByte(Data);
  CRC := CRC xor $FFFFFFFF;
  for i := 0 to Len - 1 do begin
    CRC := CRC32Table[(CRC xor P[i]) and $FF] xor (CRC shr 8);
  end;
  Result := CRC xor $FFFFFFFF;
end;

function CRC32Finalize(CRC: LongWord): LongWord; inline;
begin
  Result := CRC;  { já finalizado em CRC32Update }
end;

function CRC32Buffer(Data: Pointer; Len: Integer): LongWord;
begin
  Result := CRC32Update($FFFFFFFF xor $FFFFFFFF, Data, Len);
  { equivalente a: CRC := $FFFFFFFF; loop; CRC xor $FFFFFFFF }
  { mas como CRC32Update já faz o init e finalize, passamos 0:
    na verdade CRC32Update faz XOR $FFFFFFFF no inicio e no fim,
    então passamos 0 e ele já funciona como CRC32 padrão }
end;

function CRC32Bytes(const Data: array of Byte; Len: Integer): LongWord;
begin
  if Len = 0 then
    Result := CRC32Buffer(nil, 0)
  else
    Result := CRC32Buffer(@Data[0], Len);
end;

initialization
  BuildTable;

end.
