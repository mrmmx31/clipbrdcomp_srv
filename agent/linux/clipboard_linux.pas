{ clipboard_linux.pas — Acesso ao clipboard no Linux via Lazarus TClipboard
  Suporte primário: X11 (via Lazarus, widgetset GTK2/Qt/etc.)
  Interface abstrata preparada para futura extensão a Wayland nativo. }

unit clipboard_linux;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes,
  Graphics, Clipbrd, LCLIntf, LCLType,
  FPImage, FPReadPNG, FPWritePNG,
  cbprotocol, cbhash, image_convert;

type
  TClipboardChangeCallback = procedure(FormatType: Byte;
    const Content: TBytes; const Hash: TClipHash) of object;

  TLinuxClipboard = class
  private
    FLastTextHash  : TClipHash;
    FLastImageHash : TClipHash;
    FSuppressUntil : Int64;      { timestamp ms para suprimir republicação }
    FSuppressHash  : TClipHash;  { hash sendo suprimido }
    FDedupMs       : Integer;

    function GetCurrentTimeMs: Int64;
    function ClipboardHasImage: Boolean;
    function GetClipboardPNG(out PNGData: TBytes): Boolean;
    function GetClipboardText(out Text: string): Boolean;
  public
    constructor Create(DedupWindowMs: Integer);

    { Poll: verifica mudanças e retorna True se clipboard mudou }
    function PollText(out Content: TBytes; out Hash: TClipHash): Boolean;
    function PollImage(out Content: TBytes; out Hash: TClipHash): Boolean;

    { Aplica conteúdo recebido da rede ao clipboard local }
    function ApplyText(const Content: TBytes): Boolean;
    function ApplyImage(const PNGData: TBytes): Boolean;

    { Anti-loop: registra hash que acabou de ser aplicado remotamente }
    procedure RecordApplied(const Hash: TClipHash);

    { Verifica se este hash deve ser suprimido (anti-loop) }
    function IsSuppressed(const Hash: TClipHash): Boolean;
  end;

implementation

uses DateUtils;

constructor TLinuxClipboard.Create(DedupWindowMs: Integer);
begin
  inherited Create;
  FDedupMs := DedupWindowMs;
  FSuppressUntil := 0;
  FLastTextHash  := ZeroHash;
  FLastImageHash := ZeroHash;
  FSuppressHash  := ZeroHash;
end;

function TLinuxClipboard.GetCurrentTimeMs: Int64;
begin
  Result := DateTimeToUnix(Now) * 1000;
  { Para melhor precisão, usar gettimeofday se disponível }
end;

function TLinuxClipboard.ClipboardHasImage: Boolean;
begin
  try
    Result := Clipboard.HasFormat(PredefinedClipboardFormat(pcfBitmap));
  except
    Result := False;
  end;
end;

function TLinuxClipboard.GetClipboardText(out Text: string): Boolean;
begin
  Result := False;
  try
    if Clipboard.HasFormat(PredefinedClipboardFormat(pcfText)) then begin
      Text := Clipboard.AsText;
      WriteLn('[Clipboard] GetClipboardText: HasFormat=true len=', IntToStr(Length(Text)));
      Result := True;
    end else begin
      WriteLn('[Clipboard] GetClipboardText: HasFormat=false; attempting AsText fallback');
      { Fallback: some widgetsets may not report HasFormat correctly — try reading AsText anyway }
      Text := Clipboard.AsText;
      WriteLn('[Clipboard] GetClipboardText: Fallback AsText len=', IntToStr(Length(Text)));
      Result := True;
    end;
  except
    WriteLn('[Clipboard] GetClipboardText: exception');
    Result := False;
  end;
end;

function TLinuxClipboard.GetClipboardPNG(out PNGData: TBytes): Boolean;
var
  Bmp    : TBitmap;
  MS     : TMemoryStream;
  Writer : TFPWriterPNG;
  Img    : TFPMemoryImage;
  x, y   : Integer;
  Color  : TFPColor;
  PixVal : TColor;
begin
  Result := False;
  SetLength(PNGData, 0);
  { Alguns widgetsets não reportam corretamente HasFormat para imagens.
    Tenta extrair a imagem independentemente do HasFormat — se o bitmap
    resultante for vazio, aborta. }

  Bmp := TBitmap.Create;
  MS  := TMemoryStream.Create;
  Writer := TFPWriterPNG.Create;
  try
    try
      { Tenta popular Bmp diretamente do clipboard mesmo que HasFormat falhe }
      Clipboard.Assign(Bmp);
      if (Bmp.Width = 0) or (Bmp.Height = 0) then Exit;

      { Converte TBitmap → TFPMemoryImage → PNG }
      Img := TFPMemoryImage.Create(Bmp.Width, Bmp.Height);
      try
        for y := 0 to Bmp.Height - 1 do
          for x := 0 to Bmp.Width - 1 do begin
            PixVal := Bmp.Canvas.Pixels[x, y];
            Color.Red   := (PixVal and $FF) shl 8;
            Color.Green := ((PixVal shr 8) and $FF) shl 8;
            Color.Blue  := ((PixVal shr 16) and $FF) shl 8;
            Color.Alpha := $FFFF;
            Img.Colors[x, y] := Color;
          end;
        Writer.UseAlpha  := False;
        Writer.WordSized := False;
        Writer.ImageWrite(MS, Img);
        SetLength(PNGData, MS.Size);
        if MS.Size > 0 then begin
          MS.Position := 0;
          MS.Read(PNGData[0], MS.Size);
          Result := True;
        end;
      finally Img.Free; end;
    except
      Result := False;
    end;
  finally
    Writer.Free;
    MS.Free;
    Bmp.Free;
  end;
