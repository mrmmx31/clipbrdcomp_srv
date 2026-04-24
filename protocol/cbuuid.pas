{ cbuuid.pas — Geração e manipulação de UUIDs v4
  Funciona em Linux (lê /dev/urandom) e Win32 (usa random + GetTickCount).
  Compilável com FPC 3.x para linux-x86_64 e i386-win32. }

unit cbuuid;

{$mode objfpc}{$H+}

interface

uses cbprotocol;

{ Gera um UUID v4 aleatório (RFC 4122) }
function GenerateUUID: TNodeID;

{ Formata UUID no estilo padrão: xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx }
function UUIDToString(const N: TNodeID): string;

{ Parseia string UUID (com ou sem hífens) para TNodeID }
function StringToUUID(const S: string; out N: TNodeID): Boolean;

implementation

uses SysUtils
{$IFDEF UNIX}, BaseUnix{$ENDIF}
{$IFDEF WINDOWS}, Windows{$ENDIF};

{ ── Geração de bytes aleatórios ─────────────────────────────────────────────── }

{$IFDEF UNIX}
function GetRandomBytes(out Buf; Len: Integer): Boolean;
var F: Integer; Got: ssize_t;
begin
  Result := False;
  F := FpOpen('/dev/urandom', O_RDONLY);
  if F < 0 then begin
    { fallback: /dev/random (bloqueante, mas confiável) }
    F := FpOpen('/dev/random', O_RDONLY);
    if F < 0 then Exit;
  end;
  Got := FpRead(F, Buf, Len);
  FpClose(F);
  Result := (Got = Len);
end;
{$ENDIF}

{$IFDEF WINDOWS}
function GetRandomBytes(out Buf; Len: Integer): Boolean;
var P: PByte; i: Integer; Tick, Pid: LongWord;
begin
  { Win98 não tem CryptGenRandom de forma confiável sem importação.
    Usamos uma mistura de GetTickCount, GetCurrentProcessId e Random
    do FPC. Suficiente para gerar um UUID único por instalação. }
  Tick := GetTickCount;
  Pid  := GetCurrentProcessId;
  RandSeed := Integer(Tick xor (Pid shl 16));
  P := @Buf;
  for i := 0 to Len - 1 do
    P[i] := Byte(Random(256));
  Result := True;
end;
{$ENDIF}

{ ── GenerateUUID (RFC 4122, versão 4) ───────────────────────────────────────── }

function GenerateUUID: TNodeID;
var i: Integer;
begin
  FillChar(Result, SizeOf(Result), 0);
  if not GetRandomBytes(Result, 16) then begin
    for i := 0 to 15 do
      Result[i] := Byte(Random(256));
  end;
  { Fixar bits de versão e variante conforme RFC 4122 }
  Result[6] := (Result[6] and $0F) or $40;  { versão 4 }
  Result[8] := (Result[8] and $3F) or $80;  { variante RFC 4122 }
end;

{ ── Formatação ───────────────────────────────────────────────────────────────── }

function UUIDToString(const N: TNodeID): string;
{ Formato: xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx }
var H: string;
begin
  H := NodeIDToHex(N);
  Result := Copy(H, 1, 8)  + '-' +
            Copy(H, 9, 4)  + '-' +
            Copy(H, 13, 4) + '-' +
            Copy(H, 17, 4) + '-' +
            Copy(H, 21, 12);
end;

function StringToUUID(const S: string; out N: TNodeID): Boolean;
var Clean: string; C: Char;
begin
  { Remove hífens, verifica comprimento }
  Clean := '';
  for C in S do
    if C <> '-' then
      Clean := Clean + C;
  Result := HexToNodeID(Clean, N);
end;

end.
