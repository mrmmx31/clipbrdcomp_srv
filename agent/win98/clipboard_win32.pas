{ clipboard_win32.pas — Acesso ao clipboard Win32 compatível com Windows 98
  Usa apenas Win32 API disponível em Win98/ME.
  Suporte: CF_TEXT (texto ANSI) e CF_DIB (imagem DIB).
  NOTA: CF_UNICODETEXT não é usado aqui para manter compatibilidade Win98. }

unit clipboard_win32;

{$mode objfpc}{$H+}

interface

uses Windows, cbprotocol, cbhash, text_convert, image_convert;

type
  TClipWin32 = class
  private
    FLastTextHash  : TClipHash;
    FLastImageHash : TClipHash;
    FSuppressUntil : DWORD;   { GetTickCount timestamp }
    FSuppressHash  : TClipHash;
    FDedupMs       : Integer;
    FCodepage      : Integer;

    function GetTickMs: DWORD;
  public
    constructor Create(Codepage, DedupWindowMs: Integer);

    { Lê texto do clipboard como UTF-8; retorna True se diferente do último }
    function ReadTextUTF8(out UTF8Content: TBytes; out Hash: TClipHash): Boolean;

    { Lê imagem do clipboard como PNG; retorna True se diferente do último }
    function ReadImagePNG(out PNGData: TBytes; out Hash: TClipHash): Boolean;

    { Aplica texto UTF-8 ao clipboard Win32 como CF_TEXT ANSI }
    function WriteTextUTF8(const UTF8Content: TBytes): Boolean;

    { Aplica imagem PNG ao clipboard Win32 como CF_DIB }
    function WriteImagePNG(const PNGData: TBytes): Boolean;

    { Anti-loop: janela de supressão }
    procedure RecordApplied(const Hash: TClipHash);
    function IsSuppressed(const Hash: TClipHash): Boolean;

    { Getters de último hash (para comparação no loop) }
    function GetLastTextHash: TClipHash;
    function GetLastImageHash: TClipHash;
  end;

implementation

function TClipWin32.GetTickMs: DWORD;
begin
  Result := GetTickCount;
end;

constructor TClipWin32.Create(Codepage, DedupWindowMs: Integer);
begin
  inherited Create;
  FCodepage    := Codepage;
  FDedupMs     := DedupWindowMs;
  FLastTextHash  := ZeroHash;
  FLastImageHash := ZeroHash;
  FSuppressHash  := ZeroHash;
  FSuppressUntil := 0;
end;

{ ── Leitura de texto ─────────────────────────────────────────────────────────── }

function TClipWin32.ReadTextUTF8(out UTF8Content: TBytes; out Hash: TClipHash): Boolean;
var
  Hdl    : HANDLE;
  Ptr    : PAnsiChar;
  AnsiS  : AnsiString;
  UTF8S  : AnsiString;
  NewHash: TClipHash;
begin
  Result := False;
  SetLength(UTF8Content, 0);

  if not OpenClipboard(0) then Exit;
  try
    if not IsClipboardFormatAvailable(CF_TEXT) then Exit;

    Hdl := GetClipboardData(CF_TEXT);
    if Hdl = 0 then Exit;

    Ptr := GlobalLock(Hdl);
    if Ptr = nil then Exit;
    try
      AnsiS := AnsiString(Ptr);
    finally
      GlobalUnlock(Hdl);
    end;
  finally
    CloseClipboard;
  end;

  if AnsiS = '' then Exit;

  { Converte ANSI (codepage local) para UTF-8 }
  UTF8S := AnsiCP1252ToUTF8(AnsiS);

  SetLength(UTF8Content, Length(UTF8S));
  if Length(UTF8S) > 0 then
    Move(UTF8S[1], UTF8Content[0], Length(UTF8S));

  NewHash := HashBuffer(@UTF8Content[0], Length(UTF8Content));
  Hash    := NewHash;

  if HashEqual(NewHash, FLastTextHash) then Exit;
  FLastTextHash := NewHash;
  Result := True;
end;

{ ── Leitura de imagem ────────────────────────────────────────────────────────── }

function TClipWin32.ReadImagePNG(out PNGData: TBytes; out Hash: TClipHash): Boolean;
var
  Hdl    : HANDLE;
  Ptr    : Pointer;
  Size   : DWORD;
  DIBData: TBytes;
  NewHash: TClipHash;
