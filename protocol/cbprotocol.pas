{ cbprotocol.pas — Constantes, tipos e estruturas do protocolo ClipBrdComp v1
  Compartilhado entre broker e todos os agentes.
  Compilável com FPC 3.2.x, sem dependências externas. }

unit cbprotocol;

{$mode objfpc}{$H+}

interface

{ ── Identificação do protocolo ─────────────────────────────────────────────── }
const
  CB_MAGIC_0   = $43;   { 'C' }
  CB_MAGIC_1   = $42;   { 'B' }
  CB_VERSION   = $01;

  CB_HEADER_SIZE = 36;  { bytes do header fixo }
  CB_CRC_SIZE    = 4;   { bytes do CRC32 no fim do frame }
  CB_FRAME_OVERHEAD = CB_HEADER_SIZE + CB_CRC_SIZE; { 40 bytes }

{ ── Tipos de mensagem ───────────────────────────────────────────────────────── }
  MSG_HELLO           = $01;
  MSG_HELLO_ACK       = $02;
  MSG_AUTH            = $03;
  MSG_AUTH_ACK        = $04;
  MSG_ANNOUNCE        = $05;
  MSG_ANNOUNCE_ACK    = $06;
  MSG_CLIP_PUBLISH    = $10;
  MSG_CLIP_PUSH       = $11;
  MSG_CLIP_ACK        = $12;
  MSG_PING            = $20;
  MSG_PONG            = $21;
  MSG_ERROR           = $30;
  MSG_REQUEST_STATE   = $40;
  MSG_STATE_RESPONSE  = $41;
  MSG_SUBSCRIBE_GROUP = $50;
  MSG_SUBSCRIBE_ACK   = $51;
  MSG_POLICY_UPDATE   = $60;
  MSG_GOODBYE         = $FF;

{ ── Flags do header ─────────────────────────────────────────────────────────── }
  FLAG_COMPRESSED  = $01;
  FLAG_ENCRYPTED   = $02;  { reservado para v2 }
  FLAG_RESP_REQ    = $04;

{ ── Formatos de clipboard ───────────────────────────────────────────────────── }
  FMT_TEXT_UTF8  = $01;
  FMT_TEXT_ANSI  = $02;  { uso interno do agente, nunca na rede }
  FMT_IMAGE_PNG  = $10;
  FMT_IMAGE_BMP  = $11;  { uso interno }
  FMT_IMAGE_DIB  = $12;  { uso interno Win32 }
  FMT_HTML_UTF8  = $20;  { v1.1 }

{ ── Tipos de OS ─────────────────────────────────────────────────────────────── }
  OS_UNKNOWN       = $00;
  OS_LINUX_X11     = $01;
  OS_LINUX_WAYLAND = $02;
  OS_WIN98         = $10;
  OS_WINNT_ANSI    = $11;
  OS_WIN_MODERN    = $12;
  OS_MACOS         = $20;

{ ── Nomes dos perfis de compatibilidade ────────────────────────────────────── }
  PROF_WIN98_LEGACY  = 'WIN98_LEGACY';
  PROF_WINNT_ANSI    = 'WINNT_ANSI';
  PROF_LINUX_X11     = 'LINUX_X11';
  PROF_LINUX_WAYLAND = 'LINUX_WAYLAND_SESSION';
  PROF_WIN_MODERN    = 'WINDOWS_MODERN_UNICODE';

{ ── Bitmask de formatos suportados (campo FORMATS do ANNOUNCE) ──────────────── }
  FMTBIT_TEXT_UTF8 = $00000001;
  FMTBIT_IMAGE_PNG = $00000010;
  FMTBIT_IMAGE_BMP = $00000020;
  FMTBIT_HTML_UTF8 = $00000100;

{ ── CAP_FLAGS (campo do ANNOUNCE) ───────────────────────────────────────────── }
  CAP_COMPRESS     = $01;
  CAP_BIDIR        = $02;
  CAP_IMAGES       = $04;
  CAP_HTML         = $08;

