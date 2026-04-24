{ wintray_w98.pas — Ícone de system tray e janela oculta para Windows 98
  Usa Shell_NotifyIcon (disponível desde Win95).
  A janela oculta serve também para receber WM_DRAWCLIPBOARD.
  Menu de contexto: Ver Log, Reconectar, Sair. }

unit wintray_w98;

{$mode objfpc}{$H+}

interface

uses Windows, ShellAPI;

const
  WM_TRAYICON         = WM_USER + 1;
  WM_AGENT_CLIPCHG    = WM_USER + 2;  { clipboard mudou }
  WM_AGENT_APPLYCLIP  = WM_USER + 3;  { aplicar clipboard da rede }
  WM_AGENT_STOP       = WM_USER + 4;  { parar agente }
  WM_AGENT_CONNCHANGE = WM_USER + 5;  { wParam: 1=conectado, 0=desconectado }
  WM_AGENT_RECONNECT  = WM_USER + 6;  { forçar reconexão }

  TRAY_ID = 1;

  { IDs dos itens do menu de contexto }
  MENU_SHOWLOG   = 1001;
  MENU_RECONNECT = 1002;
  MENU_EXIT      = 1003;

type
  TClipChangeNotify = procedure; stdcall;

var
  GHiddenWnd      : HWND        = 0;
  GNextClipViewer : HWND        = 0;
  GOnClipChange   : TClipChangeNotify = nil;
  GTrayConnected  : Boolean     = False;
  GLogFilePath    : AnsiString  = '';
  GAppInst        : HINST       = 0;

function  CreateHiddenWindow(AInst: HINST; OnClipChange: TClipChangeNotify): HWND;
function  AddTrayIcon(AWnd: HWND; AInst: HINST; const Tip: string): Boolean;
procedure RemoveTrayIcon(AWnd: HWND);
procedure DestroyHiddenWindow;
procedure UpdateTrayStatus(AConnected: Boolean);
procedure SetTrayLogPath(const Path: AnsiString);
function  TrayWndProc(AWnd: HWND; uMsg: UINT; wParam: WPARAM; lParam: LPARAM): LRESULT; stdcall;

implementation

const
  WNDCLASSNAME = 'ClipBrdCompAgent';

procedure SetTrayLogPath(const Path: AnsiString);
begin
  GLogFilePath := Path;
end;

procedure UpdateTrayStatus(AConnected: Boolean);
var NID: TNotifyIconDataA; TipA: AnsiString; TipLen: Integer;
begin
  GTrayConnected := AConnected;
  if GHiddenWnd = 0 then Exit;
  FillChar(NID, SizeOf(NID), 0);
  NID.cbSize := SizeOf(NID);
  NID.hWnd   := GHiddenWnd;
  NID.uID    := TRAY_ID;
  NID.uFlags := NIF_ICON or NIF_TIP;
  if AConnected then begin
    NID.hIcon := LoadIcon(GAppInst, 'MAINICON');
    if NID.hIcon = 0 then NID.hIcon := LoadIcon(0, IDI_APPLICATION);
    TipA := 'ClipBrdComp — Conectado';
  end else begin
    NID.hIcon := LoadIcon(0, IDI_EXCLAMATION);
    TipA := 'ClipBrdComp — Desconectado';
  end;
  TipLen := Length(TipA);
  if TipLen > 63 then TipLen := 63;
  Move(TipA[1], NID.szTip, TipLen);
  Shell_NotifyIconA(NIM_MODIFY, @NID);
end;

procedure ShowTrayMenu(AWnd: HWND);
var
  Menu      : HMENU;
  Pt        : TPoint;
  StatusStr : AnsiString;
begin
  Menu := CreatePopupMenu;
  if Menu = 0 then Exit;

  FillChar(Pt, SizeOf(Pt), 0);

  { Linha de status (desabilitada — só informativa) }
  if GTrayConnected then
    StatusStr := 'Estado: Conectado'
  else
    StatusStr := 'Estado: Desconectado';
  AppendMenuA(Menu, MF_STRING or MF_GRAYED, 0, PAnsiChar(StatusStr));
  AppendMenuA(Menu, MF_SEPARATOR, 0, nil);

  AppendMenuA(Menu, MF_STRING, MENU_SHOWLOG,   'Ver Log...');
  AppendMenuA(Menu, MF_SEPARATOR, 0, nil);
  AppendMenuA(Menu, MF_STRING, MENU_RECONNECT, 'Reconectar');
  AppendMenuA(Menu, MF_SEPARATOR, 0, nil);
  AppendMenuA(Menu, MF_STRING, MENU_EXIT,      'Sair');

  GetCursorPos(Pt);
  { Obrigatório antes de TrackPopupMenu para menus de tray }
  SetForegroundWindow(AWnd);
  TrackPopupMenu(Menu, TPM_RIGHTALIGN or TPM_BOTTOMALIGN or TPM_RIGHTBUTTON,
    Pt.X, Pt.Y, 0, AWnd, nil);
  { Workaround Win9x: força a janela a processar a mensagem }
  PostMessage(AWnd, WM_NULL, 0, 0);
  DestroyMenu(Menu);
end;

