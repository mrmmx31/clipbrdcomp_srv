{ agent_netclient_w98.pas — Cliente TCP Winsock para o agente Win98
  Roda em thread separada.
  Usa Winsock 1.1 (compatível com Win98) — funções: socket, connect, send, recv.
  Thread-safe: escrita protegida por critical section. }

unit agent_netclient_w98;

{$mode objfpc}{$H+}

interface

uses
  Windows, WinSock, SysUtils, Classes, SyncObjs,
  cbprotocol, cbhash, cbmessage, cbuuid,
  agent_config_w98, agentlog_w98;

type
  TClipPushCallbackW98 = procedure(const P: TClipPushPayload) of object;

  TNetClientStateW98 = (ncsDisc, ncsConn, ncsAuth, ncsActive);

  { Stream wrapper sobre socket Winsock (implementa TStream) }
  TWinSockStream = class(TStream)
  private
    FSock: TSocket;
  public
    constructor Create(ASock: TSocket);
    function Read(var Buffer; Count: Longint): Longint; override;
    function Write(const Buffer; Count: Longint): Longint; override;
    function Seek(Offset: Longint; Origin: Word): Longint; override;
    property Socket: TSocket read FSock;
  end;

  TNetClientW98 = class(TThread)
  private
    FConfig      : TAgentConfigW98;
    FSock        : TSocket;
    FStream      : TWinSockStream;
    FState       : TNetClientStateW98;
    FSeq         : LongWord;
    FNodeID      : TNodeID;
    FLock        : TCriticalSection;
    FOnClipPush  : TClipPushCallbackW98;
    FConnected   : Boolean;
    FLastPingTick: DWORD;
    FPongOk      : Boolean;
    FHiddenWnd   : HWND;   { para PostMessage de volta ao thread principal }

    function CreateSocket: Boolean;
    procedure DoCloseSocket;
    function DoHandshake: Boolean;
    procedure HandleFrame(const Hdr: TCBHeader; const Payload: TBytes);
    procedure HandleClipPush(const Hdr: TCBHeader; const Payload: TBytes);
    procedure HandlePong(const Hdr: TCBHeader; const Payload: TBytes);
    procedure HandleError(const Hdr: TCBHeader; const Payload: TBytes);

    function NextSeq: LongWord;
    procedure SendFrameLocked(MsgType: Byte; const Payload: TBytes); overload;
    procedure SendFrameLocked(MsgType: Byte); overload;
  protected
    procedure Execute; override;
  public
    constructor Create(AConfig: TAgentConfigW98; AOnClipPush: TClipPushCallbackW98;
      AHiddenWnd: HWND);
    destructor Destroy; override;

    procedure PublishClip(FormatType: Byte; const Content: TBytes;
      const Hash: TClipHash);
    procedure ForceReconnect;

    property Connected: Boolean read FConnected;
  end;

implementation

uses compat_profiles, wintray_w98;

{ ── TWinSockStream ────────────────────────────────────────────────────────────── }

constructor TWinSockStream.Create(ASock: TSocket);
begin
  inherited Create;
  FSock := ASock;
end;

function TWinSockStream.Read(var Buffer; Count: Longint): Longint;
begin
  Result := recv(FSock, Buffer, Count, 0);
  if Result = SOCKET_ERROR then Result := -1;
end;

function TWinSockStream.Write(const Buffer; Count: Longint): Longint;
begin
  Result := send(FSock, Buffer, Count, 0);
  if Result = SOCKET_ERROR then Result := -1;
end;

function TWinSockStream.Seek(Offset: Longint; Origin: Word): Longint;
begin
  Result := -1;  { sockets não são seekable }
end;

{ ── TNetClientW98 ─────────────────────────────────────────────────────────────── }

constructor TNetClientW98.Create(AConfig: TAgentConfigW98;
  AOnClipPush: TClipPushCallbackW98; AHiddenWnd: HWND);
begin
  inherited Create(True);
  FConfig      := AConfig;
  FOnClipPush  := AOnClipPush;
  FHiddenWnd   := AHiddenWnd;
  FSock        := INVALID_SOCKET;
  FStream      := nil;
  FState       := ncsDisc;
  FSeq         := 0;
  FConnected   := False;
  FPongOk      := True;
  FLastPingTick:= 0;
  FLock        := TCriticalSection.Create;
  HexToNodeID(AConfig.NodeIDHex, FNodeID);
  FreeOnTerminate := False;
end;

destructor TNetClientW98.Destroy;
begin
  DoCloseSocket;
  FLock.Free;
  inherited;
end;

function TNetClientW98.NextSeq: LongWord;
begin
  Inc(FSeq);
  Result := FSeq;
end;

procedure TNetClientW98.SendFrameLocked(MsgType: Byte; const Payload: TBytes);
begin
  if FStream = nil then Exit;
  FLock.Enter;
  try
    WriteFrame(FStream, MsgType, 0, FNodeID, NextSeq, Payload);
  except
    FConnected := False;
    FState := ncsDisc;
  end;
  FLock.Leave;
