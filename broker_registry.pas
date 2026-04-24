{ broker_registry.pas — Registro em memória dos nós conectados
  Thread-safe via TCriticalSection.
  Mantém estado de sessão ativo e lista de grupos/nós. }

unit broker_registry;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, SyncObjs, DateUtils,
  cbprotocol, cbhash,
  broker_logger, broker_db;

type
  { Sessão ativa de um nó (ponteiro para o TClientSession, opaco aqui) }
  TSessionRef = Pointer;

  TActiveNode = record
    NodeIDHex    : string;
    Hostname     : string;
    OSType       : Byte;
    OSVersion    : string;
    Profile      : string;
    Formats      : LongWord;
    CapFlags     : Byte;
    MaxPayloadKB : Integer;
    SyncMode     : Byte;
    SessionRef   : TSessionRef;   { referência à TClientSession }
    ConnectedAt  : Int64;
    Groups       : TStringList;   { lista de group_id hex }
  end;
  PActiveNode = ^TActiveNode;

  TNodeRegistry = class
  private
    FLock    : TCriticalSection;
    FNodes   : TList;       { lista de PActiveNode }
    FDB      : TBrokerDB;
    FLogger  : TBrokerLogger;
    function FindNode(const NodeIDHex: string): PActiveNode;
  public
    constructor Create(ADB: TBrokerDB; ALogger: TBrokerLogger);
    destructor Destroy; override;

    { Registra nó conectado e retorna ponteiro para ele }
    function RegisterNode(
      const NodeIDHex, Hostname: string;
      OSType: Byte;
      const OSVersion, Profile: string;
      Formats: LongWord;
      CapFlags: Byte;
      MaxPayloadKB: Integer;
      SyncMode: Byte;
      Session: TSessionRef): PActiveNode;

    { Remove nó desconectado }
    procedure UnregisterNode(const NodeIDHex: string);

    { Consultas }
    function GetNode(const NodeIDHex: string): PActiveNode;
    function IsConnected(const NodeIDHex: string): Boolean;

    { Grupos }
    procedure AddNodeToGroup(const NodeIDHex, GroupIDHex: string; Mode: Integer = 2);
    procedure RemoveNodeFromGroup(const NodeIDHex, GroupIDHex: string);

    { Retorna lista de TSessionRef dos nós no grupo, exceto o nó remetente }
    { O caller deve liberar a TList retornada }
    function GetGroupSessions(const GroupIDHex: string;
      const ExcludeNodeIDHex: string): TList;

    { Retorna lista de (NodeIDHex, CapFlags, MaxPayloadKB) para filtragem }
    { O caller deve liberar a TList retornada (contém PActiveNode — não liberar os nodes) }
    function GetGroupNodes(const GroupIDHex: string;
      const ExcludeNodeIDHex: string): TList;

    { Debug }
    function ConnectedCount: Integer;
    procedure LogStatus;
  end;

implementation

constructor TNodeRegistry.Create(ADB: TBrokerDB; ALogger: TBrokerLogger);
begin
  inherited Create;
  FLock   := TCriticalSection.Create;
  FNodes  := TList.Create;
  FDB     := ADB;
  FLogger := ALogger;
end;

destructor TNodeRegistry.Destroy;
var i: Integer; N: PActiveNode;
begin
  FLock.Enter;
  try
    for i := 0 to FNodes.Count - 1 do begin
      N := PActiveNode(FNodes[i]);
      N^.Groups.Free;
      Dispose(N);
    end;
    FNodes.Clear;
  finally FLock.Leave; end;
  FNodes.Free;
  FLock.Free;
  inherited;
end;

function TNodeRegistry.FindNode(const NodeIDHex: string): PActiveNode;
var i: Integer; N: PActiveNode;
begin
  Result := nil;
  for i := 0 to FNodes.Count - 1 do begin
    N := PActiveNode(FNodes[i]);
    if N^.NodeIDHex = NodeIDHex then begin
      Result := N;
      Exit;
    end;
  end;
end;

function TNodeRegistry.RegisterNode(
  const NodeIDHex, Hostname: string;
  OSType: Byte;
  const OSVersion, Profile: string;
  Formats: LongWord;
  CapFlags: Byte;
  MaxPayloadKB: Integer;
  SyncMode: Byte;
  Session: TSessionRef): PActiveNode;
