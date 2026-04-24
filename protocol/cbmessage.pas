{ cbmessage.pas — Serialização e deserialização de frames ClipBrdComp v1
  Constrói e parseia todos os tipos de mensagem do protocolo.
  Usa TStream como abstração de I/O (compatível com ssockets e WinSock wrappers). }

unit cbmessage;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes,
  cbprotocol, cbcrc32, cbhash;

{ ── Tipos de payload estruturado ────────────────────────────────────────────── }
type
  THelloPayload = record
    ClientVersion : LongWord;
    MinVersion    : LongWord;
    OSType        : Byte;
    Hostname      : AnsiString;
  end;

  THelloAckPayload = record
    Status        : Byte;
    BrokerVersion : LongWord;
    ServerTime    : LongWord;
  end;

  TAuthPayload = record
    Token         : AnsiString;
  end;

  TAuthAckPayload = record
    Status        : Byte;
    Msg           : AnsiString;
  end;

  TAnnouncePayload = record
    OSType        : Byte;
    Profile       : AnsiString;
    Formats       : LongWord;
    MaxPayloadKB  : Word;
    CapFlags      : Byte;
    OSVersion     : AnsiString;
  end;

  TAnnounceAckPayload = record
    Status        : Byte;
  end;

  TClipPublishPayload = record
    ClipID        : TNodeID;
    GroupID       : TNodeID;
    FormatType    : Byte;
    OrigOSFormat  : Byte;
    Encoding      : Byte;
    Hash          : TClipHash;
    Content       : TBytes;
  end;

  TClipPushPayload = record
    ClipID        : TNodeID;
    SourceNodeID  : TNodeID;
    GroupID       : TNodeID;
    FormatType    : Byte;
    Encoding      : Byte;
    Hash          : TClipHash;
    Content       : TBytes;
  end;

  TClipAckPayload = record
    ClipID        : TNodeID;
    Status        : Byte;
  end;

  TPongPayload = record
    OrigSeq       : LongWord;
  end;

  TErrorPayload = record
    ErrorCode     : Byte;
    Msg           : AnsiString;
  end;

  TSubscribeGroupPayload = record
    GroupID       : TNodeID;
    Mode          : Byte;
  end;

  TSubscribeAckPayload = record
    Status        : Byte;
    GroupName     : AnsiString;
  end;

{ ── Leitura confiável de stream ─────────────────────────────────────────────── }
{ Lê exatamente Len bytes do stream (retorna False se conexão fechada/erro) }
function ReadExact(S: TStream; var Buf; Len: Integer): Boolean;

{ ── Escrita de frame completo ───────────────────────────────────────────────── }
{ Serializa header + payload + CRC32 e escreve no stream }
procedure WriteFrame(S: TStream; MsgType: Byte; Flags: Byte;
  const NodeID: TNodeID; SeqNum: LongWord;
  const Payload: TBytes); overload;

procedure WriteFrame(S: TStream; MsgType: Byte; Flags: Byte;
  const NodeID: TNodeID; SeqNum: LongWord); overload;  { payload vazio }

{ ── Leitura de frame ─────────────────────────────────────────────────────────── }
{ Lê e valida um frame completo. Retorna False em caso de erro ou CRC inválido. }
function ReadFrame(S: TStream; out Header: TCBHeader;
  out Payload: TBytes): Boolean;

{ ── Construtores de payload ─────────────────────────────────────────────────── }
function BuildHelloPayload(OSType: Byte; const Hostname: AnsiString): TBytes;
function BuildHelloAckPayload(Status: Byte; BrokerVersion, ServerTime: LongWord): TBytes;
function BuildAuthPayload(const Token: AnsiString): TBytes;
function BuildAuthAckPayload(Status: Byte; const Msg: AnsiString): TBytes;
function BuildAnnouncePayload(const P: TAnnouncePayload): TBytes;
function BuildAnnounceAckPayload(Status: Byte): TBytes;
function BuildClipPublishPayload(const P: TClipPublishPayload): TBytes;
function BuildClipPushPayload(const P: TClipPushPayload): TBytes;
function BuildClipAckPayload(const ClipID: TNodeID; Status: Byte): TBytes;
function BuildPongPayload(OrigSeq: LongWord): TBytes;
function BuildErrorPayload(ErrCode: Byte; const Msg: AnsiString): TBytes;
function BuildSubscribeGroupPayload(const GroupID: TNodeID; Mode: Byte): TBytes;
function BuildSubscribeAckPayload(Status: Byte; const GroupName: AnsiString): TBytes;