end;

procedure TNetClientW98.SendFrameLocked(MsgType: Byte);
var E: TBytes;
begin
  SetLength(E, 0);
  SendFrameLocked(MsgType, E);
end;

function TNetClientW98.CreateSocket: Boolean;
var
  Addr    : TSockAddrIn;
  HostEnt : PHostEnt;
  Srv     : string;
  Port    : Word;
  Timeout : DWORD;
begin
  Result := False;
  FSock := socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
  if FSock = INVALID_SOCKET then begin
    AgentLog('[NetW98] socket() failed: ' + IntToStr(WSAGetLastError));
    Exit;
  end;

  Srv  := FConfig.BrokerHost;
  Port := FConfig.BrokerPort;

  FillChar(Addr, SizeOf(Addr), 0);
  Addr.sin_family := AF_INET;
  Addr.sin_port   := htons(Port);

  { Resolve host: tenta como IP primeiro, depois DNS }
  Addr.sin_addr.S_addr := inet_addr(PAnsiChar(AnsiString(Srv)));
  if Addr.sin_addr.S_addr = INADDR_NONE then begin
    HostEnt := gethostbyname(PAnsiChar(AnsiString(Srv)));
    if HostEnt = nil then begin
      AgentLog('[NetW98] gethostbyname failed: ' + IntToStr(WSAGetLastError));
      closesocket(FSock);
      FSock := INVALID_SOCKET;
      Exit;
    end;
    Move(HostEnt^.h_addr_list^^, Addr.sin_addr, SizeOf(Addr.sin_addr));
  end;

  if connect(FSock, Addr, SizeOf(Addr)) = SOCKET_ERROR then begin
    AgentLog('[NetW98] connect() failed: ' + IntToStr(WSAGetLastError));
    closesocket(FSock);
    FSock := INVALID_SOCKET;
    Exit;
  end;

  FStream := TWinSockStream.Create(FSock);
  { Timeout de leitura via setsockopt SO_RCVTIMEO }
  Timeout := 2000;  { 2 segundos }
  setsockopt(FSock, SOL_SOCKET, SO_RCVTIMEO, @Timeout, SizeOf(Timeout));

  Result := True;
end;

procedure TNetClientW98.DoCloseSocket;
begin
  if FConnected and (FHiddenWnd <> 0) then
    PostMessage(FHiddenWnd, WM_AGENT_CONNCHANGE, 0, 0);
  FConnected := False;
  FState := ncsDisc;
  if Assigned(FStream) then FreeAndNil(FStream);
  if FSock <> INVALID_SOCKET then begin
    closesocket(FSock);
    FSock := INVALID_SOCKET;
  end;
end;

function TNetClientW98.DoHandshake: Boolean;
var
  Hdr        : TCBHeader;
  Payload    : TBytes;
  HA         : THelloAckPayload;
  AA         : TAuthAckPayload;
  GroupID    : TNodeID;
  Prof       : TCompatProfile;
  AnnPld     : TBytes;
  AP         : TAnnouncePayload;
begin
  Result := False;

  { HELLO }
  SendFrameLocked(MSG_HELLO,
    BuildHelloPayload(OS_WIN98, AnsiString(FConfig.Hostname)));
  if not ReadFrame(FStream, Hdr, Payload) then Exit;
  if Hdr.MsgType <> MSG_HELLO_ACK then Exit;
  if not ParseHelloAckPayload(Payload, HA) then Exit;
  if HA.Status <> ST_OK then begin
    AgentLog('[NetW98] HELLO_ACK rejected');
    Exit;
  end;

  { AUTH }
  SendFrameLocked(MSG_AUTH,
    BuildAuthPayload(AnsiString(FConfig.AuthToken)));
  if not ReadFrame(FStream, Hdr, Payload) then Exit;
  if Hdr.MsgType <> MSG_AUTH_ACK then Exit;
  if not ParseAuthAckPayload(Payload, AA) then Exit;
  if AA.Status <> ST_OK then begin
    AgentLog('[NetW98] AUTH failed: ' + string(AA.Msg));
    Exit;
  end;

  { ANNOUNCE }
  Prof := GetProfile(FConfig.Profile);
  AP.OSType       := OS_WIN98;
  AP.Profile      := AnsiString(FConfig.Profile);
  AP.Formats      := Prof.Formats;
  AP.MaxPayloadKB := Word(FConfig.MaxPayloadKB);
  AP.CapFlags     := Prof.CapFlags;
  AP.OSVersion    := 'Windows 98';
  SendFrameLocked(MSG_ANNOUNCE, BuildAnnouncePayload(AP));
  if not ReadFrame(FStream, Hdr, Payload) then Exit;
  if Hdr.MsgType <> MSG_ANNOUNCE_ACK then Exit;

  { SUBSCRIBE_GROUP }
  if not StringToUUID(FConfig.Group, GroupID) then
    GroupID := DefaultGroupID;
  SendFrameLocked(MSG_SUBSCRIBE_GROUP,
    BuildSubscribeGroupPayload(GroupID, SYNC_BIDIR));
  if not ReadFrame(FStream, Hdr, Payload) then Exit;
  if Hdr.MsgType <> MSG_SUBSCRIBE_ACK then Exit;

  FState := ncsActive;
  FConnected := True;
  AgentLog('[NetW98] Connected. NodeID=' + FConfig.NodeIDHex);
  if FHiddenWnd <> 0 then PostMessage(FHiddenWnd, WM_AGENT_CONNCHANGE, 1, 0);
  Result := True;
