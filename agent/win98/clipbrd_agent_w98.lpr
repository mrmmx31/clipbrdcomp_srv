program clipbrd_agent_w98;

{ ClipBrdComp Agente Windows 98
  Compilar a partir do Linux:
    fpc -Pi386 -Twin32 -Fu../../protocol -Fu../../compat -Fu. \
        clipbrd_agent_w98.lpr -o clipbrd_agent_w98.exe

  Compilar no Windows com FPC:
    fpc -Fu..\..\protocol -Fu..\..\compat -Fu. \
        clipbrd_agent_w98.lpr -o clipbrd_agent_w98.exe

  Requer: libsqlite3 NÃO é necessário aqui (apenas no broker).
  Usa apenas WinAPI + Winsock, disponíveis no Windows 98.

  Arquitetura:
    Thread principal: Win32 message loop + clipboard viewer (WM_DRAWCLIPBOARD)
    Thread de rede:   TNetClientW98 — TCP para o broker }

{$mode objfpc}{$H+}
{$APPTYPE GUI}   { aplicação GUI — sem console no Win98 }

uses
  {$IFDEF WINDOWS}
  {$ENDIF}
  Windows,
  SysUtils,
  agentlog_w98,
  agent_config_w98,
  agent_core_w98,
  wintray_w98;

var
  GConfig : TAgentConfigW98 = nil;
  GCore   : TAgentCoreW98   = nil;

{ Callback chamado quando WM_DRAWCLIPBOARD é recebido (no UI thread) }
procedure OnClipChangeCallback; stdcall;
begin
  if Assigned(GCore) then
    GCore.OnClipboardChanged;
end;

{ WndProc é implementado em wintray_w98 (TrayWndProc).
  Aqui subclassificamos para tratar WM_AGENT_APPLYCLIP. }
var
  GPrevWndProc: WNDPROC = nil;

function AgentWndProc(hWnd: HWND; uMsg: UINT; wParam: WPARAM; lParam: LPARAM): LRESULT; stdcall;
begin
  case uMsg of
    WM_AGENT_APPLYCLIP: begin
      if Assigned(GCore) then GCore.OnApplyPendingClip;
      Result := 0;
    end;
    WM_AGENT_STOP: begin
      if Assigned(GCore) then GCore.Stop;
      DestroyHiddenWindow;
      Result := 0;
    end;
    WM_AGENT_RECONNECT: begin
      if Assigned(GCore) then GCore.ForceReconnect;
      Result := 0;
    end;
  else
    { Delega para o WndProc base (TrayWndProc) }
    Result := TrayWndProc(hWnd, uMsg, wParam, lParam);
  end;
end;

var
  ConfigPath : string;
  AppWnd     : HWND;
  Msg        : TMsg;
  AppInst    : HINST;

begin
  AppInst := GetModuleHandle(nil);

  { Inicializa log antes de tudo }
  AgentLogInit(ExtractFilePath(ParamStr(0)) + 'clipbrd_agent.log');

  ConfigPath := ExtractFilePath(ParamStr(0)) + 'agent_win98.ini';
  if ParamCount >= 1 then ConfigPath := ParamStr(1);

  GConfig := TAgentConfigW98.Create;
  try
    GConfig.LoadFromFile(ConfigPath);
    GConfig.EnsureNodeID;

    if GConfig.BrokerHost = '' then begin
      MessageBoxA(0, 'broker_host not configured!', 'ClipBrdComp Error',
        MB_OK or MB_ICONERROR);
      Halt(1);
    end;

    { Cria janela oculta + registra no clipboard viewer chain }
    AppWnd := CreateHiddenWindow(AppInst, @OnClipChangeCallback);
    if AppWnd = 0 then begin
      MessageBoxA(0, 'Failed to create hidden window!', 'ClipBrdComp Error',
        MB_OK or MB_ICONERROR);
      Halt(2);
    end;

    { Substitui WndProc para capturar WM_AGENT_APPLYCLIP }
    GPrevWndProc := WNDPROC(SetWindowLong(AppWnd, GWL_WNDPROC, LongInt(@AgentWndProc)));

    { Adiciona ícone no system tray — inicia como desconectado (IDI_WARNING) }
    AddTrayIcon(AppWnd, AppInst, 'ClipBrdComp — Desconectado');
    SetTrayLogPath(AnsiString(ExtractFilePath(ParamStr(0)) + 'clipbrd_agent.log'));

    GCore := TAgentCoreW98.Create(GConfig, AppWnd);
    try
      GCore.Start;

      { Loop de mensagens Win32 }
      while GetMessage(Msg, 0, 0, 0) do begin
        TranslateMessage(Msg);
        DispatchMessage(Msg);
      end;
    finally
      GCore.Free;
      GCore := nil;
    end;
  finally
    GConfig.Free;
    GConfig := nil;
  end;
  AgentLogClose;
end.
