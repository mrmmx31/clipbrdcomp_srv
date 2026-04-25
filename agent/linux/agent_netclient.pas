{ agent_netclient.pas — Cliente TCP do agente Linux para o broker
  Roda em thread separada; lida com handshake, reconexão e leitura contínua. }

unit agent_netclient;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, StrUtils, Classes, SyncObjs, ssockets, BaseUnix,
  cbprotocol, cbhash, cbmessage, cbuuid,
  agent_config;

type
  { Callback chamado quando um CLIP_PUSH é recebido }
  TClipPushCallback = procedure(const P: TClipPushPayload) of object;

  TNetClientState = (ncsDisconnected, ncsConnecting, ncsHandshake, ncsActive);

  TNetClient = class(TThread)
  private
    FConfig      : TAgentConfig;
    FSocket      : TSocketStream;
    FState       : TNetClientState;
    FSeq         : LongWord;
    FNodeID      : TNodeID;
    FLock        : TCriticalSection;  { protege escrita }
    FOnClipPush  : TClipPushCallback;
    FConnected   : Boolean;
    FLastPing    : Int64;
    FPongOk      : Boolean;
    FMissedPongs : Integer;

    function Connect: Boolean;
    procedure Disconnect;
    function DoHandshake: Boolean;
    procedure HandleFrame(const Hdr: TCBHeader; const Payload: TBytes);
    procedure HandleHelloAck(const Hdr: TCBHeader; const Payload: TBytes);
    procedure HandleAuthAck(const Hdr: TCBHeader; const Payload: TBytes);
    procedure HandleAnnounceAck(const Hdr: TCBHeader; const Payload: TBytes);
    procedure HandleSubscribeAck(const Hdr: TCBHeader; const Payload: TBytes);
    procedure HandleClipPush(const Hdr: TCBHeader; const Payload: TBytes);
    procedure HandlePong(const Hdr: TCBHeader; const Payload: TBytes);
    procedure HandleError(const Hdr: TCBHeader; const Payload: TBytes);

    function NextSeq: LongWord;
    procedure SendFrameLocked(MsgType: Byte; const Payload: TBytes); overload;
    procedure SendFrameLocked(MsgType: Byte); overload;
    function BuildAnnounceFromConfig: TBytes;
  protected
    procedure Execute; override;
  public
    constructor Create(AConfig: TAgentConfig; AOnClipPush: TClipPushCallback);
    destructor Destroy; override;

    { Publica um item de clipboard; thread-safe }
    procedure PublishClip(FormatType: Byte; const Content: TBytes;
      const Hash: TClipHash);

    property Connected: Boolean read FConnected;
    property State: TNetClientState read FState;
  end;

implementation

uses DateUtils, compat_profiles;

const
  RECONNECT_WAIT_MS = 5000;

constructor TNetClient.Create(AConfig: TAgentConfig; AOnClipPush: TClipPushCallback);
begin
  inherited Create(True);
  FConfig     := AConfig;
  FOnClipPush := AOnClipPush;
  FSocket     := nil;
  FState      := ncsDisconnected;
  FSeq        := 0;
  FConnected  := False;
  FPongOk     := True;
  FLastPing   := 0;
  FMissedPongs:= 0;
  FLock       := TCriticalSection.Create;
  HexToNodeID(AConfig.NodeIDHex, FNodeID);
  FreeOnTerminate := False;
end;

destructor TNetClient.Destroy;
begin
  Disconnect;
  FLock.Free;
  inherited;
end;

function TNetClient.NextSeq: LongWord;
begin
  Inc(FSeq);
  Result := FSeq;
end;

procedure TNetClient.SendFrameLocked(MsgType: Byte; const Payload: TBytes);
begin
  if FSocket = nil then Exit;
  FLock.Enter;
  try
    WriteFrame(FSocket, MsgType, 0, FNodeID, NextSeq, Payload);
  except
    on E: Exception do begin
      WriteLn(StdErr, '[NetClient] SendFrame exception: ', E.ClassName, ': ', E.Message);
      FState := ncsDisconnected;
      FConnected := False;
    end;
  end;
  FLock.Leave;
end;

procedure TNetClient.SendFrameLocked(MsgType: Byte);
var Empty: TBytes;
begin
  SetLength(Empty, 0);
  SendFrameLocked(MsgType, Empty);
end;

function TNetClient.Connect: Boolean;
begin
  Result := False;
  try
    FSocket := TInetSocket.Create(FConfig.BrokerHost, FConfig.BrokerPort);
    FSocket.IOTimeout := 10000; { aumentar timeout de IO para tolerar latências altas }
    FState := ncsHandshake;
    Result := True;
  except
    on E: Exception do begin
      FSocket := nil;
      WriteLn(StdErr, '[NetClient] Connect failed: ', E.Message);
    end;
  end;