begin
  Result := False;
  SetLength(PNGData, 0);

  if not OpenClipboard(0) then Exit;
  try
    if not IsClipboardFormatAvailable(CF_DIB) then Exit;

    Hdl := GetClipboardData(CF_DIB);
    if Hdl = 0 then Exit;

    Ptr := GlobalLock(Hdl);
    if Ptr = nil then Exit;
    try
      Size := GlobalSize(Hdl);
      SetLength(DIBData, Size);
      if Size > 0 then Move(Ptr^, DIBData[0], Size);
    finally
      GlobalUnlock(Hdl);
    end;
  finally
    CloseClipboard;
  end;

  if Length(DIBData) = 0 then Exit;

  { Converte DIB para PNG }
  if not DIBToPNG(DIBData, PNGData) then Exit;
  if Length(PNGData) = 0 then Exit;

  NewHash := HashBuffer(@PNGData[0], Length(PNGData));
  Hash    := NewHash;

  if HashEqual(NewHash, FLastImageHash) then Exit;
  FLastImageHash := NewHash;
  Result := True;
end;

{ ── Escrita de texto ─────────────────────────────────────────────────────────── }

function TClipWin32.WriteTextUTF8(const UTF8Content: TBytes): Boolean;
var
  AnsiS : AnsiString;
  UTF8S : AnsiString;
  Hdl   : HANDLE;
  Ptr   : PAnsiChar;
  Len   : Integer;
begin
  Result := False;
  if Length(UTF8Content) = 0 then Exit;

  { UTF-8 bytes → AnsiString (para converter) }
  SetLength(UTF8S, Length(UTF8Content));
  Move(UTF8Content[0], UTF8S[1], Length(UTF8Content));

  { Converte UTF-8 → ANSI CP1252 }
  AnsiS := UTF8ToAnsiCP1252(UTF8S);
  Len   := Length(AnsiS) + 1;  { inclui null terminator }

  Hdl := GlobalAlloc(GMEM_MOVEABLE, Len);
  if Hdl = 0 then Exit;

  Ptr := GlobalLock(Hdl);
  if Ptr = nil then begin GlobalFree(Hdl); Exit; end;

  try
    if Length(AnsiS) > 0 then
      Move(AnsiS[1], Ptr^, Length(AnsiS));
    Ptr[Length(AnsiS)] := #0;
  finally
    GlobalUnlock(Hdl);
  end;

  if not OpenClipboard(0) then begin GlobalFree(Hdl); Exit; end;
  try
    EmptyClipboard;
    if SetClipboardData(CF_TEXT, Hdl) <> 0 then begin
      Result := True;
      { Atualiza hash para não republicar }
      FLastTextHash := HashBuffer(@UTF8Content[0], Length(UTF8Content));
    end;
  finally
    CloseClipboard;
  end;

  { Nota: após SetClipboardData bem-sucedido, o handle pertence ao sistema;
    não chamar GlobalFree nele. Se SetClipboardData falhou, o handle ainda é nosso. }
  if not Result then GlobalFree(Hdl);
end;

{ ── Escrita de imagem ────────────────────────────────────────────────────────── }

function TClipWin32.WriteImagePNG(const PNGData: TBytes): Boolean;
var
  DIBData: TBytes;
  Hdl    : HANDLE;
  Ptr    : Pointer;
begin
  Result := False;
  if Length(PNGData) = 0 then Exit;

  { Converte PNG → DIB }
  if not PNGToDIB(PNGData, DIBData) then Exit;
  if Length(DIBData) = 0 then Exit;

  Hdl := GlobalAlloc(GMEM_MOVEABLE, Length(DIBData));
  if Hdl = 0 then Exit;

  Ptr := GlobalLock(Hdl);
  if Ptr = nil then begin GlobalFree(Hdl); Exit; end;

  try
    Move(DIBData[0], Ptr^, Length(DIBData));
  finally
    GlobalUnlock(Hdl);
  end;

  if not OpenClipboard(0) then begin GlobalFree(Hdl); Exit; end;
  try
    EmptyClipboard;
    if SetClipboardData(CF_DIB, Hdl) <> 0 then begin
      Result := True;
      FLastImageHash := HashBuffer(@PNGData[0], Length(PNGData));
    end;
  finally
    CloseClipboard;
  end;

  if not Result then GlobalFree(Hdl);
end;

{ ── Anti-loop ────────────────────────────────────────────────────────────────── }

procedure TClipWin32.RecordApplied(const Hash: TClipHash);
begin
  FSuppressHash  := Hash;
  FSuppressUntil := GetTickMs + DWORD(FDedupMs);
end;

function TClipWin32.IsSuppressed(const Hash: TClipHash): Boolean;
begin
  Result := False;
  if GetTickMs < FSuppressUntil then
    if HashEqual(Hash, FSuppressHash) then
      Result := True;
end;

function TClipWin32.GetLastTextHash: TClipHash;
begin Result := FLastTextHash; end;

function TClipWin32.GetLastImageHash: TClipHash;
begin Result := FLastImageHash; end;

end.