{ ── Parsers de payload ───────────────────────────────────────────────────────── }
function ParseHelloPayload(const Data: TBytes; out P: THelloPayload): Boolean;
function ParseHelloAckPayload(const Data: TBytes; out P: THelloAckPayload): Boolean;
function ParseAuthPayload(const Data: TBytes; out P: TAuthPayload): Boolean;
function ParseAuthAckPayload(const Data: TBytes; out P: TAuthAckPayload): Boolean;
function ParseAnnouncePayload(const Data: TBytes; out P: TAnnouncePayload): Boolean;
function ParseClipPublishPayload(const Data: TBytes; out P: TClipPublishPayload): Boolean;
function ParseClipPushPayload(const Data: TBytes; out P: TClipPushPayload): Boolean;
function ParseClipAckPayload(const Data: TBytes; out P: TClipAckPayload): Boolean;
function ParseErrorPayload(const Data: TBytes; out P: TErrorPayload): Boolean;
function ParseSubscribeGroupPayload(const Data: TBytes; out P: TSubscribeGroupPayload): Boolean;
function ParseSubscribeAckPayload(const Data: TBytes; out P: TSubscribeAckPayload): Boolean;

implementation

{ ── ReadExact ────────────────────────────────────────────────────────────────── }

function ReadExact(S: TStream; var Buf; Len: Integer): Boolean;
var Bytes, Got: Integer; P: PByte;
begin
  Result := False;
  if Len = 0 then begin Result := True; Exit; end;
  P := @Buf;
  Bytes := 0;
  while Bytes < Len do begin
    Got := S.Read(P[Bytes], Len - Bytes);
    if Got <= 0 then Exit;
    Inc(Bytes, Got);
  end;
  Result := True;
end;

{ ── Helpers internos de escrita ─────────────────────────────────────────────── }

procedure WriteU8(S: TStream; V: Byte);
begin S.Write(V, 1); end;

procedure WriteU16BE(S: TStream; V: Word);
var B: Word;
begin B := HostToBE16(V); S.Write(B, 2); end;

procedure WriteU32BE(S: TStream; V: LongWord);
var B: LongWord;
begin B := HostToBE32(V); S.Write(B, 4); end;

procedure WriteBytes(S: TStream; const Buf; Len: Integer);
begin if Len > 0 then S.Write(Buf, Len); end;

procedure WritePascalStr(S: TStream; const Str: AnsiString);
var L: Byte;
begin
  L := Byte(Length(Str));  { trunca em 255 silenciosamente }
  WriteU8(S, L);
  if L > 0 then S.Write(Str[1], L);
end;

{ ── Helpers internos de leitura (de TBytes com cursor) ───────────────────────── }

function ReadU8(const Data: TBytes; var Pos: Integer; out V: Byte): Boolean;
begin
  Result := Pos < Length(Data);
  if Result then begin V := Data[Pos]; Inc(Pos); end;
end;

function ReadU16BE(const Data: TBytes; var Pos: Integer; out V: Word): Boolean;
begin
  Result := Pos + 2 <= Length(Data);
  if Result then begin
    V := BE16ToHost(PWord(@Data[Pos])^);
    Inc(Pos, 2);
  end;
end;

function ReadU32BE(const Data: TBytes; var Pos: Integer; out V: LongWord): Boolean;
begin
  Result := Pos + 4 <= Length(Data);
  if Result then begin
    V := BE32ToHost(PLongWord(@Data[Pos])^);
    Inc(Pos, 4);
  end;
end;

function ReadNodeID(const Data: TBytes; var Pos: Integer; out N: TNodeID): Boolean;
begin
  FillChar(N, SizeOf(N), 0);
  Result := Pos + 16 <= Length(Data);
  if Result then begin
    Move(Data[Pos], N, 16);
    Inc(Pos, 16);
  end;
end;

function ReadHash(const Data: TBytes; var Pos: Integer; out H: TClipHash): Boolean;
begin
  FillChar(H, SizeOf(H), 0);
  Result := Pos + 16 <= Length(Data);
  if Result then begin
    Move(Data[Pos], H, 16);
    Inc(Pos, 16);
  end;
