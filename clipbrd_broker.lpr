program clipbrd_broker;

{ ClipBrdComp Broker — Servidor central de sincronização de clipboard
  Compilar: fpc -Fu../protocol -Fu../compat clipbrd_broker.lpr -o clipbrd_broker
  Requer: libsqlite3-dev, FPC 3.2.x, pacotes fpc-units-fcl }

{$mode objfpc}{$H+}
{$IFDEF MSWINDOWS}{$APPTYPE CONSOLE}{$ENDIF}

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils, Classes, BaseUnix, Unix,
  cbprotocol,
  broker_logger,
  broker_config,
  broker_db,
  broker_registry,
  broker_router,
  broker_session,
  broker_server;

var
  Config   : TBrokerConfig    = nil;
  DB       : TBrokerDB        = nil;
  Registry : TNodeRegistry    = nil;
  Router   : TClipRouter      = nil;
  Server   : TBrokerServer    = nil;
  GLogger  : TBrokerLogger    = nil;
  Running  : Boolean = True;

{ ── Sinais POSIX ─────────────────────────────────────────────────────────────── }

procedure SigHandler(Sig: LongInt); cdecl;
begin
  WriteLn('');
  WriteLn('Signal ', Sig, ' received — shutting down...');
  Running := False;
end;

{ ── Ponto de entrada ─────────────────────────────────────────────────────────── }

var
  ConfigPath : string;
  LogLevel   : TLogLevel;
  GenerateConfig: Boolean;
  i: Integer;

begin
  ConfigPath     := 'broker.ini';
  GenerateConfig := False;

  { Parseia argumentos }
  for i := 1 to ParamCount do begin
    if ParamStr(i) = '--gen-config' then GenerateConfig := True
    else if ParamStr(i) = '--config' then begin
      if i + 1 <= ParamCount then ConfigPath := ParamStr(i + 1);
    end;
  end;

  WriteLn('ClipBrdComp Broker v1.0');
  WriteLn('========================');

  Config := TBrokerConfig.Create;
  try
    if GenerateConfig then begin
      Config.SaveDefaults(ConfigPath);
      WriteLn('Default config written to: ', ConfigPath);
      Halt(0);
    end;

    Config.LoadFromFile(ConfigPath);

    { Logger }
    GLogger := TBrokerLogger.Create(Config.LogFile, Config.LogLevel, Config.LogConsole);
    Logger  := GLogger;

    GLogger.Info('ClipBrdComp Broker starting...');
    GLogger.Info('Config: %s', [ConfigPath]);
    GLogger.Info('DB: %s', [Config.DBPath]);
    GLogger.Info('Listen: %s:%d', [Config.BindAddr, Config.Port]);

    if Config.AllowInsecure then
      GLogger.Warn('INSECURE MODE ENABLED — do not expose to untrusted networks');

    { Banco de dados }
    DB := TBrokerDB.Create(Config.DBPath, GLogger);

    { Registro de nós }
    Registry := TNodeRegistry.Create(DB, GLogger);

    { Roteador — callback de envio de frame para sessões }
    Router := TClipRouter.Create(Registry, DB, Config, GLogger,
      @RouterSessionDispatch);

    { Servidor TCP }
    Server := TBrokerServer.Create(Registry, Router, Config, GLogger);

    { Instala handlers de sinal }
    fpSignal(SIGINT,  @SigHandler);
    fpSignal(SIGTERM, @SigHandler);

    { Inicia servidor em thread separada }
    Server.Start;

    GLogger.Info('Broker running. Press Ctrl+C to stop.');

    { Loop principal: aguarda sinal de encerramento }
    while Running do begin
      Sleep(500);
      if not Server.Running then begin
        GLogger.Error('Server thread stopped unexpectedly');
        Running := False;
      end;
    end;

    GLogger.Info('Shutting down...');
    Server.StopServer;
    Server.WaitFor;

    GLogger.Info('Broker stopped cleanly.');
  finally
    FreeAndNil(Server);
    FreeAndNil(Router);
    FreeAndNil(Registry);
    FreeAndNil(DB);
    FreeAndNil(Config);
    FreeAndNil(GLogger);
  end;
end.
