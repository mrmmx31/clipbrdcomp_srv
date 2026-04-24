{ compat_profiles.pas — Definição de perfis de compatibilidade por nó
  Compartilhado entre broker e agentes. }

unit compat_profiles;

{$mode objfpc}{$H+}

interface

uses cbprotocol;

type
  TCompatProfile = record
    Name              : AnsiString;
    OSType            : Byte;
    TextLocalFormat   : Byte;    { FMT_TEXT_xxx }
    TextNetFormat     : Byte;    { sempre FMT_TEXT_UTF8 na rede }
    ImageLocalFormat  : Byte;    { FMT_IMAGE_xxx }
    ImageNetFormat    : Byte;    { sempre FMT_IMAGE_PNG na rede }
    TextCodepage      : Integer; { codepage do texto local; 0=UTF-8 }
    SupportsHTML      : Boolean;
    SupportsImages    : Boolean;
    SupportsBiDir     : Boolean;
    MaxPayloadKB      : Integer;
    DedupWindowMs     : Integer;
    Formats           : LongWord;  { bitmask FMTBIT_xxx }
    CapFlags          : Byte;      { bitmask CAP_xxx }
  end;

{ Retorna perfil padrão pelo nome. Se não encontrado, retorna perfil genérico. }
function GetProfile(const Name: AnsiString): TCompatProfile;
function GetProfileByOSType(OSType: Byte): TCompatProfile;

{ Lista de perfis conhecidos }
function ProfileCount: Integer;
function ProfileByIndex(Idx: Integer): TCompatProfile;

{ Aplica overrides de um arquivo INI ao perfil base }
procedure ApplyProfileOverrides(var P: TCompatProfile;
  const IniSection: AnsiString; const IniFile: AnsiString);

implementation

uses IniFiles, SysUtils;

const
  KNOWN_PROFILES: array[0..4] of TCompatProfile = (
    { WIN98_LEGACY }
    (Name: 'WIN98_LEGACY';
     OSType: OS_WIN98;
     TextLocalFormat: FMT_TEXT_ANSI;
     TextNetFormat: FMT_TEXT_UTF8;
     ImageLocalFormat: FMT_IMAGE_DIB;
     ImageNetFormat: FMT_IMAGE_PNG;
     TextCodepage: 1252;
     SupportsHTML: False;
     SupportsImages: True;
     SupportsBiDir: True;
     MaxPayloadKB: 4096;
     DedupWindowMs: 800;
     Formats: FMTBIT_TEXT_UTF8 or FMTBIT_IMAGE_PNG;
     CapFlags: CAP_BIDIR or CAP_IMAGES),

    { WINNT_ANSI }
    (Name: 'WINNT_ANSI';
     OSType: OS_WINNT_ANSI;
     TextLocalFormat: FMT_TEXT_ANSI;
     TextNetFormat: FMT_TEXT_UTF8;
     ImageLocalFormat: FMT_IMAGE_DIB;
     ImageNetFormat: FMT_IMAGE_PNG;
     TextCodepage: 1252;
     SupportsHTML: False;
     SupportsImages: True;
     SupportsBiDir: True;
     MaxPayloadKB: 8192;
     DedupWindowMs: 600;
     Formats: FMTBIT_TEXT_UTF8 or FMTBIT_IMAGE_PNG;
     CapFlags: CAP_BIDIR or CAP_IMAGES),

    { LINUX_X11 }
    (Name: 'LINUX_X11';
     OSType: OS_LINUX_X11;
     TextLocalFormat: FMT_TEXT_UTF8;
     TextNetFormat: FMT_TEXT_UTF8;
     ImageLocalFormat: FMT_IMAGE_PNG;
     ImageNetFormat: FMT_IMAGE_PNG;
     TextCodepage: 0;
     SupportsHTML: True;
     SupportsImages: True;
     SupportsBiDir: True;
     MaxPayloadKB: 16384;
     DedupWindowMs: 500;
     Formats: FMTBIT_TEXT_UTF8 or FMTBIT_IMAGE_PNG or FMTBIT_HTML_UTF8;
     CapFlags: CAP_BIDIR or CAP_IMAGES or CAP_HTML),

    { LINUX_WAYLAND_SESSION }
    (Name: 'LINUX_WAYLAND_SESSION';
     OSType: OS_LINUX_WAYLAND;
     TextLocalFormat: FMT_TEXT_UTF8;
     TextNetFormat: FMT_TEXT_UTF8;
     ImageLocalFormat: FMT_IMAGE_PNG;
     ImageNetFormat: FMT_IMAGE_PNG;
     TextCodepage: 0;
     SupportsHTML: True;
     SupportsImages: True;
     SupportsBiDir: True;
     MaxPayloadKB: 16384;
     DedupWindowMs: 500;
     Formats: FMTBIT_TEXT_UTF8 or FMTBIT_IMAGE_PNG or FMTBIT_HTML_UTF8;
     CapFlags: CAP_BIDIR or CAP_IMAGES or CAP_HTML),

    { WINDOWS_MODERN_UNICODE }
    (Name: 'WINDOWS_MODERN_UNICODE';
     OSType: OS_WIN_MODERN;
     TextLocalFormat: FMT_TEXT_UTF8;
     TextNetFormat: FMT_TEXT_UTF8;
     ImageLocalFormat: FMT_IMAGE_DIB;
     ImageNetFormat: FMT_IMAGE_PNG;
     TextCodepage: 0;
     SupportsHTML: True;
     SupportsImages: True;
     SupportsBiDir: True;
     MaxPayloadKB: 16384;
     DedupWindowMs: 500;
     Formats: FMTBIT_TEXT_UTF8 or FMTBIT_IMAGE_PNG or FMTBIT_HTML_UTF8;
     CapFlags: CAP_BIDIR or CAP_IMAGES or CAP_HTML)
  );

