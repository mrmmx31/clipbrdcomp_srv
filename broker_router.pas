{ broker_router.pas — Roteamento de itens de clipboard entre nós
  Recebe um CLIP_PUBLISH, aplica política de compatibilidade,
  e chama SendClipPush em cada sessão alvo. }

unit broker_router;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, DateUtils,
  cbprotocol, cbhash, cbmessage,
  broker_logger, broker_registry, broker_db, broker_config;

type
  { Callback global para enviar frame a uma sessão específica.
    Implementado como função global em broker_session (RouterSessionDispatch).
    Recebe TSessionRef e faz cast para TClientSession.EnqueueSend. }
  TSendFrameProc = procedure(Session: TSessionRef;
    MsgType: Byte; const Payload: TBytes);

  TClipRouter = class
  private
    FRegistry : TNodeRegistry;
    FDB       : TBrokerDB;
    FConfig   : TBrokerConfig;
    FLogger   : TBrokerLogger;
    FSendProc : TSendFrameProc;
    FMaxPayload: Int64;

    { Verifica se nó alvo suporta o formato e o payload cabe }
    function NodeCanReceive(Node: PActiveNode; FormatType: Byte;
      PayloadLen: Integer): Boolean;
  public
    constructor Create(ARegistry: TNodeRegistry; ADB: TBrokerDB;
      AConfig: TBrokerConfig; ALogger: TBrokerLogger;
      ASendProc: TSendFrameProc);

    { Processa um CLIP_PUBLISH recebido de SourceNode }
    { NodeID do remetente é passado; Seq é o seq do remetente para o ACK }
    procedure RouteClipPublish(
      const SourceNodeIDHex: string;
      SourceSeq: LongWord;
      const Pub: TClipPublishPayload);

    { Processa SUBSCRIBE_GROUP }
    procedure HandleSubscribeGroup(
      const NodeIDHex: string;
      const Sub: TSubscribeGroupPayload;
      Session: TSessionRef;
      NodeSeq: LongWord);
  end;

implementation

uses cbuuid, compat_profiles;

constructor TClipRouter.Create(ARegistry: TNodeRegistry; ADB: TBrokerDB;
  AConfig: TBrokerConfig; ALogger: TBrokerLogger;
  ASendProc: TSendFrameProc);
begin
  inherited Create;
  FRegistry  := ARegistry;
  FDB        := ADB;
  FConfig    := AConfig;
  FLogger    := ALogger;
  FSendProc  := ASendProc;
  FMaxPayload:= Int64(AConfig.MaxPayloadMB) * 1024 * 1024;
end;

function TClipRouter.NodeCanReceive(Node: PActiveNode; FormatType: Byte;
  PayloadLen: Integer): Boolean;
begin
  Result := False;

  { Verificar tamanho máximo de payload }
  if Int64(PayloadLen) > Int64(Node^.MaxPayloadKB) * 1024 then Exit;

  { Verificar suporte ao formato }
  case FormatType of
    FMT_TEXT_UTF8:
      Result := (Node^.Formats and FMTBIT_TEXT_UTF8) <> 0;
    FMT_IMAGE_PNG:
      Result := (Node^.Formats and FMTBIT_IMAGE_PNG) <> 0;
    FMT_HTML_UTF8:
      Result := (Node^.Formats and FMTBIT_HTML_UTF8) <> 0;
  else
    Result := False;  { formato desconhecido: rejeitar }
  end;
end;

procedure TClipRouter.RouteClipPublish(
  const SourceNodeIDHex: string;
  SourceSeq: LongWord;
  const Pub: TClipPublishPayload);
var
  GroupIDHex  : string;
  TargetNodes : TList;
  i           : Integer;
  TargetNode  : PActiveNode;
  PushPayload : TClipPushPayload;
  PayloadBytes: TBytes;
  SrcNode     : PActiveNode;
  HistRec     : TClipHistoryRecord;
  ClipIDHex   : string;