{ ── Encoding ────────────────────────────────────────────────────────────────── }
  ENC_UTF8    = $01;
  ENC_ANSI    = $02;
  ENC_BINARY  = $03;

{ ── Status codes (HELLO_ACK, AUTH_ACK, ANNOUNCE_ACK, SUBSCRIBE_ACK) ─────────── }
  ST_OK                = $00;
  ST_VERSION_INCOMPAT  = $01;
  ST_AUTH_FAILED       = $01;  { reutiliza 0x01 em contexto AUTH }
  ST_GROUP_NOTFOUND    = $02;

{ ── Códigos de erro ─────────────────────────────────────────────────────────── }
  ERR_NONE            = $00;
  ERR_AUTH_FAILED     = $01;
  ERR_UNKNOWN_NODE    = $02;
  ERR_FORMAT_UNSUP    = $03;
  ERR_PAYLOAD_TOO_BIG = $04;
  ERR_GROUP_NOTFOUND  = $05;
  ERR_PROTOCOL        = $06;
  ERR_SEQ_INVALID     = $07;
  ERR_NOT_AUTH        = $08;
  ERR_INTERNAL        = $FF;

{ ── Grupos bem-conhecidos (UUID como bytes) ─────────────────────────────────── }
  { 00000000-0000-0000-0000-000000000001 }
  GROUP_DEFAULT_HEX = '00000000000000000000000000000001';
  { 00000000-0000-0000-0000-000000000000 — broker system ID }
  GROUP_SYSTEM_HEX  = '00000000000000000000000000000000';

{ ── Status de CLIP_ACK ──────────────────────────────────────────────────────── }
  ACK_APPLIED         = $00;
  ACK_FORMAT_UNSUP    = $01;
  ACK_TOO_LARGE       = $02;
  ACK_APPLY_FAILED    = $03;
  ACK_DEDUPLICATED    = $04;

{ ── Versão do cliente/protocolo (uint32) ────────────────────────────────────── }
  CLIENT_VERSION = $00010000;  { 1.0.0 }
  MIN_PROTOCOL   = $00010000;

{ ── Limites padrão ──────────────────────────────────────────────────────────── }
  DEFAULT_PORT          = 6543;
  DEFAULT_MAX_PAYLOAD   = 4 * 1024 * 1024;  { 4 MB }
  DEFAULT_HISTORY_SIZE  = 50;
  DEFAULT_PING_SEC      = 30;
  DEFAULT_PING_TIMEOUT  = 90;               { 3× ping interval }
  DEFAULT_SUPP_WINDOW   = 800;              { ms janela de supressão anti-loop }
  HANDSHAKE_TIMEOUT_SEC = 10;

{ ── Modo de sincronização ───────────────────────────────────────────────────── }
  SYNC_RECV_ONLY = 0;
  SYNC_SEND_ONLY = 1;
  SYNC_BIDIR     = 2;

type
  { Identificador de nó: UUID v4, 16 bytes raw }
  TNodeID = array[0..15] of Byte;
  PNodeID = ^TNodeID;

  { Header do frame (packed, 36 bytes) }
  TCBHeader = packed record
    Magic    : array[0..1] of Byte;   { 0: 0x43  1: 0x42 }
    Version  : Byte;                  { CB_VERSION }
    MsgType  : Byte;                  { MSG_xxx }
    Flags    : Byte;                  { FLAG_xxx bitmask }
    Reserved : array[0..2] of Byte;   { zeros }
    NodeID   : TNodeID;               { sender UUID }
    SeqNum   : LongWord;              { big-endian }
    Timestamp: LongWord;              { big-endian, Unix seconds }
    PayloadLen: LongWord;             { big-endian }
  end;
  PCBHeader = ^TCBHeader;

  TBytes = array of Byte;

