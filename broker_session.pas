{ broker_session.pas — Gerenciamento de sessão TCP por nó conectado
  Cada conexão aceita gera um TClientSession (TThread).
  Implementa a máquina de estados: HELLO→AUTH→ANNOUNCE→ACTIVE }

unit broker_session;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, SyncObjs, ssockets, sockets, BaseUnix,
  cbprotocol, cbhash, cbmessage, cbuuid,
  broker_logger, broker_registry, broker_router, broker_config;

type
  TSessionState = (ssHello, ssAuth, ssAnnounce, ssActive, ssClosed);

  TClientSession = class(TThread)
  private
    FSocket    : TSocketStream;
    FRegistry  : TNodeRegistry;
    FRouter    : TClipRouter;
    FConfig    : TBrokerConfig;
    FLogger    : TBrokerLogger;

    FState     : TSessionState;
    FNodeIDHex : string;
    FNodeID    : TNodeID;
    FSeqExpect : LongWord;   { próximo seq esperado (anti-replay simples) }
    FLock      : TCriticalSection;  { protege escrita no socket }

    FPingTimer : Int64;     { timestamp do último ping enviado }
    FPongReceived: Boolean;

    procedure HandleHello(const Hdr: TCBHeader; const Payload: TBytes);
    procedure HandleAuth(const Hdr: TCBHeader; const Payload: TBytes);
    procedure HandleAnnounce(const Hdr: TCBHeader; const Payload: TBytes);
    procedure HandleActive(const Hdr: TCBHeader; const Payload: TBytes);
    procedure HandleClipPublish(const Hdr: TCBHeader; const Payload: TBytes);
    procedure HandleClipAck(const Hdr: TCBHeader; const Payload: TBytes);
    procedure HandlePing(const Hdr: TCBHeader; const Payload: TBytes);
    procedure HandlePong(const Hdr: TCBHeader; const Payload: TBytes);
    procedure HandleSubscribeGroup(const Hdr: TCBHeader; const Payload: TBytes);
    procedure HandleGoodbye;

    procedure SendFrame(MsgType: Byte; const Payload: TBytes); overload;
    procedure SendFrame(MsgType: Byte); overload;
    procedure SendError(ErrCode: Byte; const Msg: string);
    procedure SendPing;

    function PeerAddr: string;
  protected
    procedure Execute; override;
  public
    constructor Create(ASocket: TSocketStream; ARegistry: TNodeRegistry;
      ARouter: TClipRouter; AConfig: TBrokerConfig; ALogger: TBrokerLogger);
    destructor Destroy; override;

    { Chamado pelo router para empurrar dados a este nó }
    procedure EnqueueSend(MsgType: Byte; const Payload: TBytes);
  end;

{ Função global passada ao TClipRouter — despacha frames para qualquer sessão }
procedure RouterSessionDispatch(Session: TSessionRef; MsgType: Byte;
  const Payload: TBytes);

implementation

uses DateUtils;

{ ── Dispatch global para o router ───────────────────────────────────────────── }

procedure RouterSessionDispatch(Session: TSessionRef; MsgType: Byte;
  const Payload: TBytes);
begin
  if Assigned(Session) then
  begin
    try
      TClientSession(Session).EnqueueSend(MsgType, Payload);
    except
      on E: Exception do
      begin
        try
          if Assigned(TClientSession(Session).FLogger) then
            TClientSession(Session).FLogger.Error('Router dispatch exception for %s: %s',
              [TClientSession(Session).PeerAddr, E.ClassName + ': ' + E.Message]);
        except
        end;
      end;
    end;
  end;
end;

{ ── Constructor / Destructor ─────────────────────────────────────────────────── }

constructor TClientSession.Create(ASocket: TSocketStream; ARegistry: TNodeRegistry;
  ARouter: TClipRouter; AConfig: TBrokerConfig; ALogger: TBrokerLogger);
begin
  inherited Create(True);  { suspenso até Start }
  FSocket    := ASocket;
  FRegistry  := ARegistry;
  FRouter    := ARouter;
  FConfig    := AConfig;
  FLogger    := ALogger;
  FState     := ssHello;
  FNodeIDHex := '';
  FSeqExpect := 0;
  FLock      := TCriticalSection.Create;
  FPingTimer := 0;
  FPongReceived := True;
  FreeOnTerminate := True;
end;

destructor TClientSession.Destroy;
begin
  FLock.Free;
  FSocket.Free;
  inherited;
end;

{ ── Helpers de envio ─────────────────────────────────────────────────────────── }

function TClientSession.PeerAddr: string;
var
  SA: TInetSockAddr;