end;

function ReadPascalStr(const Data: TBytes; var Pos: Integer; out S: AnsiString): Boolean;
var L: Byte;
begin
  Result := False;
  if not ReadU8(Data, Pos, L) then Exit;
  if Pos + L > Length(Data) then Exit;
  SetLength(S, L);
  if L > 0 then Move(Data[Pos], S[1], L);
  Inc(Pos, L);
  Result := True;
end;

function ReadRestAsBytes(const Data: TBytes; Pos: Integer; out B: TBytes): Boolean;
var Rem: Integer;
begin
  Rem := Length(Data) - Pos;
  if Rem < 0 then Rem := 0;
  SetLength(B, Rem);
  if Rem > 0 then Move(Data[Pos], B[0], Rem);
  Result := True;
end;

{ ── WriteFrame ───────────────────────────────────────────────────────────────── }

procedure WriteFrame(S: TStream; MsgType: Byte; Flags: Byte;
  const NodeID: TNodeID; SeqNum: LongWord;
  const Payload: TBytes);
var
  Hdr: TCBHeader;
  PLen: LongWord;
  CRC: LongWord;
  CRCBuf: LongWord;
  Buf: TBytes;
begin
  PLen := LongWord(Length(Payload));

  { Preenche header }
  Hdr.Magic[0]   := CB_MAGIC_0;
  Hdr.Magic[1]   := CB_MAGIC_1;
  Hdr.Version    := CB_VERSION;
  Hdr.MsgType    := MsgType;
  Hdr.Flags      := Flags;
  Hdr.Reserved[0] := 0;
  Hdr.Reserved[1] := 0;
  Hdr.Reserved[2] := 0;
  Hdr.NodeID     := NodeID;
  Hdr.SeqNum     := HostToBE32(SeqNum);
  Hdr.Timestamp  := HostToBE32(UnixNow);
  Hdr.PayloadLen := HostToBE32(PLen);

  { Calcula CRC32 concatenando header+payload num buffer contíguo }
  SetLength(Buf, CB_HEADER_SIZE + PLen);
  Move(Hdr, Buf[0], CB_HEADER_SIZE);
  if PLen > 0 then Move(Payload[0], Buf[CB_HEADER_SIZE], PLen);
  CRC := CRC32Buffer(@Buf[0], Length(Buf));

  { Escreve tudo }
  S.Write(Hdr, CB_HEADER_SIZE);
  if PLen > 0 then S.Write(Payload[0], PLen);
  CRCBuf := HostToBE32(CRC);
  S.Write(CRCBuf, 4);
end;

procedure WriteFrame(S: TStream; MsgType: Byte; Flags: Byte;
  const NodeID: TNodeID; SeqNum: LongWord);
var Empty: TBytes;
begin
  SetLength(Empty, 0);
  WriteFrame(S, MsgType, Flags, NodeID, SeqNum, Empty);
end;

{ ── ReadFrame ────────────────────────────────────────────────────────────────── }

function ReadFrame(S: TStream; out Header: TCBHeader;
  out Payload: TBytes): Boolean;
var
  PLen: LongWord;
  CRCRead, CRCCalc: LongWord;
  CRCBuf: LongWord;
  Buf: TBytes;
begin
  Result := False;
  SetLength(Payload, 0);
  FillChar(Header, SizeOf(Header), 0);

  { Lê header fixo }
  if not ReadExact(S, Header, CB_HEADER_SIZE) then Exit;

  { Valida magic e versão }
  if (Header.Magic[0] <> CB_MAGIC_0) or
     (Header.Magic[1] <> CB_MAGIC_1) then Exit;
  if Header.Version <> CB_VERSION then Exit;

  { Converte payload length de big-endian }
  PLen := BE32ToHost(Header.PayloadLen);

  { Limite de segurança: recusar payloads absurdos }
  if PLen > 64 * 1024 * 1024 then Exit;  { 64 MB max absoluto }

  { Lê payload }
  SetLength(Payload, PLen);
  if PLen > 0 then
    if not ReadExact(S, Payload[0], PLen) then begin
      SetLength(Payload, 0);
      Exit;
    end;

  { Lê CRC32 }
  if not ReadExact(S, CRCBuf, 4) then Exit;
  CRCRead := BE32ToHost(CRCBuf);

  { Recalcula CRC32 sobre header + payload }
  SetLength(Buf, CB_HEADER_SIZE + PLen);
  Move(Header, Buf[0], CB_HEADER_SIZE);
  if PLen > 0 then Move(Payload[0], Buf[CB_HEADER_SIZE], PLen);
  CRCCalc := CRC32Buffer(@Buf[0], Length(Buf));

  if CRCCalc <> CRCRead then Exit;  { frame corrompido }

  { Converte campos de big-endian para host order no header retornado }
  Header.SeqNum     := BE32ToHost(Header.SeqNum);
  Header.Timestamp  := BE32ToHost(Header.Timestamp);
  Header.PayloadLen := PLen;  { já convertido }

  Result := True;
