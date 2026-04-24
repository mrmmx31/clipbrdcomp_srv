{ agent_core_w98.pas — Núcleo do agente Win98
  Coordena: detecção de clipboard (via WM_DRAWCLIPBOARD) + rede (TNetClientW98).
  Thread principal (Win32 message loop) detecta mudanças via WM_DRAWCLIPBOARD.
  Thread de rede (TNetClientW98) recebe CLIP_PUSH e coloca na fila.
  Thread principal aplica itens da fila ao clipboard local. }

unit agent_core_w98;

{$mode objfpc}{$H+}

interface

uses
  Windows, SyncObjs, Classes, SysUtils,
  cbprotocol, cbhash, cbmessage, cbuuid,
  agent_config_w98, clipboard_win32, agent_netclient_w98,
  wintray_w98, agentlog_w98;

type
  { Item pendente da rede para aplicar ao clipboard }
  TPendingClipItem = record
    FormatType : Byte;
    Content    : TBytes;
    Hash       : TClipHash;
    Valid      : Boolean;
  end;

  TAgentCoreW98 = class
  private
    FConfig    : TAgentConfigW98;
    FClipboard : TClipWin32;
    FNetClient : TNetClientW98;
    FRunning   : Boolean;

    { Fila de itens recebidos da rede (protegida por FCritSect) }
    FCritSect  : TCriticalSection;
    FPendingClip: TPendingClipItem;  { apenas o mais recente }
    FHasPending : Boolean;

    { Anti-loop }
    FLastPubHash   : TClipHash;

    procedure OnClipPush(const P: TClipPushPayload);
    procedure ProcessNetwork;  { consome FPendingClip }
    procedure DoPublishClip(FormatType: Byte; const Content: TBytes;
      const Hash: TClipHash);
  public
    constructor Create(AConfig: TAgentConfigW98; AHiddenWnd: HWND);
    destructor Destroy; override;

    { Chamado pelo WndProc quando WM_DRAWCLIPBOARD chega }
    procedure OnClipboardChanged;

    { Chamado pelo WndProc quando WM_AGENT_APPLYCLIP chega }
    procedure OnApplyPendingClip;

    procedure Start;
    procedure Stop;
    procedure ForceReconnect;
  end;

implementation


constructor TAgentCoreW98.Create(AConfig: TAgentConfigW98; AHiddenWnd: HWND);
begin
  inherited Create;
  FConfig    := AConfig;
  FRunning   := False;
  FHasPending := False;
  FLastPubHash := ZeroHash;
  FCritSect  := TCriticalSection.Create;
  FClipboard := TClipWin32.Create(AConfig.TextCodepage, AConfig.DedupWindowMs);
  FNetClient := TNetClientW98.Create(AConfig, @OnClipPush, AHiddenWnd);
end;

destructor TAgentCoreW98.Destroy;
begin
  Stop;
  FNetClient.Free;
  FClipboard.Free;
  FCritSect.Free;
  inherited;
end;

procedure TAgentCoreW98.Start;
begin
  FRunning := True;
  FNetClient.Start;
end;

procedure TAgentCoreW98.Stop;
begin
  FRunning := False;
  FNetClient.Terminate;
  FNetClient.WaitFor;
end;

{ ── Callback da rede: recebe CLIP_PUSH ──────────────────────────────────────── }

procedure TAgentCoreW98.OnClipPush(const P: TClipPushPayload);
begin
  { Chamado no thread de rede — coloca na fila e sinaliza UI thread }
  if SameText(NodeIDToHex(P.SourceNodeID), FConfig.NodeIDHex) then Exit;

  FCritSect.Enter;
  try
    FPendingClip.FormatType := P.FormatType;
    FPendingClip.Content    := Copy(P.Content);
    FPendingClip.Hash       := P.Hash;
    FPendingClip.Valid      := True;
    FHasPending             := True;
  finally
    FCritSect.Leave;
  end;
  { PostMessage já foi feito em HandleClipPush do TNetClientW98 }
end;

{ ── Aplica item pendente ao clipboard local (chamado no UI thread) ─────────── }

procedure TAgentCoreW98.OnApplyPendingClip;
var Item: TPendingClipItem;
begin
  FCritSect.Enter;
  try
    if not FHasPending then Exit;
    Item        := FPendingClip;
    FHasPending := False;
  finally
    FCritSect.Leave;
  end;

  if HashEqual(Item.Hash, FClipboard.GetLastTextHash) and
     (Item.FormatType = FMT_TEXT_UTF8) then Exit;
  if HashEqual(Item.Hash, FClipboard.GetLastImageHash) and
     (Item.FormatType = FMT_IMAGE_PNG) then Exit;

  FClipboard.RecordApplied(Item.Hash);

  case Item.FormatType of
    FMT_TEXT_UTF8: begin
      if FClipboard.WriteTextUTF8(Item.Content) then
        AgentLog('[CoreW98] Applied text to clipboard (' + IntToStr(Length(Item.Content)) + ' bytes)')
      else
        AgentLog('[CoreW98] Failed to apply text');
    end;
    FMT_IMAGE_PNG: begin
      if FClipboard.WriteImagePNG(Item.Content) then
        AgentLog('[CoreW98] Applied image to clipboard (' + IntToStr(Length(Item.Content)) + ' bytes PNG)')
      else
        AgentLog('[CoreW98] Failed to apply image');
    end;
  else
    AgentLog('[CoreW98] Unknown format: 0x' + IntToHex(Item.FormatType, 2));
  end;
end;

{ ── Detecta mudança local no clipboard (chamado no UI thread) ────────────────── }

procedure TAgentCoreW98.OnClipboardChanged;
var
  Content: TBytes;
  Hash   : TClipHash;
begin
  if FConfig.SyncMode = SYNC_RECV_ONLY then Exit;
  if not FNetClient.Connected then Exit;

  { Verifica texto }
  if FClipboard.ReadTextUTF8(Content, Hash) then begin
    if HashEqual(Hash, FLastPubHash) then Exit;
    if FClipboard.IsSuppressed(Hash) then Exit;
    DoPublishClip(FMT_TEXT_UTF8, Content, Hash);
    Exit;  { prioriza texto }
  end;

  { Verifica imagem }
  if FClipboard.ReadImagePNG(Content, Hash) then begin
    if HashEqual(Hash, FLastPubHash) then Exit;
    if FClipboard.IsSuppressed(Hash) then Exit;
    DoPublishClip(FMT_IMAGE_PNG, Content, Hash);
  end;
end;

procedure TAgentCoreW98.DoPublishClip(FormatType: Byte; const Content: TBytes;
  const Hash: TClipHash);
begin
  FLastPubHash := Hash;
  FNetClient.PublishClip(FormatType, Content, Hash);
  AgentLog('[CoreW98] Published fmt=0x' + IntToHex(FormatType, 2) +
    ' size=' + IntToStr(Length(Content)));
end;

procedure TAgentCoreW98.ProcessNetwork;
begin
  { Não utilizado no modelo de fila por PostMessage; mantido para extensibilidade }
end;

procedure TAgentCoreW98.ForceReconnect;
begin
  FNetClient.ForceReconnect;
end;

end.