begin
  try
    SA := TInetSockAddr(FSocket.RemoteAddress);
    Result := NetAddrToStr(SA.sin_addr);
  except
    Result := '(unknown)';
  end;
end;

procedure TClientSession.SendFrame(MsgType: Byte; const Payload: TBytes);
var BrokerID: TNodeID;
begin
  NodeIDZero(BrokerID);
  if (FState = ssClosed) or Terminated then Exit;
  if not Assigned(FSocket) then
  begin
    FState := ssClosed;
    Exit;
  end;

  if Assigned(FLock) then
  begin
    FLock.Enter;
    try
      try
        WriteFrame(FSocket, MsgType, 0, BrokerID, 0, Payload);
      except
        on E: Exception do
        begin
          FState := ssClosed;
          try
            if Assigned(FLogger) then
              FLogger.Error('SendFrame exception to %s: %s', [PeerAddr, E.ClassName + ': ' + E.Message]);
          except
          end;
        end;
      end;
    finally
      try
        FLock.Leave;
      except
      end;
    end;
  end
  else
  begin
    try
      WriteFrame(FSocket, MsgType, 0, BrokerID, 0, Payload);
    except
      on E: Exception do
      begin
        FState := ssClosed;
        try
          if Assigned(FLogger) then
            FLogger.Error('SendFrame exception (no lock) to %s: %s', [PeerAddr, E.ClassName + ': ' + E.Message]);
        except
        end;
      end;
    end;
  end;
end;

procedure TClientSession.SendFrame(MsgType: Byte);
var Empty: TBytes;
begin
  Empty := nil;
  SendFrame(MsgType, Empty);
end;

procedure TClientSession.SendError(ErrCode: Byte; const Msg: string);
begin
  SendFrame(MSG_ERROR, BuildErrorPayload(ErrCode, AnsiString(Msg)));
end;

procedure TClientSession.SendPing;
begin
  FPingTimer := DateTimeToUnix(Now);
  FPongReceived := False;
  SendFrame(MSG_PING);
  if Assigned(FLogger) then
    FLogger.Debug('PING → %s', [FNodeIDHex]);
end;

{ ── Callback do router ───────────────────────────────────────────────────────── }

{ RouterSendFrame removido — substituído por RouterSessionDispatch global }

procedure TClientSession.EnqueueSend(MsgType: Byte; const Payload: TBytes);
var
  LocalPayload: TBytes;
  LLen: Integer;
begin
  if (FState = ssClosed) or Terminated then Exit;
  LLen := Length(Payload);
  if LLen > 0 then
  begin
    SetLength(LocalPayload, LLen);
    try
      Move(Payload[0], LocalPayload[0], LLen);
    except
      LocalPayload := nil;
    end;
  end
  else
    LocalPayload := nil;

  try
    SendFrame(MsgType, LocalPayload);
  except
    on E: Exception do
    begin
      try
        if Assigned(FLogger) then
          FLogger.Error('EnqueueSend failed for %s msg=0x%02x: %s', [FNodeIDHex, MsgType, E.ClassName + ': ' + E.Message]);
      except
      end;
      FState := ssClosed;
    end;
  end;
end;

{ ── Handlers de mensagem ─────────────────────────────────────────────────────── }

procedure TClientSession.HandleHello(const Hdr: TCBHeader; const Payload: TBytes);
var P: THelloPayload; Ack: TBytes;
begin
  if not ParseHelloPayload(Payload, P) then begin
    SendError(ERR_PROTOCOL, 'Invalid HELLO payload');
    FState := ssClosed; Exit;
  end;
  { Verifica versão mínima }
  if P.ClientVersion < MIN_PROTOCOL then begin
    Ack := BuildHelloAckPayload(ST_VERSION_INCOMPAT, CLIENT_VERSION, UnixNow);
    SendFrame(MSG_HELLO_ACK, Ack);
    FState := ssClosed; Exit;
  end;
  if Assigned(FLogger) then
    FLogger.Info('HELLO from %s OS=%d', [P.Hostname, P.OSType]);
  Ack := BuildHelloAckPayload(ST_OK, CLIENT_VERSION, UnixNow);
  SendFrame(MSG_HELLO_ACK, Ack);
  FState := ssAuth;
end;