end;

{ ── Construtores de payload ─────────────────────────────────────────────────── }

function BuildHelloPayload(OSType: Byte; const Hostname: AnsiString): TBytes;
var S: TMemoryStream;
begin
  S := TMemoryStream.Create;
  try
    WriteU32BE(S, CLIENT_VERSION);
    WriteU32BE(S, MIN_PROTOCOL);
    WriteU8(S, OSType);
    WritePascalStr(S, Hostname);
    SetLength(Result, S.Size);
    S.Position := 0;
    S.Read(Result[0], S.Size);
  finally S.Free; end;
end;

function BuildHelloAckPayload(Status: Byte; BrokerVersion, ServerTime: LongWord): TBytes;
var S: TMemoryStream;
begin
  S := TMemoryStream.Create;
  try
    WriteU8(S, Status);
    WriteU32BE(S, BrokerVersion);
    WriteU32BE(S, ServerTime);
    SetLength(Result, S.Size);
    S.Position := 0;
    S.Read(Result[0], S.Size);
  finally S.Free; end;
end;

function BuildAuthPayload(const Token: AnsiString): TBytes;
var S: TMemoryStream;
begin
  S := TMemoryStream.Create;
  try
    WritePascalStr(S, Token);
    SetLength(Result, S.Size);
    S.Position := 0;
    S.Read(Result[0], S.Size);
  finally S.Free; end;
end;

function BuildAuthAckPayload(Status: Byte; const Msg: AnsiString): TBytes;
var S: TMemoryStream;
begin
  S := TMemoryStream.Create;
  try
    WriteU8(S, Status);
    WritePascalStr(S, Msg);
    SetLength(Result, S.Size);
    S.Position := 0;
    S.Read(Result[0], S.Size);
  finally S.Free; end;
end;

function BuildAnnouncePayload(const P: TAnnouncePayload): TBytes;
var S: TMemoryStream;
begin
  S := TMemoryStream.Create;
  try
    WriteU8(S, P.OSType);
    WritePascalStr(S, P.Profile);
    WriteU32BE(S, P.Formats);
    WriteU16BE(S, P.MaxPayloadKB);
    WriteU8(S, P.CapFlags);
    WritePascalStr(S, P.OSVersion);
    SetLength(Result, S.Size);
    S.Position := 0;
    S.Read(Result[0], S.Size);
  finally S.Free; end;
end;

function BuildAnnounceAckPayload(Status: Byte): TBytes;
begin
  SetLength(Result, 1);
  Result[0] := Status;
end;

function BuildClipPublishPayload(const P: TClipPublishPayload): TBytes;
var S: TMemoryStream; ContentLen: LongWord;
begin
  S := TMemoryStream.Create;
  try
    WriteBytes(S, P.ClipID, 16);
    WriteBytes(S, P.GroupID, 16);
    WriteU8(S, P.FormatType);
    WriteU8(S, P.OrigOSFormat);
    WriteU8(S, P.Encoding);
    WriteU8(S, 0);  { reserved }
    WriteBytes(S, P.Hash, 16);
    ContentLen := LongWord(Length(P.Content));
    WriteU32BE(S, ContentLen);
    if ContentLen > 0 then WriteBytes(S, P.Content[0], ContentLen);
    SetLength(Result, S.Size);
    S.Position := 0;
    S.Read(Result[0], S.Size);
  finally S.Free; end;
end;