function GetProfile(const Name: AnsiString): TCompatProfile;
var i: Integer;
begin
  for i := 0 to High(KNOWN_PROFILES) do
    if SameText(KNOWN_PROFILES[i].Name, Name) then begin
      Result := KNOWN_PROFILES[i];
      Exit;
    end;
  { padrão genérico se não encontrado }
  Result := KNOWN_PROFILES[2];  { LINUX_X11 como base }
  Result.Name := Name;
end;

function GetProfileByOSType(OSType: Byte): TCompatProfile;
var i: Integer;
begin
  for i := 0 to High(KNOWN_PROFILES) do
    if KNOWN_PROFILES[i].OSType = OSType then begin
      Result := KNOWN_PROFILES[i];
      Exit;
    end;
  Result := KNOWN_PROFILES[2];  { fallback }
end;

function ProfileCount: Integer;
begin
  Result := Length(KNOWN_PROFILES);
end;

function ProfileByIndex(Idx: Integer): TCompatProfile;
begin
  if (Idx >= 0) and (Idx < Length(KNOWN_PROFILES)) then
    Result := KNOWN_PROFILES[Idx]
  else
    Result := KNOWN_PROFILES[0];
end;

procedure ApplyProfileOverrides(var P: TCompatProfile;
  const IniSection: AnsiString; const IniFile: AnsiString);
var Ini: TIniFile;
begin
  if not FileExists(IniFile) then Exit;
  Ini := TIniFile.Create(IniFile);
  try
    P.MaxPayloadKB  := Ini.ReadInteger(IniSection, 'max_payload_kb', P.MaxPayloadKB);
    P.DedupWindowMs := Ini.ReadInteger(IniSection, 'dedupe_window_ms', P.DedupWindowMs);
    P.TextCodepage  := Ini.ReadInteger(IniSection, 'text_codepage', P.TextCodepage);
    P.SupportsHTML  := Ini.ReadBool(IniSection, 'supports_html', P.SupportsHTML);
    P.SupportsImages:= Ini.ReadBool(IniSection, 'supports_images', P.SupportsImages);
    P.SupportsBiDir := Ini.ReadBool(IniSection, 'allow_bidirectional', P.SupportsBiDir);
  finally Ini.Free; end;
end;

end.