procedure TClientSession.HandleAuth(const Hdr: TCBHeader; const Payload: TBytes);
var P: TAuthPayload; Ack: TBytes;
begin
  if not ParseAuthPayload(Payload, P) then begin
    SendError(ERR_PROTOCOL, 'Invalid AUTH payload');
    FState := ssClosed; Exit;
  end;
  if string(P.Token) <> FConfig.AuthToken then begin
    Ack := BuildAuthAckPayload(ST_AUTH_FAILED, 'Invalid token');
    SendFrame(MSG_AUTH_ACK, Ack);
    if Assigned(FLogger) then
      FLogger.Warn('AUTH failed from %s', [PeerAddr]);
    FState := ssClosed; Exit;
  end;
  Ack := BuildAuthAckPayload(ST_OK, '');
  SendFrame(MSG_AUTH_ACK, Ack);
  FState := ssAnnounce;
  if Assigned(FLogger) then
    FLogger.Info('AUTH ok from %s', [PeerAddr]);
end;

procedure TClientSession.HandleAnnounce(const Hdr: TCBHeader; const Payload: TBytes);
var P: TAnnouncePayload; Ack: TBytes;
begin
  if not ParseAnnouncePayload(Payload, P) then begin
    SendError(ERR_PROTOCOL, 'Invalid ANNOUNCE payload');
    FState := ssClosed; Exit;
  end;

  { Salva NodeID do header }
  FNodeID    := Hdr.NodeID;
  FNodeIDHex := NodeIDToHex(FNodeID);

  { Registra nó }
  FRegistry.RegisterNode(
    FNodeIDHex,
    string(P.Profile),   { hostname não está aqui; usamos profile como temp }
    P.OSType,
    string(P.OSVersion),
    string(P.Profile),
    P.Formats,
    P.CapFlags,
    P.MaxPayloadKB,
    SYNC_BIDIR,
    TSessionRef(Self));

  Ack := BuildAnnounceAckPayload(ST_OK);
  SendFrame(MSG_ANNOUNCE_ACK, Ack);
  FState := ssActive;

  if Assigned(FLogger) then
    FLogger.Info('ANNOUNCE: node %s profile=%s formats=0x%08x',
      [FNodeIDHex, P.Profile, P.Formats]);
end;

procedure TClientSession.HandleActive(const Hdr: TCBHeader; const Payload: TBytes);
begin
  case Hdr.MsgType of
    MSG_CLIP_PUBLISH:    HandleClipPublish(Hdr, Payload);
    MSG_CLIP_ACK:        HandleClipAck(Hdr, Payload);
    MSG_PING:            HandlePing(Hdr, Payload);
    MSG_PONG:            HandlePong(Hdr, Payload);
    MSG_SUBSCRIBE_GROUP: HandleSubscribeGroup(Hdr, Payload);
    MSG_GOODBYE:         HandleGoodbye;
  else
    if Assigned(FLogger) then
      FLogger.Warn('Unknown message type 0x%02x from %s', [Hdr.MsgType, FNodeIDHex]);
    SendError(ERR_PROTOCOL, 'Unknown message type');
  end;
end;

procedure TClientSession.HandleClipPublish(const Hdr: TCBHeader; const Payload: TBytes);
var P: TClipPublishPayload;
begin
  if not ParseClipPublishPayload(Payload, P) then begin
    SendError(ERR_PROTOCOL, 'Invalid CLIP_PUBLISH payload');
    Exit;
  end;
  { Envia ACK imediato ao publicador }
  SendFrame(MSG_CLIP_ACK, BuildClipAckPayload(P.ClipID, ACK_APPLIED));
  { Roteia para outros nós }
  FRouter.RouteClipPublish(FNodeIDHex, Hdr.SeqNum, P);
end;

procedure TClientSession.HandleClipAck(const Hdr: TCBHeader; const Payload: TBytes);
var P: TClipAckPayload;
begin
  if ParseClipAckPayload(Payload, P) then
    if Assigned(FLogger) then
      FLogger.Debug('CLIP_ACK from %s clip=%s status=%d',
        [FNodeIDHex, NodeIDToHex(P.ClipID), P.Status]);
end;

procedure TClientSession.HandlePing(const Hdr: TCBHeader; const Payload: TBytes);
begin
  SendFrame(MSG_PONG, BuildPongPayload(Hdr.SeqNum));
end;

procedure TClientSession.HandlePong(const Hdr: TCBHeader; const Payload: TBytes);
begin
  FPongReceived := True;
  if Assigned(FLogger) then
    FLogger.Debug('PONG from %s RTT≈ok', [FNodeIDHex]);
end;

procedure TClientSession.HandleSubscribeGroup(const Hdr: TCBHeader; const Payload: TBytes);
var P: TSubscribeGroupPayload;
begin
  if not ParseSubscribeGroupPayload(Payload, P) then begin
    SendError(ERR_PROTOCOL, 'Invalid SUBSCRIBE payload');
    Exit;
  end;
  FRouter.HandleSubscribeGroup(FNodeIDHex, P, TSessionRef(Self), Hdr.SeqNum);
