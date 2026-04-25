{ agent_core.pas — Núcleo do agente Linux: coordena clipboard e rede
  Implementa o loop de polling, anti-loop e deduplicação. }

unit agent_core;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes,
  cbprotocol, cbhash, cbmessage,
  agent_config, clipboard_linux, agent_netclient;

type
  TAgentCore = class
  private
    FConfig    : TAgentConfig;
    FClipboard : TLinuxClipboard;
    FNetClient : TNetClient;
    FRunning   : Boolean;

    FLastPubHash    : TClipHash;  { hash do último item que PUBLICAMOS }
    FLastApplyHash  : TClipHash;  { hash do último item que APLICAMOS remotamente }

    { Callback do TNetClient quando recebe CLIP_PUSH }
    procedure OnClipPush(const P: TClipPushPayload);

    procedure PollAndPublish;
    procedure ApplyRemoteText(const Content: TBytes; const Hash: TClipHash);
    procedure ApplyRemoteImage(const Content: TBytes; const Hash: TClipHash);
  public
    constructor Create(AConfig: TAgentConfig);
    destructor Destroy; override;

    procedure Run;  { loop bloqueante — roda na thread principal }
    procedure Stop;
  end;

implementation

uses Forms;  { para Application.ProcessMessages em Lazarus }

constructor TAgentCore.Create(AConfig: TAgentConfig);
begin
  inherited Create;
  FConfig    := AConfig;
  FRunning   := False;
  FClipboard := TLinuxClipboard.Create(AConfig.DedupWindowMs);
  FNetClient := TNetClient.Create(AConfig, @OnClipPush);
  FLastPubHash   := ZeroHash;
  FLastApplyHash := ZeroHash;
end;

destructor TAgentCore.Destroy;
begin
  FNetClient.Terminate;
  FNetClient.WaitFor;
  FNetClient.Free;
  FClipboard.Free;
  inherited;
end;

procedure TAgentCore.Stop;
begin
  FRunning := False;
end;

{ ── Callback: recebe CLIP_PUSH do broker ────────────────────────────────────── }

procedure TAgentCore.OnClipPush(const P: TClipPushPayload);
var
  SourceHex: string;
begin
  SourceHex := NodeIDToHex(P.SourceNodeID);

  { Anti-loop: não aplicar conteúdo que originou deste próprio nó }
  if SameText(SourceHex, FConfig.NodeIDHex) then Exit;

  { Deduplicação: já temos este hash aplicado? }
  if HashEqual(P.Hash, FLastApplyHash) then Exit;

  WriteLn(StdErr, '[AgentCore] CLIP_PUSH fmt=0x', IntToHex(P.FormatType, 2),
    ' size=', Length(P.Content), ' from=', SourceHex);

  case P.FormatType of
    FMT_TEXT_UTF8:  ApplyRemoteText(P.Content, P.Hash);
    FMT_IMAGE_PNG:  ApplyRemoteImage(P.Content, P.Hash);
  else
    WriteLn(StdErr, '[AgentCore] Unsupported format: 0x', IntToHex(P.FormatType, 2));
  end;
end;

procedure TAgentCore.ApplyRemoteText(const Content: TBytes; const Hash: TClipHash);
begin
  { Aplica texto (UTF-8) ao clipboard local }
  if FClipboard.ApplyText(Content) then begin
    FLastApplyHash := Hash;
    FClipboard.RecordApplied(Hash);  { janela de supressão }
    WriteLn(StdErr, '[AgentCore] Applied text to clipboard (', Length(Content), ' bytes)');
  end else
    WriteLn(StdErr, '[AgentCore] Failed to apply text to clipboard');
end;

procedure TAgentCore.ApplyRemoteImage(const Content: TBytes; const Hash: TClipHash);
begin
  if FClipboard.ApplyImage(Content) then begin
    FLastApplyHash := Hash;
    FClipboard.RecordApplied(Hash);
    WriteLn(StdErr, '[AgentCore] Applied image to clipboard (', Length(Content), ' bytes PNG)');
  end else
    WriteLn(StdErr, '[AgentCore] Failed to apply image to clipboard');
