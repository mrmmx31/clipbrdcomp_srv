{ broker_server.pas — Loop de accept TCP do broker
  Aguarda conexões e cria TClientSession para cada uma. }

unit broker_server;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, ssockets, sockets,
  broker_logger, broker_config, broker_registry, broker_router, broker_session;

type
  TBrokerServer = class(TThread)
  private
    FServer   : TInetServer;
    FRegistry : TNodeRegistry;
    FRouter   : TClipRouter;
    FConfig   : TBrokerConfig;
    FLogger   : TBrokerLogger;
    FRunning  : Boolean;
    procedure HandleConnection(Sender: TObject; Data: TSocketStream);
  protected
    procedure Execute; override;
  public
    constructor Create(ARegistry: TNodeRegistry; ARouter: TClipRouter;
      AConfig: TBrokerConfig; ALogger: TBrokerLogger);
    destructor Destroy; override;
    procedure StopServer;
    property Running: Boolean read FRunning;
  end;

implementation

constructor TBrokerServer.Create(ARegistry: TNodeRegistry; ARouter: TClipRouter;
  AConfig: TBrokerConfig; ALogger: TBrokerLogger);
begin
  inherited Create(True);
  FRegistry := ARegistry;
  FRouter   := ARouter;
  FConfig   := AConfig;
  FLogger   := ALogger;
  FRunning  := False;
  FreeOnTerminate := False;
end;

destructor TBrokerServer.Destroy;
begin
  if Assigned(FServer) then FServer.Free;
  inherited;
end;

procedure TBrokerServer.StopServer;
begin
  Terminate;
  if Assigned(FServer) then FServer.StopAccepting(False);
end;

procedure TBrokerServer.HandleConnection(Sender: TObject; Data: TSocketStream);
var
  SA      : TInetSockAddr;
  Session : TClientSession;
begin
  SA := TInetSockAddr(Data.RemoteAddress);
  if Assigned(FLogger) then
    FLogger.Info('New connection from %s', [NetAddrToStr(SA.sin_addr)]);
  Session := TClientSession.Create(Data, FRegistry, FRouter, FConfig, FLogger);
  Session.Start;
end;

procedure TBrokerServer.Execute;
begin
  try
    FServer := TInetServer.Create(FConfig.BindAddr, FConfig.Port);
    FServer.MaxConnections := FConfig.MaxConns;
    FServer.OnConnect := @HandleConnection;
    FRunning := True;

    if Assigned(FLogger) then
      FLogger.Info('Broker listening on %s:%d', [FConfig.BindAddr, FConfig.Port]);

    FServer.StartAccepting;
  except
    on E: Exception do
      if Assigned(FLogger) then
        FLogger.Error('Server fatal: %s', [E.Message]);
  end;
  FRunning := False;
end;

end.