{ ── Funções de byte order (big-endian network ↔ host) ────────────────────────── }
function HostToBE32(V: LongWord): LongWord; inline;
function BE32ToHost(V: LongWord): LongWord; inline;
function HostToBE16(V: Word): Word; inline;
function BE16ToHost(V: Word): Word; inline;

{ ── Helpers de NodeID ────────────────────────────────────────────────────────── }
function NodeIDToHex(const N: TNodeID): string;
function HexToNodeID(const S: string; out N: TNodeID): Boolean;
function NodeIDEqual(const A, B: TNodeID): Boolean;
function NodeIDIsZero(const N: TNodeID): Boolean;
procedure NodeIDZero(out N: TNodeID);

{ ── Grupos bem-conhecidos ────────────────────────────────────────────────────── }
function DefaultGroupID: TNodeID;
function SystemGroupID: TNodeID;

{ ── Unix timestamp ───────────────────────────────────────────────────────────── }
function UnixNow: LongWord;

implementation

uses SysUtils
{$IFDEF UNIX}, BaseUnix, unix{$ENDIF};

{ ── Byte order ───────────────────────────────────────────────────────────────── }

function HostToBE32(V: LongWord): LongWord; inline;
begin
  Result := ((V and $000000FF) shl 24) or
            ((V and $0000FF00) shl  8) or
            ((V and $00FF0000) shr  8) or
            ((V and $FF000000) shr 24);
end;

function BE32ToHost(V: LongWord): LongWord; inline;
begin
  Result := HostToBE32(V);  { simétrico }
end;

function HostToBE16(V: Word): Word; inline;
begin
  Result := ((V and $00FF) shl 8) or ((V and $FF00) shr 8);
end;

function BE16ToHost(V: Word): Word; inline;
begin
  Result := HostToBE16(V);
end;

{ ── NodeID helpers ───────────────────────────────────────────────────────────── }

function NodeIDToHex(const N: TNodeID): string;
const HexChars: string = '0123456789abcdef';
var i: Integer;
begin
  SetLength(Result, 32);
  for i := 0 to 15 do begin
    Result[i*2+1] := HexChars[(N[i] shr 4) + 1];
    Result[i*2+2] := HexChars[(N[i] and $0F) + 1];
  end;
end;

function HexToNodeID(const S: string; out N: TNodeID): Boolean;
var i, hi, lo: Integer; C: Char;

  function HexVal(C: Char): Integer;
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
  if Length(S) <> 32 then Exit;
  FillChar(N, SizeOf(N), 0);
  for i := 0 to 15 do begin
    hi := HexVal(S[i*2+1]);
    lo := HexVal(S[i*2+2]);
    if (hi < 0) or (lo < 0) then Exit;
    N[i] := Byte(hi shl 4) or Byte(lo);
  end;
  Result := True;
end;

function NodeIDEqual(const A, B: TNodeID): Boolean;
var i: Integer;
begin
  Result := True;
  for i := 0 to 15 do
    if A[i] <> B[i] then begin Result := False; Exit; end;
end;

function NodeIDIsZero(const N: TNodeID): Boolean;
var i: Integer;
begin
  Result := True;
  for i := 0 to 15 do
    if N[i] <> 0 then begin Result := False; Exit; end;
end;

procedure NodeIDZero(out N: TNodeID);
begin
  FillChar(N, SizeOf(N), 0);
end;

function DefaultGroupID: TNodeID;
begin
  FillChar(Result, SizeOf(Result), 0);
  Result[15] := $01;
end;

function SystemGroupID: TNodeID;
begin
  FillChar(Result, SizeOf(Result), 0);
end;

{ ── Timestamp ────────────────────────────────────────────────────────────────── }

function UnixNow: LongWord;
{$IFDEF UNIX}
var tv: TimeVal;
begin
  fpgettimeofday(@tv, nil);
  Result := LongWord(tv.tv_sec);
end;
{$ELSE}
begin
  { Win32: DateTimeToUnix equivalente }
  Result := LongWord(Round((Now - 25569.0) * 86400.0));
end;
{$ENDIF}

end.