end;

procedure TNetClient.Disconnect;
begin
  FConnected := False;
  FState := ncsDisconnected;
  if Assigned(FSocket) then begin
    try FSocket.Free; except end;
    FSocket := nil;
  end;
end;

function TNetClient.DoHandshake: Boolean;
var
  Hdr        : TCBHeader;
  Payload    : TBytes;
  HelloPld   : TBytes;
  AuthPld    : TBytes;
  AnnPld     : TBytes;
  SubPld     : TBytes;
  GroupID    : TNodeID;
  StepOK     : Boolean;
  HA         : THelloAckPayload;
  AA         : TAuthAckPayload;
begin
  Result := False;

  { 1. HELLO }
  HelloPld := BuildHelloPayload(OS_LINUX_X11, AnsiString(FConfig.Hostname));
  SendFrameLocked(MSG_HELLO, HelloPld);
  if not ReadFrame(FSocket, Hdr, Payload) then Exit;
  if Hdr.MsgType <> MSG_HELLO_ACK then Exit;
  if not ParseHelloAckPayload(Payload, HA) then Exit;
  if HA.Status <> ST_OK then begin
    WriteLn('[NetClient] HELLO_ACK rejected: status=', HA.Status);
    Exit;
  end;

  { 2. AUTH }
  AuthPld := BuildAuthPayload(AnsiString(FConfig.AuthToken));
  SendFrameLocked(MSG_AUTH, AuthPld);
  if not ReadFrame(FSocket, Hdr, Payload) then Exit;
  if Hdr.MsgType <> MSG_AUTH_ACK then Exit;
  if not ParseAuthAckPayload(Payload, AA) then Exit;
  if AA.Status <> ST_OK then begin
    WriteLn('[NetClient] AUTH failed: ', AA.Msg);
    Exit;
  end;

  { 3. ANNOUNCE }
  AnnPld := BuildAnnounceFromConfig;
  SendFrameLocked(MSG_ANNOUNCE, AnnPld);
  if not ReadFrame(FSocket, Hdr, Payload) then Exit;
  if Hdr.MsgType <> MSG_ANNOUNCE_ACK then Exit;

  { 4. SUBSCRIBE_GROUP }
  if SameText(FConfig.Group, 'default') or (FConfig.Group = '') then
    GroupID := DefaultGroupID
  else begin
    { Tenta parsear como hex; caso contrário usa default }
    if not StringToUUID(FConfig.Group, GroupID) then
      GroupID := DefaultGroupID;
  end;
  SubPld := BuildSubscribeGroupPayload(GroupID, SYNC_BIDIR);
  SendFrameLocked(MSG_SUBSCRIBE_GROUP, SubPld);
  if not ReadFrame(FSocket, Hdr, Payload) then Exit;
  if Hdr.MsgType <> MSG_SUBSCRIBE_ACK then Exit;

  FState := ncsActive;
  FConnected := True;
  WriteLn(StdErr, '[NetClient] Connected and active. NodeID=', FConfig.NodeIDHex);
  Result := True;
end;

function TNetClient.BuildAnnounceFromConfig: TBytes;
var P: TAnnouncePayload; Prof: TCompatProfile;
begin
  Prof := GetProfile(FConfig.Profile);
  P.OSType      := OS_LINUX_X11;
  P.Profile     := AnsiString(FConfig.Profile);
  P.Formats     := Prof.Formats;
  P.MaxPayloadKB:= Word(FConfig.MaxPayloadKB);
  P.CapFlags    := Prof.CapFlags;
  P.OSVersion   := 'Linux';
  Result := BuildAnnouncePayload(P);
end;

procedure TNetClient.HandleFrame(const Hdr: TCBHeader; const Payload: TBytes);
begin
  case Hdr.MsgType of
    MSG_CLIP_PUSH:    HandleClipPush(Hdr, Payload);
    MSG_PONG:         HandlePong(Hdr, Payload);
    MSG_PING: begin
      { broker enviou ping — responde }
      SendFrameLocked(MSG_PONG, BuildPongPayload(Hdr.SeqNum));
    end;
    MSG_ERROR:        HandleError(Hdr, Payload);
    MSG_GOODBYE: begin
      WriteLn(StdErr, '[NetClient] Server sent GOODBYE');
      FState := ncsDisconnected;
      FConnected := False;
    end;
  else
    { Frame inesperado — ignora em estado ativo }
  end;
end;

procedure TNetClient.HandleHelloAck(const Hdr: TCBHeader; const Payload: TBytes);
begin end;

procedure TNetClient.HandleAuthAck(const Hdr: TCBHeader; const Payload: TBytes);
begin end;

