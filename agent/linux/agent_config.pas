{ agent_config.pas — Configuração do agente Linux lida de arquivo INI }

unit agent_config;

{$mode objfpc}{$H+}

interface

uses SysUtils, IniFiles, cbuuid, cbprotocol;

type
  TSyncMode = (smRecvOnly, smSendOnly, smBiDir);

  TAgentConfig = class
  private
    FBrokerHost     : string;
    FBrokerPort     : Integer;
    FReconnectSec   : Integer;
    FPingIntervalSec: Integer;
    FNodeIDHex      : string;
    FHostname       : string;
    FProfile        : string;
    FGroup          : string;
    FSyncMode       : TSyncMode;
    FPollMs         : Integer;
    FAuthToken      : string;
    FLogFile        : string;
    FLogLevel       : string;
    FConfigPath     : string;
    FMaxPayloadKB   : Integer;
    FDedupWindowMs  : Integer;
  public
    constructor Create;
    procedure LoadFromFile(const Path: string);
    procedure SaveToFile(const Path: string);
    procedure EnsureNodeID;

    property BrokerHost     : string     read FBrokerHost;
    property BrokerPort     : Integer    read FBrokerPort;
    property ReconnectSec   : Integer    read FReconnectSec;
    property PingIntervalSec: Integer    read FPingIntervalSec;
    property NodeIDHex      : string     read FNodeIDHex;
    property Hostname       : string     read FHostname;
    property Profile        : string     read FProfile;
    property Group          : string     read FGroup;
    property SyncMode       : TSyncMode  read FSyncMode;
    property PollMs         : Integer    read FPollMs;
    property AuthToken      : string     read FAuthToken;
    property LogFile        : string     read FLogFile;
    property LogLevel       : string     read FLogLevel;
    property ConfigPath     : string     read FConfigPath;
    property MaxPayloadKB   : Integer    read FMaxPayloadKB;
    property DedupWindowMs  : Integer    read FDedupWindowMs;
  end;

implementation

constructor TAgentConfig.Create;
begin
  inherited;
  FBrokerHost      := '127.0.0.1';
  FBrokerPort      := 6543;
  FReconnectSec    := 10;
  FPingIntervalSec := 30;
  FNodeIDHex       := '';
  FHostname        := GetEnvironmentVariable('HOSTNAME');
  if FHostname = '' then FHostname := 'linux-node';
  FProfile         := 'LINUX_X11';
  FGroup           := 'default';
  FSyncMode        := smBiDir;
  FPollMs          := 500;
  FAuthToken       := 'changeme';
  FLogFile         := '/tmp/clipbrd_agent.log';
  FLogLevel        := 'info';
  FMaxPayloadKB    := 16384;
  FDedupWindowMs   := 500;
end;

procedure TAgentConfig.LoadFromFile(const Path: string);
var Ini: TIniFile; ModeStr: string;
begin
  FConfigPath := Path;
  if not FileExists(Path) then Exit;
  Ini := TIniFile.Create(Path);
  try
    FBrokerHost      := Ini.ReadString ('Network',   'broker_host',         FBrokerHost);
    FBrokerPort      := Ini.ReadInteger('Network',   'broker_port',         FBrokerPort);
    FReconnectSec    := Ini.ReadInteger('Network',   'reconnect_interval_sec', FReconnectSec);
    FPingIntervalSec := Ini.ReadInteger('Network',   'ping_interval_sec',   FPingIntervalSec);

    FNodeIDHex       := Ini.ReadString ('Identity',  'node_id',             '');
    FHostname        := Ini.ReadString ('Identity',  'hostname',            FHostname);

    FProfile         := Ini.ReadString ('Clipboard', 'profile',             FProfile);
    FGroup           := Ini.ReadString ('Clipboard', 'group',               FGroup);
    FPollMs          := Ini.ReadInteger('Clipboard', 'poll_interval_ms',    FPollMs);
    FMaxPayloadKB    := Ini.ReadInteger('Clipboard', 'max_payload_kb',      FMaxPayloadKB);
    FDedupWindowMs   := Ini.ReadInteger('Clipboard', 'dedup_window_ms',     FDedupWindowMs);

    ModeStr := LowerCase(Ini.ReadString('Clipboard', 'sync_mode', 'bidirectional'));
    if ModeStr = 'receive_only' then FSyncMode := smRecvOnly
    else if ModeStr = 'send_only' then FSyncMode := smSendOnly
    else FSyncMode := smBiDir;

    FAuthToken       := Ini.ReadString ('Security',  'auth_token',          FAuthToken);
    FLogFile         := Ini.ReadString ('Logging',   'log_file',            FLogFile);
    FLogLevel        := Ini.ReadString ('Logging',   'log_level',           FLogLevel);
  finally Ini.Free; end;
end;

procedure TAgentConfig.SaveToFile(const Path: string);
var Ini: TIniFile;
begin
  Ini := TIniFile.Create(Path);
  try
    Ini.WriteString ('Identity', 'node_id', FNodeIDHex);
    Ini.WriteString ('Identity', 'hostname', FHostname);
  finally Ini.Free; end;
end;

procedure TAgentConfig.EnsureNodeID;
var N: TNodeID;
begin
  if FNodeIDHex = '' then begin
    N := GenerateUUID;
    FNodeIDHex := NodeIDToHex(N);
    WriteLn('Generated node_id: ', FNodeIDHex);
    if FConfigPath <> '' then SaveToFile(FConfigPath);
  end;
end;

end.