function BuildClipPushPayload(const P: TClipPushPayload): TBytes;
var S: TMemoryStream; ContentLen: LongWord;
begin
  S := TMemoryStream.Create;
  try
    WriteBytes(S, P.ClipID, 16);
    WriteBytes(S, P.SourceNodeID, 16);
    WriteBytes(S, P.GroupID, 16);
    WriteU8(S, P.FormatType);
    WriteU8(S, P.Encoding);
    WriteU8(S, 0); WriteU8(S, 0);  { reserved }
    WriteBytes(S, P.Hash, 16);
    ContentLen := LongWord(Length(P.Content));
    WriteU32BE(S, ContentLen);
    if ContentLen > 0 then WriteBytes(S, P.Content[0], ContentLen);
    SetLength(Result, S.Size);
    S.Position := 0;
    S.Read(Result[0], S.Size);
  finally S.Free; end;
end;

function BuildClipAckPayload(const ClipID: TNodeID; Status: Byte): TBytes;
var S: TMemoryStream;
begin
  S := TMemoryStream.Create;
  try
    WriteBytes(S, ClipID, 16);
    WriteU8(S, Status);
    SetLength(Result, S.Size);
    S.Position := 0;
    S.Read(Result[0], S.Size);
  finally S.Free; end;
end;

function BuildPongPayload(OrigSeq: LongWord): TBytes;
begin
  SetLength(Result, 4);
  PLongWord(@Result[0])^ := HostToBE32(OrigSeq);
end;

function BuildErrorPayload(ErrCode: Byte; const Msg: AnsiString): TBytes;
var S: TMemoryStream;
begin
  S := TMemoryStream.Create;
  try
    WriteU8(S, ErrCode);
    WritePascalStr(S, Msg);
    SetLength(Result, S.Size);
    S.Position := 0;
    S.Read(Result[0], S.Size);
  finally S.Free; end;
end;

function BuildSubscribeGroupPayload(const GroupID: TNodeID; Mode: Byte): TBytes;
var S: TMemoryStream;
begin
  S := TMemoryStream.Create;
  try
    WriteBytes(S, GroupID, 16);
    WriteU8(S, Mode);
    SetLength(Result, S.Size);
    S.Position := 0;
    S.Read(Result[0], S.Size);
  finally S.Free; end;
end;

function BuildSubscribeAckPayload(Status: Byte; const GroupName: AnsiString): TBytes;
var S: TMemoryStream;
begin
  S := TMemoryStream.Create;
  try
    WriteU8(S, Status);
    WritePascalStr(S, GroupName);
    SetLength(Result, S.Size);
    S.Position := 0;
    S.Read(Result[0], S.Size);
  finally S.Free; end;
end;

{ ── Parsers de payload ───────────────────────────────────────────────────────── }

function ParseHelloPayload(const Data: TBytes; out P: THelloPayload): Boolean;
var Pos: Integer;
begin
  Result := False;
  Pos := 0;
  if not ReadU32BE(Data, Pos, P.ClientVersion) then Exit;
  if not ReadU32BE(Data, Pos, P.MinVersion)    then Exit;
  if not ReadU8(Data, Pos, P.OSType)           then Exit;
  if not ReadPascalStr(Data, Pos, P.Hostname)  then Exit;
  Result := True;
end;

function ParseHelloAckPayload(const Data: TBytes; out P: THelloAckPayload): Boolean;
var Pos: Integer;
begin
  Result := False;
  Pos := 0;
  if not ReadU8(Data, Pos, P.Status)               then Exit;
  if not ReadU32BE(Data, Pos, P.BrokerVersion)     then Exit;
  if not ReadU32BE(Data, Pos, P.ServerTime)        then Exit;
  Result := True;
end;

function ParseAuthPayload(const Data: TBytes; out P: TAuthPayload): Boolean;
var Pos: Integer;
begin
  Result := False;
  Pos := 0;
  if not ReadPascalStr(Data, Pos, P.Token) then Exit;
  Result := True;
end;

function ParseAuthAckPayload(const Data: TBytes; out P: TAuthAckPayload): Boolean;
var Pos: Integer;
begin
  Result := False;
  Pos := 0;
  if not ReadU8(Data, Pos, P.Status) then Exit;
  ReadPascalStr(Data, Pos, P.Msg);   { mensagem é opcional }
  Result := True;
end;

