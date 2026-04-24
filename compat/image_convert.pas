{ image_convert.pas — Stubs para ambientes onde FPImage não funciona }

unit image_convert;

{$mode objfpc}{$H+}

interface

uses cbprotocol;

function DIBToPNG(const DIBData: TBytes; out PNGData: TBytes): Boolean;
function PNGToDIB(const PNGData: TBytes; out DIBData: TBytes): Boolean;
function BMPToPNG(const BMPData: TBytes; out PNGData: TBytes): Boolean;
function PNGToBMP(const PNGData: TBytes; out BMPData: TBytes): Boolean;

implementation

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