end;

procedure TClientSession.HandleGoodbye;
begin
  if Assigned(FLogger) then
    FLogger.Info('GOODBYE from %s', [FNodeIDHex]);
  FState := ssClosed;
end;

{ ── Execute (loop principal da thread) ──────────────────────────────────────── }

procedure TClientSession.Execute;
var
  Hdr        : TCBHeader;
  Payload    : TBytes;
  LastPing   : Int64;
  HandshakeStart: Int64;
  Now2       : Int64;
  PingIntervalSec: Integer;
  PingTimeoutSec: Integer;
  LPeer      : string;
  LLastErr   : Integer;
begin
  FSocket.IOTimeout := 1000;  { timeout de 1s para permitir ping periódico }
  LastPing := DateTimeToUnix(Now);
  HandshakeStart := DateTimeToUnix(Now);

  PingIntervalSec := FConfig.PingInterval;
  if PingIntervalSec < 1 then
    PingIntervalSec := 30;
  PingTimeoutSec := FConfig.PingTimeout;
  if PingTimeoutSec < (PingIntervalSec * 2) then
    PingTimeoutSec := PingIntervalSec * 3;

  try
    while (FState <> ssClosed) and not Terminated do begin
      { Tenta ler um frame; timeout é curto para verificar pings }
      if ReadFrame(FSocket, Hdr, Payload) then begin
        Now2 := DateTimeToUnix(Now);
        { Reset handshake timer on any activity during handshake states }
        if (FState in [ssHello, ssAuth, ssAnnounce]) then
          HandshakeStart := Now2;

        case FState of
          ssHello:    HandleHello(Hdr, Payload);
          ssAuth:     HandleAuth(Hdr, Payload);
          ssAnnounce: HandleAnnounce(Hdr, Payload);
          ssActive:   HandleActive(Hdr, Payload);
        end;
      end else begin
        { ReadFrame falhou: timeout de I/O, EOF ou erro real
          - LastError = EAGAIN/EWOULDBLOCK → IOTimeout (1s), continuar
          - LastError = 0 → EOF: cliente fechou a ligação → terminar
          - Outros valores → erro de socket real → terminar }
        if (FSocket.LastError <> ESysEAGAIN) and
           (FSocket.LastError <> ESysEWOULDBLOCK) then begin
          if (FNodeIDHex <> '') and Assigned(FLogger) then
            FLogger.Info('Connection lost: %s', [FNodeIDHex]);
          Break;
        end;
        { Timeout de I/O — verifica necessidade de ping }
        Now2 := DateTimeToUnix(Now);
        if (FState = ssActive) then begin
          { If a PONG hasn't been received and we've already waited longer
            than the configured ping timeout, disconnect the peer. }
          if (not FPongReceived) and (FPingTimer > 0) and
             ((Now2 - FPingTimer) >= PingTimeoutSec) then begin
            if Assigned(FLogger) then
              FLogger.Warn('Ping timeout for %s (no PONG for %d sec), disconnecting', [FNodeIDHex, PingTimeoutSec]);
            Break;
          end;

          { Send periodic ping every PingInterval seconds }
          if (PingIntervalSec > 0) and ((Now2 - LastPing) >= PingIntervalSec) then begin
            SendPing;
            LastPing := Now2;
          end;
        end;
        { Timeout de handshake }
        if (FState in [ssHello, ssAuth, ssAnnounce]) then begin
          if (Now2 - HandshakeStart) >= HANDSHAKE_TIMEOUT_SEC then begin
            if Assigned(FLogger) then
              FLogger.Warn('Handshake timeout from %s', [PeerAddr]);
            Break;
          end;
        end;
      end;
    end;
  except
    on E: Exception do
    begin
      try
        if Assigned(FLogger) then
        begin
          LPeer := '(unknown)';
          LLastErr := 0;
          if Assigned(FSocket) then
          begin
            try
              LPeer := PeerAddr;
              LLastErr := FSocket.LastError;
            except
              LPeer := '(unknown)';
              LLastErr := 0;
            end;
          end;
          FLogger.Error('Session exception [%s] peer=%s lasterror=%d: %s',
            [FNodeIDHex, LPeer, LLastErr, E.ClassName + ': ' + E.Message]);
        end;
      except
      end;
    end;
  end;

  { Cleanup }
  if FNodeIDHex <> '' then
    FRegistry.UnregisterNode(FNodeIDHex);
  FState := ssClosed;
end;

end.