function ParseAnnouncePayload(const Data: TBytes; out P: TAnnouncePayload): Boolean;
var Pos: Integer;
begin
  Result := False;
  Pos := 0;
  if not ReadU8(Data, Pos, P.OSType)               then Exit;
  if not ReadPascalStr(Data, Pos, P.Profile)       then Exit;
  if not ReadU32BE(Data, Pos, P.Formats)           then Exit;
  if not ReadU16BE(Data, Pos, P.MaxPayloadKB)      then Exit;
  if not ReadU8(Data, Pos, P.CapFlags)             then Exit;
  ReadPascalStr(Data, Pos, P.OSVersion);           { opcional }
  Result := True;
end;

function ParseClipPublishPayload(const Data: TBytes; out P: TClipPublishPayload): Boolean;
var Pos: Integer; ContentLen: LongWord; Reserved: Byte;
begin
  Result := False;
  Pos := 0;
  if not ReadNodeID(Data, Pos, P.ClipID)       then Exit;
  if not ReadNodeID(Data, Pos, P.GroupID)      then Exit;
  if not ReadU8(Data, Pos, P.FormatType)       then Exit;
  if not ReadU8(Data, Pos, P.OrigOSFormat)     then Exit;
  if not ReadU8(Data, Pos, P.Encoding)         then Exit;
  if not ReadU8(Data, Pos, Reserved)           then Exit;
  if not ReadHash(Data, Pos, P.Hash)           then Exit;
  if not ReadU32BE(Data, Pos, ContentLen)      then Exit;
  if Pos + Integer(ContentLen) > Length(Data) then Exit;
  SetLength(P.Content, ContentLen);
  if ContentLen > 0 then begin
    Move(Data[Pos], P.Content[0], ContentLen);
    Inc(Pos, ContentLen);
  end;
  Result := True;
end;

function ParseClipPushPayload(const Data: TBytes; out P: TClipPushPayload): Boolean;
var Pos: Integer; ContentLen: LongWord; R1, R2: Byte;
begin
  Result := False;
  Pos := 0;
  if not ReadNodeID(Data, Pos, P.ClipID)       then Exit;
  if not ReadNodeID(Data, Pos, P.SourceNodeID) then Exit;
  if not ReadNodeID(Data, Pos, P.GroupID)      then Exit;
  if not ReadU8(Data, Pos, P.FormatType)       then Exit;
  if not ReadU8(Data, Pos, P.Encoding)         then Exit;
  if not ReadU8(Data, Pos, R1)                 then Exit;  { reserved }
  if not ReadU8(Data, Pos, R2)                 then Exit;
  if not ReadHash(Data, Pos, P.Hash)           then Exit;
  if not ReadU32BE(Data, Pos, ContentLen)      then Exit;
  if Pos + Integer(ContentLen) > Length(Data) then Exit;
  SetLength(P.Content, ContentLen);
  if ContentLen > 0 then begin
    Move(Data[Pos], P.Content[0], ContentLen);
    Inc(Pos, ContentLen);
  end;
  Result := True;
end;

function ParseClipAckPayload(const Data: TBytes; out P: TClipAckPayload): Boolean;
var Pos: Integer;
begin
  Result := False;
  Pos := 0;
  if not ReadNodeID(Data, Pos, P.ClipID) then Exit;
  if not ReadU8(Data, Pos, P.Status)     then Exit;
  Result := True;
end;

function ParseErrorPayload(const Data: TBytes; out P: TErrorPayload): Boolean;
var Pos: Integer;
begin
  Result := False;
  Pos := 0;
  if not ReadU8(Data, Pos, P.ErrorCode)     then Exit;
  ReadPascalStr(Data, Pos, P.Msg);
  Result := True;
end;

function ParseSubscribeGroupPayload(const Data: TBytes; out P: TSubscribeGroupPayload): Boolean;
var Pos: Integer;
begin
  Result := False;
  Pos := 0;
  if not ReadNodeID(Data, Pos, P.GroupID) then Exit;
  if not ReadU8(Data, Pos, P.Mode)        then Exit;
  Result := True;
end;

function ParseSubscribeAckPayload(const Data: TBytes; out P: TSubscribeAckPayload): Boolean;
var Pos: Integer;
begin
  Result := False;
  Pos := 0;
  if not ReadU8(Data, Pos, P.Status)          then Exit;
  ReadPascalStr(Data, Pos, P.GroupName);
  Result := True;
end;

end.