function TrayWndProc(AWnd: HWND; uMsg: UINT; wParam: WPARAM; lParam: LPARAM): LRESULT; stdcall;
var
  WParamHWND : HWND;
  LParamHWND : HWND;
begin
  Result := 0;
  WParamHWND := HWND(wParam);
  LParamHWND := HWND(lParam);
  case uMsg of
    WM_DRAWCLIPBOARD: begin
      if Assigned(GOnClipChange) then GOnClipChange;
      if GNextClipViewer <> 0 then
        SendMessage(GNextClipViewer, WM_DRAWCLIPBOARD, wParam, lParam);
    end;

    WM_CHANGECBCHAIN: begin
      if WParamHWND = GNextClipViewer then
        GNextClipViewer := LParamHWND
      else if GNextClipViewer <> 0 then
        SendMessage(GNextClipViewer, WM_CHANGECBCHAIN, wParam, lParam);
    end;

    WM_TRAYICON: begin
      case lParam of
        WM_RBUTTONUP,
        WM_LBUTTONUP:    ShowTrayMenu(AWnd);
        WM_LBUTTONDBLCLK: begin
          { Duplo clique: abre o log directamente }
          if GLogFilePath <> '' then
            ShellExecuteA(0, 'open', 'notepad.exe',
              PAnsiChar(GLogFilePath), nil, SW_SHOW);
        end;
      end;
    end;

    WM_COMMAND: begin
      case LoWord(wParam) of
        MENU_SHOWLOG: begin
          if GLogFilePath <> '' then
            ShellExecuteA(0, 'open', 'notepad.exe',
              PAnsiChar(GLogFilePath), nil, SW_SHOW)
          else
            MessageBoxA(AWnd, 'Log file not configured.',
              'ClipBrdComp', MB_OK or MB_ICONINFORMATION);
        end;
        MENU_RECONNECT:
          PostMessage(AWnd, WM_AGENT_RECONNECT, 0, 0);
        MENU_EXIT:
          PostMessage(AWnd, WM_AGENT_STOP, 0, 0);
      end;
    end;

    WM_AGENT_CONNCHANGE:
      UpdateTrayStatus(wParam <> 0);

    WM_DESTROY: begin
      if GNextClipViewer <> 0 then
        ChangeClipboardChain(AWnd, GNextClipViewer);
      RemoveTrayIcon(AWnd);
      PostQuitMessage(0);
    end;

    WM_AGENT_STOP:
      DestroyWindow(AWnd);

  else
    Result := DefWindowProc(AWnd, uMsg, wParam, lParam);
  end;
end;

function CreateHiddenWindow(AInst: HINST; OnClipChange: TClipChangeNotify): HWND;
var WC: WNDCLASS;
begin
  Result := 0;
  GAppInst      := AInst;
  GOnClipChange := OnClipChange;
  FillChar(WC, SizeOf(WC), 0);
  WC.lpfnWndProc   := @TrayWndProc;
  WC.hInstance     := AInst;
  WC.lpszClassName := WNDCLASSNAME;
  WC.hbrBackground := COLOR_WINDOW + 1;
  if RegisterClass(WC) = 0 then begin end;  { pode já estar registada }
  Result := CreateWindowEx(0, WNDCLASSNAME, 'ClipBrd Agent', WS_POPUP,
    0, 0, 1, 1, 0, 0, AInst, nil);
  if Result = 0 then Exit;
  ShowWindow(Result, SW_HIDE);
  GHiddenWnd      := Result;
  GNextClipViewer := SetClipboardViewer(Result);
end;

function AddTrayIcon(AWnd: HWND; AInst: HINST; const Tip: string): Boolean;
var NID: TNotifyIconDataA; TipA: AnsiString; TipLen: Integer;
begin
  FillChar(NID, SizeOf(NID), 0);
  NID.cbSize           := SizeOf(NID);
  NID.hWnd             := AWnd;
  NID.uID              := TRAY_ID;
  NID.uFlags           := NIF_ICON or NIF_MESSAGE or NIF_TIP;
  NID.uCallbackMessage := WM_TRAYICON;
  { Inicia com ícone de aviso (desconectado) até receber CONNCHANGE }
  NID.hIcon := LoadIcon(0, IDI_EXCLAMATION);
  TipA   := AnsiString(Copy(Tip, 1, 63));
  TipLen := Length(TipA);
  if TipLen > 63 then TipLen := 63;
  Move(TipA[1], NID.szTip, TipLen);
  Result := Shell_NotifyIconA(NIM_ADD, @NID);
end;

procedure RemoveTrayIcon(AWnd: HWND);
var NID: TNotifyIconDataA;
begin
  FillChar(NID, SizeOf(NID), 0);
  NID.cbSize := SizeOf(NID);
  NID.hWnd   := AWnd;
  NID.uID    := TRAY_ID;
  Shell_NotifyIconA(NIM_DELETE, @NID);
end;

procedure DestroyHiddenWindow;
begin
  if GHiddenWnd <> 0 then begin
    ChangeClipboardChain(GHiddenWnd, GNextClipViewer);
    RemoveTrayIcon(GHiddenWnd);
    DestroyWindow(GHiddenWnd);
    GHiddenWnd      := 0;
    GNextClipViewer := 0;
  end;
end;

end.