procedure TNetClient.HandleAnnounceAck(const Hdr: TCBHeader; const Payload: TBytes);
begin end;

procedure TNetClient.HandleSubscribeAck(const Hdr: TCBHeader; const Payload: TBytes);
begin end;

procedure TNetClient.HandleClipPush(const Hdr: TCBHeader; const Payload: TBytes);
var P: TClipPushPayload;
begin
  if ParseClipPushPayload(Payload, P) then begin
    { Envia ACK }
    SendFrameLocked(MSG_CLIP_ACK, BuildClipAckPayload(P.ClipID, ACK_APPLIED));
    { Notifica o agente }
    if Assigned(FOnClipPush) then FOnClipPush(P);
  end;
end;

procedure TNetClient.HandlePong(const Hdr: TCBHeader; const Payload: TBytes);
begin
  FPongOk := True;
  FMissedPongs := 0;
end;

procedure TNetClient.HandleError(const Hdr: TCBHeader; const Payload: TBytes);
var P: TErrorPayload;
begin
  if ParseErrorPayload(Payload, P) then
    WriteLn(StdErr, '[NetClient] ERROR from broker: code=', P.ErrorCode, ' msg=', P.Msg);
end;

procedure TNetClient.PublishClip(FormatType: Byte; const Content: TBytes;
  const Hash: TClipHash);
var P: TClipPublishPayload;
begin
  if not FConnected then begin
    WriteLn(StdErr, '[NetClient] PublishClip skipped: not connected fmt=0x', IntToHex(FormatType,2), ' len=', IntToStr(Length(Content)));
    Exit;
  end;

  P.ClipID     := GenerateUUID;
  P.GroupID    := DefaultGroupID;
  P.FormatType := FormatType;
  P.OrigOSFormat := $03;  { X11_UTF8 / X11_BITMAP }
  P.Encoding   := ENC_UTF8;
  P.Hash       := Hash;
  P.Content    := Content;

  WriteLn(StdErr, '[NetClient] PublishClip: fmt=0x', IntToHex(FormatType,2), ' len=', IntToStr(Length(Content)), ' hash=', HashToHex(Hash));

  SendFrameLocked(MSG_CLIP_PUBLISH, BuildClipPublishPayload(P));

  WriteLn(StdErr, '[NetClient] CLIP_PUBLISH sent');
end;

procedure TNetClient.Execute;
var
  Hdr    : TCBHeader;
  Payload: TBytes;
  Now2   : Int64;
begin
  try
  while not Terminated do begin
    { Conecta }
    if not Connect then begin
      Sleep(FConfig.ReconnectSec * 1000);
      Continue;
    end;
    { Handshake }
    if not DoHandshake then begin
      WriteLn(StdErr, '[NetClient] Handshake failed, retrying in ', FConfig.ReconnectSec, 's');
      Disconnect;
      Sleep(FConfig.ReconnectSec * 1000);
      Continue;
    end;
    FLastPing := DateTimeToUnix(Now);
    FPongOk   := True;
    { Loop de leitura }
    while FConnected and not Terminated do begin
      if ReadFrame(FSocket, Hdr, Payload) then begin
        HandleFrame(Hdr, Payload);
      end else begin
        { EAGAIN/EWOULDBLOCK = IOTimeout expirou, continuar
          LastError = 0 = EOF; outros = erro real → desligar }
        if (FSocket = nil) or
           ((FSocket.LastError <> ESysEAGAIN) and
            (FSocket.LastError <> ESysEWOULDBLOCK)) then begin
          WriteLn(StdErr, '[NetClient] Connection lost (LastError=',
            IfThen(FSocket <> nil, IntToStr(FSocket.LastError), 'nil'), ')');
          Disconnect;
          Break;
        end;
        { Verifica ping }
        Now2 := DateTimeToUnix(Now);
        if (Now2 - FLastPing) >= FConfig.PingIntervalSec then begin
          if not FPongOk then begin
            Inc(FMissedPongs);
            if FMissedPongs >= 6 then begin
              WriteLn(StdErr, '[NetClient] Ping timeout (missed ', FMissedPongs, ' pongs)');
              Disconnect;
              Break;
            end else
              WriteLn(StdErr, '[NetClient] Ping missed (', FMissedPongs, '), waiting');
          end else
            FMissedPongs := 0;
          FPongOk := False;
          SendFrameLocked(MSG_PING);
          FLastPing := Now2;
        end;
      end;
    end;
    if not Terminated then
      Sleep(FConfig.ReconnectSec * 1000);
  end;
  except
    on E: Exception do
      WriteLn(StdErr, '[NetClient] FATAL exception in Execute: ', E.ClassName, ': ', E.Message);
  end;
end;

end.