var N: PActiveNode; DBRec: TNodeRecord;
begin
  FLock.Enter;
  try
    { Remove registro anterior se houver (reconexão) }
    N := FindNode(NodeIDHex);
    if N <> nil then begin
      N^.Groups.Free;
      FNodes.Remove(N);
      Dispose(N);
    end;
    { Cria novo }
    New(N);
    N^.NodeIDHex    := NodeIDHex;
    N^.Hostname     := Hostname;
    N^.OSType       := OSType;
    N^.OSVersion    := OSVersion;
    N^.Profile      := Profile;
    N^.Formats      := Formats;
    N^.CapFlags     := CapFlags;
    N^.MaxPayloadKB := MaxPayloadKB;
    N^.SyncMode     := SyncMode;
    N^.SessionRef   := Session;
    N^.ConnectedAt  := DateTimeToUnix(Now);
    N^.Groups       := TStringList.Create;
    FNodes.Add(N);
    Result := N;
  finally FLock.Leave; end;

  { Persiste no DB (fora do lock para não bloquear) }
  if Assigned(FDB) then begin
    DBRec.NodeIDHex := NodeIDHex;
    DBRec.Hostname  := Hostname;
    DBRec.OSType    := OSType;
    DBRec.OSVersion := OSVersion;
    DBRec.Profile   := Profile;
    DBRec.Formats   := Formats;
    DBRec.CapFlags  := CapFlags;
    DBRec.MaxKB     := MaxPayloadKB;
    DBRec.SyncMode  := SyncMode;
    DBRec.Active    := True;
    DBRec.LastSeen  := DateTimeToUnix(Now);
    DBRec.CreatedAt := DateTimeToUnix(Now);
    FDB.UpsertNode(DBRec);
  end;

  if Assigned(FLogger) then
    FLogger.Info('Node registered: %s (%s) OS=%d Profile=%s',
      [NodeIDHex, Hostname, OSType, Profile]);
end;

procedure TNodeRegistry.UnregisterNode(const NodeIDHex: string);
var N: PActiveNode;
begin
  FLock.Enter;
  try
    N := FindNode(NodeIDHex);
    if N <> nil then begin
      N^.Groups.Free;
      FNodes.Remove(N);
      Dispose(N);
    end;
  finally FLock.Leave; end;

  if Assigned(FDB) then
    FDB.SetNodeActive(NodeIDHex, False);

  if Assigned(FLogger) then
    FLogger.Info('Node unregistered: %s', [NodeIDHex]);
end;

function TNodeRegistry.GetNode(const NodeIDHex: string): PActiveNode;
begin
  FLock.Enter;
  try
    Result := FindNode(NodeIDHex);
  finally FLock.Leave; end;
end;

function TNodeRegistry.IsConnected(const NodeIDHex: string): Boolean;
begin
  FLock.Enter;
  try
    Result := FindNode(NodeIDHex) <> nil;
  finally FLock.Leave; end;
end;

procedure TNodeRegistry.AddNodeToGroup(const NodeIDHex, GroupIDHex: string; Mode: Integer);
var N: PActiveNode;
begin
  FLock.Enter;
  try
    N := FindNode(NodeIDHex);
    if N <> nil then
      if N^.Groups.IndexOf(GroupIDHex) < 0 then
        N^.Groups.Add(GroupIDHex);
  finally FLock.Leave; end;

  if Assigned(FDB) then
    FDB.AddNodeToGroup(NodeIDHex, GroupIDHex, Mode);
end;

procedure TNodeRegistry.RemoveNodeFromGroup(const NodeIDHex, GroupIDHex: string);
var N: PActiveNode; Idx: Integer;
begin
  FLock.Enter;
  try
    N := FindNode(NodeIDHex);
    if N <> nil then begin
      Idx := N^.Groups.IndexOf(GroupIDHex);
      if Idx >= 0 then N^.Groups.Delete(Idx);
    end;
  finally FLock.Leave; end;
end;

function TNodeRegistry.GetGroupSessions(const GroupIDHex: string;
  const ExcludeNodeIDHex: string): TList;
var i: Integer; N: PActiveNode;
begin
  Result := TList.Create;
  FLock.Enter;
  try
    for i := 0 to FNodes.Count - 1 do begin
      N := PActiveNode(FNodes[i]);
      if N^.NodeIDHex = ExcludeNodeIDHex then Continue;
      if N^.Groups.IndexOf(GroupIDHex) >= 0 then
        Result.Add(N^.SessionRef);
    end;
  finally FLock.Leave; end;
end;

function TNodeRegistry.GetGroupNodes(const GroupIDHex: string;
  const ExcludeNodeIDHex: string): TList;
var i: Integer; N: PActiveNode;
begin
  Result := TList.Create;
  FLock.Enter;
  try
    for i := 0 to FNodes.Count - 1 do begin
      N := PActiveNode(FNodes[i]);
      if N^.NodeIDHex = ExcludeNodeIDHex then Continue;
      if N^.Groups.IndexOf(GroupIDHex) >= 0 then
        Result.Add(N);
    end;
  finally FLock.Leave; end;
end;

function TNodeRegistry.ConnectedCount: Integer;
begin
  FLock.Enter;
  try Result := FNodes.Count;
  finally FLock.Leave; end;
end;

procedure TNodeRegistry.LogStatus;
var i: Integer; N: PActiveNode;
begin
  if not Assigned(FLogger) then Exit;
  FLock.Enter;
  try
    FLogger.Info('Registry: %d node(s) connected', [FNodes.Count]);
    for i := 0 to FNodes.Count - 1 do begin
      N := PActiveNode(FNodes[i]);
      FLogger.Debug('  Node %s (%s) Groups=%d', [N^.NodeIDHex, N^.Hostname, N^.Groups.Count]);
    end;
  finally FLock.Leave; end;
end;

end.
