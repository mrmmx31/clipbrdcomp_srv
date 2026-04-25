program clipbrd_agent_linux;

{ ClipBrdComp Agente Linux — Sincronização de clipboard via X11/Lazarus
  Compilar: lazbuild clipbrd_agent_linux.lpi
  Requer: Lazarus, FPC 3.2.x, libgtk2-dev (ou equivalente do widgetset)

  Roda na sessão gráfica do usuário.
  Sem janela visível; acessa TClipboard do widgetset ativo. }

{$mode objfpc}{$H+}
{$APPTYPE CONSOLE}

uses
  {$IFDEF UNIX}
  cthreads,      { suporte a threads POSIX — deve ser o PRIMEIRO }
  BaseUnix, Unix,
  {$ENDIF}
  Interfaces,    { registra widgetset Lazarus (GTK2, Qt, etc.) }
  Forms,
  SysUtils,
  agent_config,
  agent_core;

var
  Config : TAgentConfig = nil;
  Core   : TAgentCore   = nil;
  Running: Boolean = True;

procedure SigHandler(sig: LongInt); cdecl;
begin
  WriteLn(StdErr, 'Signal ', sig, ' received — stopping agent (SIGKILL)...');
  if Assigned(Core) then Core.Stop;
  Running := False;
  { Garante encerramento imediato mesmo se o loop de poll estiver bloqueado }
  fpKill(fpGetPID(), SIGKILL);
end;

{$IFDEF UNIX}
{$ENDIF}

var
  ConfigPath: string;

begin
  ConfigPath := ExpandFileName('~/.config/clipbrdcomp/agent_linux.ini');

  { Parseia argumentos }
  if ParamCount >= 1 then ConfigPath := ParamStr(1);

  WriteLn('ClipBrdComp Agent (Linux/X11) v1.0');
  WriteLn('Config: ', ConfigPath);

  { Inicializa Application Lazarus (necessário para TClipboard) }
  Application.Initialize;
  Application.ShowMainForm := False;

  Config := TAgentConfig.Create;
  try
    Config.LoadFromFile(ConfigPath);
    Config.EnsureNodeID;

    if Config.BrokerHost = '' then begin
      WriteLn('ERROR: broker_host not set in config.');
      Halt(1);
    end;

    {$IFDEF UNIX}
    fpSignal(SIGINT,  @SigHandler);
    fpSignal(SIGTERM, @SigHandler);
    {$ENDIF}

    Core := TAgentCore.Create(Config);
    try
      Core.Run;  { bloqueia até Stop ser chamado }
    finally
      Core.Free;
    end;
  finally
    Config.Free;
  end;

  WriteLn('Agent stopped.');
end.