begin
  GroupIDHex := NodeIDToHex(Pub.GroupID);
  ClipIDHex  := NodeIDToHex(Pub.ClipID);

  { Valida formato (somente formatos canônicos são aceitos na rede) }
  if not (Pub.FormatType in [FMT_TEXT_UTF8, FMT_IMAGE_PNG, FMT_HTML_UTF8]) then begin
    if Assigned(FLogger) then
      FLogger.Warn('CLIP_PUBLISH from %s: non-canonical format 0x%02x rejected',
        [SourceNodeIDHex, Pub.FormatType]);
    Exit;
  end;

  { Valida tamanho }
  if Int64(Length(Pub.Content)) > FMaxPayload then begin
    if Assigned(FLogger) then
      FLogger.Warn('CLIP_PUBLISH from %s: payload %d bytes exceeds max %d',
        [SourceNodeIDHex, Length(Pub.Content), FMaxPayload]);
    Exit;
  end;

  if Assigned(FLogger) then
    FLogger.Info('CLIP_PUBLISH from %s group=%s fmt=0x%02x size=%d hash=%s',
      [SourceNodeIDHex, GroupIDHex, Pub.FormatType, Length(Pub.Content),
       HashToHex(Pub.Hash)]);

  { Persiste no histórico }
  if Assigned(FDB) and FConfig.HistoryEnabled then begin
    HistRec.ClipIDHex       := ClipIDHex;
    HistRec.SourceNodeIDHex := SourceNodeIDHex;
    HistRec.GroupIDHex      := GroupIDHex;
    HistRec.FormatType      := Pub.FormatType;
    HistRec.HashHex         := HashToHex(Pub.Hash);
    HistRec.CreatedAt       := DateTimeToUnix(Now);
    HistRec.Payload         := Pub.Content;
    FDB.InsertClipHistory(HistRec);
    FDB.PruneHistory(GroupIDHex, FConfig.HistorySize);
  end;

  { Busca nós alvo no grupo (exclui o remetente) }
  TargetNodes := FRegistry.GetGroupNodes(GroupIDHex, SourceNodeIDHex);
  try
    if TargetNodes.Count = 0 then begin
      if Assigned(FLogger) then
        FLogger.Debug('No target nodes for group %s', [GroupIDHex]);
      Exit;
    end;

    { Prepara payload CLIP_PUSH }
    PushPayload.ClipID       := Pub.ClipID;
    PushPayload.GroupID      := Pub.GroupID;
    PushPayload.FormatType   := Pub.FormatType;
    PushPayload.Encoding     := Pub.Encoding;
    PushPayload.Hash         := Pub.Hash;
    PushPayload.Content      := Pub.Content;

    { Converte source node ID hex para TNodeID }
    HexToNodeID(SourceNodeIDHex, PushPayload.SourceNodeID);

    { Envia para cada nó elegível }
    for i := 0 to TargetNodes.Count - 1 do begin
      TargetNode := PActiveNode(TargetNodes[i]);

      { Verifica capacidade }
      if not NodeCanReceive(TargetNode, Pub.FormatType, Length(Pub.Content)) then begin
        if Assigned(FLogger) then
          FLogger.Debug('Skipping node %s: format/size not supported', [TargetNode^.NodeIDHex]);
        Continue;
      end;

      { Envia CLIP_PUSH via callback (thread da sessão alvo) }
      PayloadBytes := BuildClipPushPayload(PushPayload);
      if Assigned(FSendProc) then
      begin
        try
          FSendProc(TargetNode^.SessionRef, MSG_CLIP_PUSH, PayloadBytes);
        except
          on E: Exception do
          begin
            try
              if Assigned(FLogger) then
                FLogger.Error('Exception sending CLIP_PUSH to %s: %s',
                  [TargetNode^.NodeIDHex, E.ClassName + ': ' + E.Message]);
            except
            end;
          end;
        end;
      end;

      if Assigned(FLogger) then
        FLogger.Debug('CLIP_PUSH sent to %s', [TargetNode^.NodeIDHex]);
    end;
  finally
    TargetNodes.Free;
  end;
end;

procedure TClipRouter.HandleSubscribeGroup(
  const NodeIDHex: string;
  const Sub: TSubscribeGroupPayload;
  Session: TSessionRef;
  NodeSeq: LongWord);
var
  GroupIDHex : string;
  GroupRec   : TGroupRecord;
  AckPayload : TBytes;
  BrokerID   : TNodeID;
begin
  GroupIDHex := NodeIDToHex(Sub.GroupID);

  { Verifica se grupo existe (ou é o default) }
  if NodeIDIsZero(Sub.GroupID) then begin
    { zeros -> usa grupo default }
    GroupIDHex := NodeIDToHex(DefaultGroupID);
  end;

  FRegistry.AddNodeToGroup(NodeIDHex, GroupIDHex, Sub.Mode);

  if Assigned(FLogger) then
    FLogger.Info('Node %s subscribed to group %s mode=%d',
      [NodeIDHex, GroupIDHex, Sub.Mode]);

  { Envia ACK }
  NodeIDZero(BrokerID);
  AckPayload := BuildSubscribeAckPayload(ST_OK, GroupIDHex);
  if Assigned(FSendProc) then
    FSendProc(Session, MSG_SUBSCRIBE_ACK, AckPayload);
end;

end.
