{ image_convert.pas — Conversão de imagens via FPImage (BMP/DIB ↔ PNG)
  Esta unit usa FCL-Image (FPImage, FPReadPNG/FPWritePNG, FPReadBMP/FPWriteBMP).
  Requer que os diretórios de units do FPC/FCL sejam visíveis ao compilador
  (adicionar -Fu para o caminho `.../fcl-image` quando necessário). }

unit image_convert;

{$mode objfpc}{$H+}

interface

uses cbprotocol;

function DIBToPNG(const DIBData: TBytes; out PNGData: TBytes): Boolean;
function PNGToDIB(const PNGData: TBytes; out DIBData: TBytes): Boolean;
function BMPToPNG(const BMPData: TBytes; out PNGData: TBytes): Boolean;
function PNGToBMP(const PNGData: TBytes; out BMPData: TBytes): Boolean;

implementation

uses
  Classes, SysUtils,
  FPImage, FPReadBMP, FPWriteBMP, FPReadPNG, FPWritePNG;

const
  SIZEOF_BITMAPFILEHEADER = 14;
  SIZEOF_BITMAPINFOHEADER = 40;
  BI_BITFIELDS = 3;

type
  TBitmapFileHeader = packed record
    bfType      : Word;
    bfSize      : LongWord;
    bfReserved1 : Word;
    bfReserved2 : Word;
    bfOffBits   : LongWord;
  end;

  TBitmapInfoHeader = packed record
    biSize          : LongWord;
    biWidth         : LongInt;
    biHeight        : LongInt;
    biPlanes        : Word;
    biBitCount      : Word;
    biCompression   : LongWord;
    biSizeImage     : LongWord;
    biXPelsPerMeter : LongInt;
    biYPelsPerMeter : LongInt;
    biClrUsed       : LongWord;
    biClrImportant  : LongWord;
  end;

function ColorTableSize(const Hdr: TBitmapInfoHeader): Integer;
begin
  case Hdr.biBitCount of
    1:  Result := 2   * 4;
    4:  Result := 16  * 4;
    8:  Result := 256 * 4;
    16, 32: begin
      if Hdr.biCompression = BI_BITFIELDS then Result := 3 * 4
      else Result := 0;
    end;
  else
    Result := 0;
  end;
  if (Hdr.biClrUsed > 0) and (Hdr.biBitCount <= 8) then
    Result := Integer(Hdr.biClrUsed) * 4;
end;

function DIBToBMPBytes(const DIBData: cbprotocol.TBytes): cbprotocol.TBytes;
var
  Hdr: TBitmapFileHeader;
  InfoHdr: TBitmapInfoHeader;
  ColTabSz, OffBits, TotalSize: Integer;
begin
  SetLength(Result, 0);
  if Length(DIBData) < SIZEOF_BITMAPINFOHEADER then Exit;
  FillChar(InfoHdr, SizeOf(InfoHdr), 0);
  Move(DIBData[0], InfoHdr, SIZEOF_BITMAPINFOHEADER);
  ColTabSz  := ColorTableSize(InfoHdr);
  OffBits   := SIZEOF_BITMAPFILEHEADER + SIZEOF_BITMAPINFOHEADER + ColTabSz;
  TotalSize := SIZEOF_BITMAPFILEHEADER + Length(DIBData);
  FillChar(Hdr, SizeOf(Hdr), 0);
  Hdr.bfType    := $4D42; // 'BM'
  Hdr.bfSize    := LongWord(TotalSize);
  Hdr.bfOffBits := LongWord(OffBits);
  SetLength(Result, TotalSize);
  Move(Hdr, Result[0], SIZEOF_BITMAPFILEHEADER);
  if Length(DIBData) > 0 then
    Move(DIBData[0], Result[SIZEOF_BITMAPFILEHEADER], Length(DIBData));
end;

function ImageToPNGBytes(Img: TFPCustomImage): cbprotocol.TBytes;
var
  MS: TMemoryStream;
  Writer: TFPWriterPNG;
begin
  SetLength(Result, 0);
  if Img = nil then Exit;
  MS := TMemoryStream.Create;
  Writer := TFPWriterPNG.Create;
  try
    Writer.UseAlpha := False;
    Writer.ImageWrite(MS, Img);
    if MS.Size = 0 then Exit;
    SetLength(Result, MS.Size);
    MS.Position := 0;
    MS.Read(Result[0], MS.Size);
  finally
    Writer.Free;
    MS.Free;
  end;