end;

{ ── Poll: detecta mudanças no clipboard local ─────────────────────────────────── }

procedure TAgentCore.PollAndPublish;
var
  Content  : TBytes;
  Hash     : TClipHash;
  Preview  : string;
  MaxPrev  : Integer;
begin
  { Não publicar se estiver em modo receive-only }
  if FConfig.SyncMode = smRecvOnly then begin
    WriteLn(StdErr, '[AgentCore] Poll skipped: recv-only mode');
    Exit;
  end;
  if not FNetClient.Connected then begin
    WriteLn(StdErr, '[AgentCore] Poll skipped: not connected');
    Exit;
  end;

  { Verifica texto }
  if FClipboard.PollText(Content, Hash) then begin
    { Anti-loop: este hash foi publicado recentemente por nós? }
    if HashEqual(Hash, FLastPubHash) then begin
      WriteLn(StdErr, '[AgentCore] Text unchanged (same hash), skip publish');
      Exit;
    end;
    { Anti-loop: este hash acabou de ser aplicado de forma remota? }
    if FClipboard.IsSuppressed(Hash) then begin
      WriteLn(StdErr, '[AgentCore] Text suppressed (anti-loop), skip publish');
      Exit;
    end;
    FLastPubHash := Hash;
    { Preview: primeiros 80 chars }
    if Length(Content) > 0 then begin
      MaxPrev := Length(Content);
      if MaxPrev > 80 then MaxPrev := 80;
      SetLength(Preview, MaxPrev);
      Move(Content[0], Preview[1], MaxPrev);
    end else
      Preview := '';
    WriteLn(StdErr, '[AgentCore] Clipboard changed, publishing text (', Length(Content), ' bytes): [', Preview, ']');
    FNetClient.PublishClip(FMT_TEXT_UTF8, Content, Hash);
    WriteLn(StdErr, '[AgentCore] Published text OK (', Length(Content), ' bytes)');
  end else
    WriteLn(StdErr, '[AgentCore] Poll: no text change detected');

  { Verifica imagem — apenas se suporte a imagens habilitado }
  if FClipboard.PollImage(Content, Hash) then begin
    if HashEqual(Hash, FLastPubHash) then begin
      WriteLn(StdErr, '[AgentCore] Image unchanged (same hash), skip publish');
      Exit;
    end;
    if FClipboard.IsSuppressed(Hash) then begin
      WriteLn(StdErr, '[AgentCore] Image suppressed (anti-loop), skip publish');
      Exit;
    end;
    FLastPubHash := Hash;
    WriteLn(StdErr, '[AgentCore] Clipboard changed, publishing image (', Length(Content), ' bytes PNG)');
    FNetClient.PublishClip(FMT_IMAGE_PNG, Content, Hash);
    WriteLn(StdErr, '[AgentCore] Published image OK (', Length(Content), ' bytes PNG)');
  end else
    WriteLn(StdErr, '[AgentCore] Poll: no image change detected');
end;

{ ── Loop principal ───────────────────────────────────────────────────────────── }

procedure TAgentCore.Run;
begin
  FRunning := True;
  WriteLn(StdErr, '[AgentCore] Starting. Node=', FConfig.NodeIDHex);
  WriteLn(StdErr, '[AgentCore] Broker=', FConfig.BrokerHost, ':', FConfig.BrokerPort);
  WriteLn(StdErr, '[AgentCore] Profile=', FConfig.Profile, ' Group=', FConfig.Group);

  FNetClient.Start;

  while FRunning do begin
    { Processa mensagens Lazarus (necessário para clipboard X11) }
    Application.ProcessMessages;

    PollAndPublish;

    Sleep(FConfig.PollMs);
  end;

  WriteLn(StdErr, '[AgentCore] Stopping...');
end;

end.
