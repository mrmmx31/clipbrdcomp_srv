{ agent_config_w98.pas — Configuração do agente Win98
  Leitor INI mínimo sem dependência de IniFiles do FPC (compatível com Win98).
  Na prática, a unit IniFiles do FPC funciona em Win32, então a usamos. }

unit agent_config_w98;

{$mode objfpc}{$H+}

interface

uses SysUtils, IniFiles, cbuuid, cbprotocol, agentlog_w98;

type
  TAgentConfigW98 = class
  private
    FBrokerHost     : string;
    FBrokerPort     : Integer;
    FReconnectSec   : Integer;
    FPingIntervalSec: Integer;
    FNodeIDHex      : string;
    FHostname       : string;
    FProfile        : string;
    FGroup          : string;
    FSyncMode       : Byte;   { SYNC_RECV_ONLY, SYNC_SEND_ONLY, SYNC_BIDIR }
    FAuthToken      : string;
    FLogFile        : string;
    FMaxPayloadKB   : Integer;
    FDedupWindowMs  : Integer;
    FTextCodepage   : Integer;
    FConfigPath     : string;
  public
    constructor Create;
    procedure LoadFromFile(const Path: string);
    procedure SaveNodeID(const NodeIDHex: string);
    procedure EnsureNodeID;

    property BrokerHost     : string   read FBrokerHost;
    property BrokerPort     : Integer  read FBrokerPort;
    property ReconnectSec   : Integer  read FReconnectSec;
    property PingIntervalSec: Integer  read FPingIntervalSec;
    property NodeIDHex      : string   read FNodeIDHex;
    property Hostname       : string   read FHostname;
    property Profile        : string   read FProfile;
    property Group          : string   read FGroup;
    property SyncMode       : Byte     read FSyncMode;
    property AuthToken      : string   read FAuthToken;
    property LogFile        : string   read FLogFile;
    property MaxPayloadKB   : Integer  read FMaxPayloadKB;
    property DedupWindowMs  : Integer  read FDedupWindowMs;
    property TextCodepage   : Integer  read FTextCodepage;
    property ConfigPath     : string   read FConfigPath;
  end;

implementation

uses Windows;

function GetLocalHostname: string;
var Buf: array[0..255] of AnsiChar; Len: DWORD;
begin
  Len := 256;
  if GetComputerNameA(Buf, Len) then
    Result := string(Buf)
  else
    Result := 'win98-node';
end;

constructor TAgentConfigW98.Create;
begin
  inherited;
  FBrokerHost      := '192.168.1.1';
  FBrokerPort      := 6543;
  FReconnectSec    := 15;
  FPingIntervalSec := 30;
  FNodeIDHex       := '';
  FHostname        := GetLocalHostname;
  FProfile         := 'WIN98_LEGACY';
  FGroup           := 'default';
  FSyncMode        := SYNC_BIDIR;
  FAuthToken       := 'changeme';
  FLogFile         := 'clipbrd_agent.log';
  FMaxPayloadKB    := 4096;
  FDedupWindowMs   := 800;
  FTextCodepage    := 1252;
end;

procedure TAgentConfigW98.LoadFromFile(const Path: string);
var Ini: TIniFile; ModeStr: string;
begin
  FConfigPath := Path;
  if not FileExists(Path) then begin
    AgentLog('Config not found: ' + Path + ' — using defaults');
    Exit;
  end;
  Ini := TIniFile.Create(Path);
  try
    FBrokerHost      := Ini.ReadString ('Network',   'broker_host',            FBrokerHost);
    FBrokerPort      := Ini.ReadInteger('Network',   'broker_port',            FBrokerPort);
    FReconnectSec    := Ini.ReadInteger('Network',   'reconnect_interval_sec', FReconnectSec);
    FPingIntervalSec := Ini.ReadInteger('Network',   'ping_interval_sec',      FPingIntervalSec);

    FNodeIDHex       := Ini.ReadString ('Identity',  'node_id',                '');
    FHostname        := Ini.ReadString ('Identity',  'hostname',               FHostname);

    FProfile         := Ini.ReadString ('Clipboard', 'profile',                FProfile);
    FGroup           := Ini.ReadString ('Clipboard', 'group',                  FGroup);
    FMaxPayloadKB    := Ini.ReadInteger('Clipboard', 'max_payload_kb',         FMaxPayloadKB);
    FDedupWindowMs   := Ini.ReadInteger('Clipboard', 'dedup_window_ms',        FDedupWindowMs);
    FTextCodepage    := Ini.ReadInteger('Clipboard', 'text_codepage',          FTextCodepage);

    ModeStr := LowerCase(Ini.ReadString('Clipboard', 'sync_mode', 'bidirectional'));
    if ModeStr = 'receive_only' then FSyncMode := SYNC_RECV_ONLY
    else if ModeStr = 'send_only' then FSyncMode := SYNC_SEND_ONLY
    else FSyncMode := SYNC_BIDIR;

    FAuthToken       := Ini.ReadString ('Security',  'auth_token',             FAuthToken);
    FLogFile         := Ini.ReadString ('Logging',   'log_file',               FLogFile);
  finally Ini.Free; end;
end;

procedure TAgentConfigW98.SaveNodeID(const NodeIDHex: string);
var Ini: TIniFile;
begin
  FNodeIDHex := NodeIDHex;
  if FConfigPath = '' then Exit;
  Ini := TIniFile.Create(FConfigPath);
  try
    Ini.WriteString('Identity', 'node_id', NodeIDHex);
  finally Ini.Free; end;
end;

procedure TAgentConfigW98.EnsureNodeID;
var N: TNodeID;
begin
  if FNodeIDHex = '' then begin
    N := GenerateUUID;
    FNodeIDHex := NodeIDToHex(N);
    SaveNodeID(FNodeIDHex);
    AgentLog('Generated node_id: ' + FNodeIDHex);
  end;
end;

end.
