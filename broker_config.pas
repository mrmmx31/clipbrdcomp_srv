{ broker_config.pas — Configuração do broker lida de arquivo INI }

unit broker_config;

{$mode objfpc}{$H+}

interface

uses SysUtils, IniFiles, broker_logger;

type
  TBrokerConfig = class
  private
    FBindAddr     : string;
    FPort         : Integer;
    FMaxConns     : Integer;
    FAuthToken    : string;
    FAllowInsecure: Boolean;
    FDBPath       : string;
    FHistorySize  : Integer;
    FHistoryEnabled: Boolean;
    FLogFile      : string;
    FLogLevel     : TLogLevel;
    FLogConsole   : Boolean;
    FPingInterval : Integer;
    FPingTimeout  : Integer;
    FMaxPayloadMB : Integer;
  public
    constructor Create;
    procedure LoadFromFile(const Path: string);
    procedure SaveDefaults(const Path: string);

    property BindAddr     : string     read FBindAddr;
    property Port         : Integer    read FPort;
    property MaxConns     : Integer    read FMaxConns;
    property AuthToken    : string     read FAuthToken;
    property AllowInsecure: Boolean    read FAllowInsecure;
    property DBPath       : string     read FDBPath;
    property HistorySize  : Integer    read FHistorySize;
    property HistoryEnabled: Boolean   read FHistoryEnabled;
    property LogFile      : string     read FLogFile;
    property LogLevel     : TLogLevel  read FLogLevel;
    property LogConsole   : Boolean    read FLogConsole;
    property PingInterval : Integer    read FPingInterval;
    property PingTimeout  : Integer    read FPingTimeout;
    property MaxPayloadMB : Integer    read FMaxPayloadMB;
  end;

function ParseLogLevel(const S: string): TLogLevel;

implementation

function ParseLogLevel(const S: string): TLogLevel;
var L: string;
begin
  L := LowerCase(Trim(S));
  if L = 'debug' then Result := llDebug
  else if L = 'warn'  then Result := llWarn
  else if L = 'error' then Result := llError
  else Result := llInfo;  { padrão }
end;

constructor TBrokerConfig.Create;
begin
  inherited;
  { Valores padrão }
  FBindAddr      := '0.0.0.0';
  FPort          := 6543;
  FMaxConns      := 100;
  FAuthToken     := 'changeme';
  FAllowInsecure := True;
  FDBPath        := './broker.db';
  FHistorySize   := 50;
  FHistoryEnabled:= True;
  FLogFile       := './broker.log';
  FLogLevel      := llInfo;
  FLogConsole    := True;
  FPingInterval  := 30;
  FPingTimeout   := 90;
  FMaxPayloadMB  := 4;
end;

procedure TBrokerConfig.LoadFromFile(const Path: string);
var Ini: TIniFile;
begin
  if not FileExists(Path) then begin
    WriteLn('Config file not found: ', Path, ' — using defaults.');
    Exit;
  end;
  Ini := TIniFile.Create(Path);
  try
    FBindAddr      := Ini.ReadString ('Network',  'bind_address',      FBindAddr);
    FPort          := Ini.ReadInteger('Network',  'port',              FPort);
    FMaxConns      := Ini.ReadInteger('Network',  'max_connections',   FMaxConns);

    FAuthToken     := Ini.ReadString ('Security', 'auth_token',        FAuthToken);
    FAllowInsecure := Ini.ReadBool   ('Security', 'allow_insecure',    FAllowInsecure);

    FDBPath        := Ini.ReadString ('Database', 'db_path',           FDBPath);

    FHistoryEnabled:= Ini.ReadBool   ('History',  'enabled',           FHistoryEnabled);
    FHistorySize   := Ini.ReadInteger('History',  'max_items',         FHistorySize);

    FLogFile       := Ini.ReadString ('Logging',  'log_file',          FLogFile);
    FLogLevel      := ParseLogLevel(Ini.ReadString('Logging', 'log_level', 'info'));
    FLogConsole    := Ini.ReadBool   ('Logging',  'console',           FLogConsole);

    FPingInterval  := Ini.ReadInteger('Network',  'ping_interval_sec', FPingInterval);
    FPingTimeout   := Ini.ReadInteger('Network',  'ping_timeout_sec',  FPingTimeout);
    FMaxPayloadMB  := Ini.ReadInteger('Network',  'max_payload_mb',    FMaxPayloadMB);
    { Validate ping settings — keep sensible defaults }
    if FPingInterval < 5 then
      FPingInterval := 5;
    if FPingTimeout < (FPingInterval * 2) then
      FPingTimeout := FPingInterval * 3;
  finally Ini.Free; end;
end;

procedure TBrokerConfig.SaveDefaults(const Path: string);
var Ini: TIniFile;
begin
  Ini := TIniFile.Create(Path);
  try
    Ini.WriteString ('Network',  'bind_address',      '0.0.0.0');
    Ini.WriteInteger('Network',  'port',              6543);
    Ini.WriteInteger('Network',  'max_connections',   100);
    Ini.WriteString ('Security', 'auth_token',        'CHANGE_THIS_TOKEN');
    Ini.WriteBool   ('Security', 'allow_insecure',    True);
    Ini.WriteString ('Database', 'db_path',           './broker.db');
    Ini.WriteBool   ('History',  'enabled',           True);
    Ini.WriteInteger('History',  'max_items',         50);
    Ini.WriteString ('Logging',  'log_file',          './broker.log');
    Ini.WriteString ('Logging',  'log_level',         'info');
    Ini.WriteBool   ('Logging',  'console',           True);
    Ini.WriteInteger('Network',  'ping_interval_sec', 30);
    Ini.WriteInteger('Network',  'ping_timeout_sec',  90);
    Ini.WriteInteger('Network',  'max_payload_mb',    4);
  finally Ini.Free; end;
end;

end.