end;

function TLinuxClipboard.PollText(out Content: TBytes; out Hash: TClipHash): Boolean;
var Text: string; NewHash: TClipHash;
begin
  Result := False;
  SetLength(Content, 0);
  if not GetClipboardText(Text) then Exit;
  if Text = '' then Exit;

  { Converte para bytes UTF-8 }
  SetLength(Content, Length(Text));
  if Length(Text) > 0 then
    Move(Text[1], Content[0], Length(Text));

  NewHash := HashBuffer(@Content[0], Length(Content));
  Hash := NewHash;

  { Mudou em relação ao último conhecido? }
  if HashEqual(NewHash, FLastTextHash) then Exit;

  { Debug: log novo hash detectado e tamanho (não imprime conteúdo) }
  WriteLn('[Clipboard] PollText detected new hash=', HashToHex(NewHash), ' len=', IntToStr(Length(Content)));

  FLastTextHash := NewHash;
  Result := True;
end;

function TLinuxClipboard.PollImage(out Content: TBytes; out Hash: TClipHash): Boolean;
var NewHash: TClipHash;
begin
  Result := False;
  SetLength(Content, 0);
  if not GetClipboardPNG(Content) then Exit;
  if Length(Content) = 0 then Exit;

  NewHash := HashBuffer(@Content[0], Length(Content));
  Hash := NewHash;

  if HashEqual(NewHash, FLastImageHash) then Exit;

  { Debug: log novo hash de imagem detectado }
  WriteLn('[Clipboard] PollImage detected new hash=', HashToHex(NewHash), ' len=', IntToStr(Length(Content)));

  FLastImageHash := NewHash;
  Result := True;
end;

function TLinuxClipboard.ApplyText(const Content: TBytes): Boolean;
var Text: string;
begin
  Result := False;
  if Length(Content) = 0 then Exit;
  try
    SetLength(Text, Length(Content));
    Move(Content[0], Text[1], Length(Content));
    Clipboard.AsText := Text;
    { Atualiza hash interno para não republicar }
    FLastTextHash := HashBuffer(@Content[0], Length(Content));
    Result := True;
  except
    Result := False;
  end;
end;

function TLinuxClipboard.ApplyImage(const PNGData: TBytes): Boolean;
var
  Bmp    : TBitmap;
  Img    : TFPMemoryImage;
  MS     : TMemoryStream;
  Reader : TFPReaderPNG;
  x, y   : Integer;
  Color  : TFPColor;
begin
  Result := False;
  if Length(PNGData) = 0 then Exit;
  MS     := TMemoryStream.Create;
  Reader := TFPReaderPNG.Create;
  Bmp    := TBitmap.Create;
  Img    := TFPMemoryImage.Create(0, 0);
  try
    try
      MS.Write(PNGData[0], Length(PNGData));
      MS.Position := 0;
      Img.LoadFromStream(MS, Reader);
      Bmp.Width  := Img.Width;
      Bmp.Height := Img.Height;
      for y := 0 to Img.Height - 1 do
        for x := 0 to Img.Width - 1 do begin
          Color := Img.Colors[x, y];
          Bmp.Canvas.Pixels[x, y] :=
            (Color.Red shr 8) or
            ((Color.Green shr 8) shl 8) or
            ((Color.Blue shr 8) shl 16);
        end;
      Clipboard.Assign(Bmp);
      FLastImageHash := HashBuffer(@PNGData[0], Length(PNGData));
      Result := True;
    except
      Result := False;
    end;
  finally
    Img.Free;
    Reader.Free;
    MS.Free;
    Bmp.Free;
  end;
end;

procedure TLinuxClipboard.RecordApplied(const Hash: TClipHash);
begin
  FSuppressHash  := Hash;
  FSuppressUntil := GetCurrentTimeMs + FDedupMs;
end;

function TLinuxClipboard.IsSuppressed(const Hash: TClipHash): Boolean;
begin
  Result := False;
  if GetCurrentTimeMs < FSuppressUntil then
    if HashEqual(Hash, FSuppressHash) then
      Result := True;
end;

end.
