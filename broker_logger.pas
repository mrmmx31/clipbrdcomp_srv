{ broker_logger.pas — Logger thread-safe para o broker
  Níveis: debug, info, warn, error. Escreve em arquivo e opcionalmente em stdout. }

unit broker_logger;

{$mode objfpc}{$H+}

interface

uses SysUtils, Classes, SyncObjs;

type
  TLogLevel = (llDebug, llInfo, llWarn, llError);

  TBrokerLogger = class
  private
    FLock     : TCriticalSection;
    FFile     : TextFile;
    FFileOpen : Boolean;
    FLevel    : TLogLevel;
    FLogPath  : string;
    FConsole  : Boolean;
    procedure WriteEntry(Level: TLogLevel; const Msg: string);
  public
    constructor Create(const LogPath: string; Level: TLogLevel; Console: Boolean = True);
    destructor Destroy; override;

    procedure Debug(const Msg: string); overload;
    procedure Info (const Msg: string); overload;
    procedure Warn (const Msg: string); overload;
    procedure Error(const Msg: string); overload;

    procedure Debug(const Fmt: string; const Args: array of const); overload;
    procedure Info (const Fmt: string; const Args: array of const); overload;
    procedure Warn (const Fmt: string; const Args: array of const); overload;
    procedure Error(const Fmt: string; const Args: array of const); overload;

    property Level: TLogLevel read FLevel write FLevel;
  end;

const
  LOG_LEVEL_NAMES: array[TLogLevel] of string = ('DEBUG', 'INFO ', 'WARN ', 'ERROR');

var
  Logger: TBrokerLogger = nil;

implementation

constructor TBrokerLogger.Create(const LogPath: string; Level: TLogLevel; Console: Boolean);
begin
  inherited Create;
  FLock    := TCriticalSection.Create;
  FLevel   := Level;
  FLogPath := LogPath;
  FConsole := Console;
  FFileOpen := False;
  if LogPath <> '' then begin
    try
      { Garante que o diretório existe }
      ForceDirectories(ExtractFilePath(LogPath));
      AssignFile(FFile, LogPath);
      Append(FFile);
      FFileOpen := True;
    except
      try
        Rewrite(FFile);
        FFileOpen := True;
      except
        FFileOpen := False;
      end;
    end;
  end;
end;

destructor TBrokerLogger.Destroy;
begin
  if FFileOpen then CloseFile(FFile);
  FLock.Free;
  inherited;
end;

procedure TBrokerLogger.WriteEntry(Level: TLogLevel; const Msg: string);
var Line: string;
begin
  if Level < FLevel then Exit;
  Line := FormatDateTime('[yyyy-mm-dd hh:nn:ss] ', Now) +
          '[' + LOG_LEVEL_NAMES[Level] + '] ' + Msg;
  FLock.Enter;
  try
    if FFileOpen then begin
      WriteLn(FFile, Line);
      Flush(FFile);
    end;
    if FConsole then
      WriteLn(Line);
  finally FLock.Leave; end;
end;

procedure TBrokerLogger.Debug(const Msg: string);
begin WriteEntry(llDebug, Msg); end;

procedure TBrokerLogger.Info(const Msg: string);
begin WriteEntry(llInfo, Msg); end;

procedure TBrokerLogger.Warn(const Msg: string);
begin WriteEntry(llWarn, Msg); end;

procedure TBrokerLogger.Error(const Msg: string);
begin WriteEntry(llError, Msg); end;

procedure TBrokerLogger.Debug(const Fmt: string; const Args: array of const);
begin WriteEntry(llDebug, Format(Fmt, Args)); end;

procedure TBrokerLogger.Info(const Fmt: string; const Args: array of const);
begin WriteEntry(llInfo, Format(Fmt, Args)); end;

procedure TBrokerLogger.Warn(const Fmt: string; const Args: array of const);
begin WriteEntry(llWarn, Format(Fmt, Args)); end;

procedure TBrokerLogger.Error(const Fmt: string; const Args: array of const);
begin WriteEntry(llError, Format(Fmt, Args)); end;

end.
