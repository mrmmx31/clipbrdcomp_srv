{ agentlog_w98.pas — Log para aplicação GUI Win32 (sem console).
  Escreve para ficheiro de texto. Thread-safe via CriticalSection.
  Em aplicações GUI o WriteLn causa "EInOutError: File not open". }

unit agentlog_w98;

{$mode objfpc}{$H+}

interface

{ Inicializa o log com o caminho do ficheiro. Deve ser chamado antes de AgentLog. }
procedure AgentLogInit(const FilePath: string);

{ Escreve uma linha no ficheiro de log. }
procedure AgentLog(const Msg: string);

{ Fecha o ficheiro de log. }
procedure AgentLogClose;

implementation

uses Windows, SysUtils;

var
  GLogFile    : TextFile;
  GLogOpen    : Boolean = False;
  GLogCS      : TRTLCriticalSection;
  GLogCSInited: Boolean = False;

procedure AgentLogInit(const FilePath: string);
begin
  if not GLogCSInited then begin
    InitializeCriticalSection(GLogCS);
    GLogCSInited := True;
  end;
  EnterCriticalSection(GLogCS);
  try
    if GLogOpen then CloseFile(GLogFile);
    AssignFile(GLogFile, FilePath);
    {$I-}
    Append(GLogFile);
    if IOResult <> 0 then Rewrite(GLogFile);
    {$I+}
    GLogOpen := (IOResult = 0);
  finally
    LeaveCriticalSection(GLogCS);
  end;
end;

procedure AgentLog(const Msg: string);
var Line: string;
begin
  if not GLogCSInited then Exit;
  EnterCriticalSection(GLogCS);
  try
    if GLogOpen then begin
      Line := FormatDateTime('yyyy-mm-dd hh:nn:ss', Now) + '  ' + Msg;
      WriteLn(GLogFile, Line);
      Flush(GLogFile);
    end;
  finally
    LeaveCriticalSection(GLogCS);
  end;
end;

procedure AgentLogClose;
begin
  if not GLogCSInited then Exit;
  EnterCriticalSection(GLogCS);
  try
    if GLogOpen then begin
      CloseFile(GLogFile);
      GLogOpen := False;
    end;
  finally
    LeaveCriticalSection(GLogCS);
    DeleteCriticalSection(GLogCS);
    GLogCSInited := False;
  end;
end;

end.
