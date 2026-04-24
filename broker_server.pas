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
  try
    Session := TClientSession.Create(Data, FRegistry, FRouter, FConfig, FLogger);
    Session.Start;
  except
    on E: Exception do
    begin
      if Assigned(FLogger) then
        FLogger.Error('HandleConnection error: %s', [E.Message]);
      { If session creation failed, free the provided stream to avoid leak }
      try
        Data.Free;
      except
      end;
    end;
  end;
end;

procedure TBrokerServer.Execute;
begin
  try
    { Do not create the listening socket here — the inner accept loop is
      responsible for creating/recreating the TInetServer instance. Set
      to nil so we don't accidentally overwrite an existing instance. }
    FServer := nil;
    FRunning := True;

    { Start accept loop. Keep acceptor resilient: if StartAccepting raises
      we catch, log and attempt to recreate/restart the listener unless the
      thread was requested to terminate. This prevents a single transient
      exception from taking the whole server down. }
    var
      attempts: Integer;
    begin
      attempts := 0;
      try
        { Try to create/listen on the configured address; if bind fails keep retrying
          until the thread is terminated. This handles transient bind conflicts. }
        while not Terminated do
        begin
          try
            FServer := TInetServer.Create(FConfig.BindAddr, FConfig.Port);
            FServer.MaxConnections := FConfig.MaxConns;
            FServer.OnConnect := @HandleConnection;
            FRunning := True;

            if Assigned(FLogger) then
              FLogger.Info('Broker listening on %s:%d', [FConfig.BindAddr, FConfig.Port]);

            Break; { created successfully }
          except
            on E: Exception do
            begin
              Inc(attempts);
              if Assigned(FLogger) then
                FLogger.Error('Server create/bind failed (attempt %d): %s',
                  [attempts, E.ClassName + ': ' + E.Message]);
              Sleep(1000);
            end;
          end;
        end;

        if not Assigned(FServer) then
        begin
          if Assigned(FLogger) then
            FLogger.Error('Server could not be created — exiting acceptor thread');
          Exit;
        end;

        { Start accept loop. Keep acceptor resilient: if StartAccepting raises
          we catch, log and attempt to recreate/restart the listener unless the
          thread was requested to terminate. This prevents a single transient
          exception from taking the whole server down. }
        while not Terminated do
        begin
          try
            FServer.StartAccepting;
            { StartAccepting returned due to StopAccepting -> exit loop }
            Break;
          except
            on E: Exception do
            begin
              if Assigned(FLogger) then
                FLogger.Error('Server accept loop error: %s — retrying in 1s', [E.ClassName + ': ' + E.Message]);
              Sleep(1000);
              { Attempt to recreate the listening socket in case it's in a bad state }
              try
                if Assigned(FServer) then
                  FreeAndNil(FServer);
                FServer := TInetServer.Create(FConfig.BindAddr, FConfig.Port);
                FServer.MaxConnections := FConfig.MaxConns;
                FServer.OnConnect := @HandleConnection;
              except
                on E2: Exception do
                begin
                  if Assigned(FLogger) then
                    FLogger.Error('Failed to recreate server after error: %s', [E2.ClassName + ': ' + E2.Message]);
                  Sleep(1000);
                end;
              end;
            end;
          end;
        end;
  except
    on E: Exception do
    begin
      if Assigned(FLogger) then
        FLogger.Error('Server fatal: %s', [E.ClassName + ': ' + E.Message]);
    end;
  end;
  FRunning := False;
  if Assigned(FLogger) then
    FLogger.Info('Server thread exiting.');
end;

end.