end;

function PNGBytesToImage(const PNGData: cbprotocol.TBytes): TFPMemoryImage;
var
  MS: TMemoryStream;
  Reader: TFPReaderPNG;
begin
  Result := nil;
  if Length(PNGData) = 0 then Exit;
  MS := TMemoryStream.Create;
  Reader := TFPReaderPNG.Create;
  try
    MS.Write(PNGData[0], Length(PNGData));
    MS.Position := 0;
    Result := TFPMemoryImage.Create(0, 0);
    try
      Result.LoadFromStream(MS, Reader);
    except
      FreeAndNil(Result);
    end;
  finally
    Reader.Free;
    MS.Free;
  end;
end;

function BMPBytesToImage(const BMPData: cbprotocol.TBytes): TFPMemoryImage;
var
  MS: TMemoryStream;
  Reader: TFPReaderBMP;
begin
  Result := nil;
  if Length(BMPData) = 0 then Exit;
  MS := TMemoryStream.Create;
  Reader := TFPReaderBMP.Create;
  try
    MS.Write(BMPData[0], Length(BMPData));
    MS.Position := 0;
    Result := TFPMemoryImage.Create(0, 0);
    try
      Result.LoadFromStream(MS, Reader);
    except
      FreeAndNil(Result);
    end;
  finally
    Reader.Free;
    MS.Free;
  end;
end;

function ImageToBMPBytes(Img: TFPCustomImage): cbprotocol.TBytes;
var
  MS: TMemoryStream;
  Writer: TFPWriterBMP;
begin
  SetLength(Result, 0);
  if Img = nil then Exit;
  MS := TMemoryStream.Create;
  Writer := TFPWriterBMP.Create;
  try
    Writer.ImageWrite(MS, Img);
    if MS.Size = 0 then Exit;
    SetLength(Result, MS.Size);
    MS.Position := 0;
    MS.Read(Result[0], MS.Size);
  finally
    Writer.Free;
    MS.Free;
  end;
end;

function DIBToPNG(const DIBData: cbprotocol.TBytes; out PNGData: cbprotocol.TBytes): Boolean;
var
  BMPData: cbprotocol.TBytes;
  Img: TFPMemoryImage;
begin
  Result := False;
  SetLength(PNGData, 0);
  BMPData := DIBToBMPBytes(DIBData);
  if Length(BMPData) = 0 then Exit;
  Img := BMPBytesToImage(BMPData);
  if Img = nil then Exit;
  try
    PNGData := ImageToPNGBytes(Img);
    Result := Length(PNGData) > 0;
  finally
    Img.Free;
  end;
end;

function PNGToDIB(const PNGData: cbprotocol.TBytes; out DIBData: cbprotocol.TBytes): Boolean;
var
  Img: TFPMemoryImage;
  BMPData: cbprotocol.TBytes;
begin
  Result := False;
  SetLength(DIBData, 0);
  Img := PNGBytesToImage(PNGData);
  if Img = nil then Exit;
  try
    BMPData := ImageToBMPBytes(Img);
    if Length(BMPData) <= SIZEOF_BITMAPFILEHEADER then Exit;
    SetLength(DIBData, Length(BMPData) - SIZEOF_BITMAPFILEHEADER);
    Move(BMPData[SIZEOF_BITMAPFILEHEADER], DIBData[0], Length(DIBData));
    Result := True;
  finally
    Img.Free;
  end;
end;

function BMPToPNG(const BMPData: cbprotocol.TBytes; out PNGData: cbprotocol.TBytes): Boolean;
var Img: TFPMemoryImage;
begin
  Result := False;
  SetLength(PNGData, 0);
  Img := BMPBytesToImage(BMPData);
  if Img = nil then Exit;
  try
    PNGData := ImageToPNGBytes(Img);
    Result := Length(PNGData) > 0;
  finally Img.Free; end;
end;

function PNGToBMP(const PNGData: cbprotocol.TBytes; out BMPData: cbprotocol.TBytes): Boolean;
var Img: TFPMemoryImage;
begin
  Result := False;
  SetLength(BMPData, 0);
  Img := PNGBytesToImage(PNGData);
  if Img = nil then Exit;
  try
    BMPData := ImageToBMPBytes(Img);
    Result := Length(BMPData) > 0;
  finally Img.Free; end;
end;

end.
