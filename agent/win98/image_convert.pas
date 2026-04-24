{ image_convert.pas — Stubs para Win32 / FPC 2.6.4
  FPImage tem incompatibilidades de API entre FPC 2.6.x e 3.x.
  Sincronização de imagens desabilitada no agente Win98; texto funciona normalmente.
  Este arquivo tem precedência sobre compat/image_convert.pas quando compilado
  a partir do diretório win98 (FPC busca units no diretório do arquivo importador). }

unit image_convert;

{$mode objfpc}{$H+}

interface

uses cbprotocol;

function DIBToPNG(const DIBData: TBytes; out PNGData: TBytes): Boolean;
function PNGToDIB(const PNGData: TBytes; out DIBData: TBytes): Boolean;
function BMPToPNG(const BMPData: TBytes; out PNGData: TBytes): Boolean;
function PNGToBMP(const PNGData: TBytes; out BMPData: TBytes): Boolean;

implementation

{$WARN 5024 OFF}

function DIBToPNG(const DIBData: TBytes; out PNGData: TBytes): Boolean;
begin
  Result := False;
  SetLength(PNGData, 0);
end;

function PNGToDIB(const PNGData: TBytes; out DIBData: TBytes): Boolean;
begin
  Result := False;
  SetLength(DIBData, 0);
end;

function BMPToPNG(const BMPData: TBytes; out PNGData: TBytes): Boolean;
begin
  Result := False;
  SetLength(PNGData, 0);
end;

function PNGToBMP(const PNGData: TBytes; out BMPData: TBytes): Boolean;
begin
  Result := False;
  SetLength(BMPData, 0);
end;

end.