end;

procedure TNetClientW98.HandleFrame(const Hdr: TCBHeader; const Payload: TBytes);
begin
  case Hdr.MsgType of
    MSG_CLIP_PUSH:    HandleClipPush(Hdr, Payload);
    MSG_PONG:         HandlePong(Hdr, Payload);
    MSG_PING:         SendFrameLocked(MSG_PONG, BuildPongPayload(Hdr.SeqNum));
    MSG_ERROR:        HandleError(Hdr, Payload);
    MSG_GOODBYE: begin
      AgentLog('[NetW98] Broker sent GOODBYE');
      FConnected := False;
    end;
  end;
end;

procedure TNetClientW98.HandleClipPush(const Hdr: TCBHeader; const Payload: TBytes);
var P: TClipPushPayload;
begin
  if ParseClipPushPayload(Payload, P) then begin
    SendFrameLocked(MSG_CLIP_ACK, BuildClipAckPayload(P.ClipID, ACK_APPLIED));
    if Assigned(FOnClipPush) then FOnClipPush(P);
    { Sinaliza o thread principal da UI para aplicar o clipboard }
    if FHiddenWnd <> 0 then
      PostMessage(FHiddenWnd, WM_AGENT_APPLYCLIP, 0, 0);
  end;
end;

procedure TNetClientW98.HandlePong(const Hdr: TCBHeader; const Payload: TBytes);
begin
  FPongOk := True;
end;

procedure TNetClientW98.HandleError(const Hdr: TCBHeader; const Payload: TBytes);
var P: TErrorPayload;
begin
  if ParseErrorPayload(Payload, P) then
    AgentLog('[NetW98] ERROR: code=' + IntToStr(P.ErrorCode) + ' msg=' + string(P.Msg));
end;

procedure TNetClientW98.PublishClip(FormatType: Byte; const Content: TBytes;
  const Hash: TClipHash);
var P: TClipPublishPayload;
begin
  if not FConnected then Exit;
  P.ClipID       := GenerateUUID;
  P.GroupID      := DefaultGroupID;
  P.FormatType   := FormatType;
  P.OrigOSFormat := $10; { CF_DIB / CF_TEXT — informativo }
  P.Encoding     := ENC_UTF8;
  P.Hash         := Hash;
  P.Content      := Content;
  SendFrameLocked(MSG_CLIP_PUBLISH, BuildClipPublishPayload(P));
end;

procedure TNetClientW98.ForceReconnect;
begin
  DoCloseSocket;
  { O loop Execute vai detectar FConnected=False e reconectar }
end;

procedure TNetClientW98.Execute;
var
  Hdr     : TCBHeader;
  Payload : TBytes;
  WsaData : TWSAData;
  NowTick : DWORD;
  Err     : Integer;
begin
  { Inicializa Winsock 1.1 }
  if WSAStartup(MAKEWORD(1, 1), WsaData) <> 0 then begin
    AgentLog('[NetW98] WSAStartup failed');
    Exit;
  end;

  while not Terminated do begin
    if not CreateSocket then begin
      Sleep(FConfig.ReconnectSec * 1000);
      Continue;
    end;
    if not DoHandshake then begin
      AgentLog('[NetW98] Handshake failed, retrying...');
      DoCloseSocket;
      Sleep(FConfig.ReconnectSec * 1000);
      Continue;
    end;
    FLastPingTick := GetTickCount;
    FPongOk := True;

    while FConnected and not Terminated do begin
      if ReadFrame(FStream, Hdr, Payload) then begin
        HandleFrame(Hdr, Payload);
      end else begin
        { Verifica se foi timeout (WSAETIMEDOUT) ou desconexão real }
        Err := WSAGetLastError;
        if (Err = WSAETIMEDOUT) or (Err = 0) then begin
          { Só timeout — verifica ping }
          NowTick := GetTickCount;
          if (NowTick - FLastPingTick) >= DWORD(FConfig.PingIntervalSec * 1000) then begin
            if not FPongOk then begin
              AgentLog('[NetW98] Ping timeout');
              DoCloseSocket;
              Break;
            end;
            FPongOk := False;
            SendFrameLocked(MSG_PING);
            FLastPingTick := NowTick;
          end;
        end else begin
          AgentLog('[NetW98] Connection error: ' + IntToStr(Err));
          DoCloseSocket;
          Break;
        end;
      end;
    end;

    if not Terminated then
      Sleep(FConfig.ReconnectSec * 1000);
  end;

  WSACleanup;
end;

end.
