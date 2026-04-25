{ broker_db.pas — Persistência SQLite para o broker
  Usa a unit sqlite3 do FPC (pacote sqlite).
  Requer: libsqlite3-dev instalada no sistema de build (Linux). }

unit broker_db;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, DateUtils,
  sqlite3,
  cbprotocol,
  broker_logger;

const
  { SQLITE_TRANSIENT no Debian FPC 3.2.2 é Pointer(-1); precisamos de cast }
  CB_SQLITE_TRANSIENT : sqlite3_destructor_type = sqlite3_destructor_type(Pointer(-1));

type
  TNodeRecord = record
    NodeIDHex  : string;
    Hostname   : string;
    OSType     : Integer;
    OSVersion  : string;
    Profile    : string;
    Formats    : LongWord;
    CapFlags   : Integer;
    MaxKB      : Integer;
    SyncMode   : Integer;
    Active     : Boolean;
    LastSeen   : Int64;
    CreatedAt  : Int64;
  end;

  TGroupRecord = record
    GroupIDHex : string;
    GroupName  : string;
    SyncMode   : Integer;
    CreatedAt  : Int64;
  end;

  TClipHistoryRecord = record
    ClipIDHex      : string;
    SourceNodeIDHex: string;
    GroupIDHex     : string;
    FormatType     : Integer;
    HashHex        : string;
    CreatedAt      : Int64;
    Payload        : TBytes;
  end;

  TBrokerDB = class
  private
    FDB     : Psqlite3;
    FLogger : TBrokerLogger;
    function ExecSQL(const SQL: string): Boolean;
    function ExecSQLFmt(const Fmt: string; const Args: array of const): Boolean;
    procedure LogDBError(const Context: string);
  public
    constructor Create(const DBPath: string; ALogger: TBrokerLogger);
    destructor Destroy; override;

    { Inicializa schema (cria tabelas se não existirem) }
    procedure InitSchema;

    { Nós }
    function UpsertNode(const Rec: TNodeRecord): Boolean;
    function GetNode(const NodeIDHex: string; out Rec: TNodeRecord): Boolean;
    function UpdateNodeLastSeen(const NodeIDHex: string; TS: Int64): Boolean;
    function SetNodeActive(const NodeIDHex: string; Active: Boolean): Boolean;
    function GetAllNodes(out Nodes: array of TNodeRecord): Integer;

    { Grupos }
    function UpsertGroup(const Rec: TGroupRecord): Boolean;
    function GetGroup(const GroupIDHex: string; out Rec: TGroupRecord): Boolean;
    function GetGroupByName(const Name: string; out Rec: TGroupRecord): Boolean;

    { Relação nó ↔ grupo }
    function AddNodeToGroup(const NodeIDHex, GroupIDHex: string; Mode: Integer): Boolean;
    function RemoveNodeFromGroup(const NodeIDHex, GroupIDHex: string): Boolean;
    function GetGroupMembers(const GroupIDHex: string; out Members: TStringArray): Boolean;
    function GetNodeGroups(const NodeIDHex: string; out Groups: TStringArray): Boolean;

    { Histórico de clipboard }
    function InsertClipHistory(const Rec: TClipHistoryRecord): Boolean;
    function PruneHistory(const GroupIDHex: string; MaxItems: Integer): Boolean;
    function GetLastClipForGroup(const GroupIDHex: string; out Rec: TClipHistoryRecord): Boolean;
  end;

implementation

const
  SCHEMA_NODES = 'CREATE TABLE IF NOT EXISTS nodes (' +
    'node_id TEXT PRIMARY KEY,' +
    'hostname TEXT NOT NULL,' +
    'os_type INTEGER NOT NULL DEFAULT 0,' +
    'os_version TEXT,' +
    'profile TEXT NOT NULL,' +
    'formats INTEGER DEFAULT 0,' +
    'cap_flags INTEGER DEFAULT 0,' +
    'max_kb INTEGER DEFAULT 4096,' +
    'sync_mode INTEGER DEFAULT 2,' +
    'active INTEGER DEFAULT 1,' +
    'last_seen INTEGER,' +
    'created_at INTEGER' +
    ')';

  SCHEMA_GROUPS = 'CREATE TABLE IF NOT EXISTS groups (' +
    'group_id TEXT PRIMARY KEY,' +
    'group_name TEXT NOT NULL UNIQUE,' +
    'sync_mode INTEGER DEFAULT 2,' +
    'created_at INTEGER' +
    ')';

  SCHEMA_NODE_GROUPS = 'CREATE TABLE IF NOT EXISTS node_groups (' +
    'node_id TEXT NOT NULL,' +
    'group_id TEXT NOT NULL,' +
    'mode INTEGER DEFAULT 2,' +
    'PRIMARY KEY (node_id, group_id)' +
    ')';

  SCHEMA_HISTORY = 'CREATE TABLE IF NOT EXISTS clipboard_history (' +
    'clip_id TEXT PRIMARY KEY,' +
    'source_node_id TEXT NOT NULL,' +
    'group_id TEXT NOT NULL,' +
    'format_type INTEGER NOT NULL,' +
    'hash TEXT NOT NULL,' +
    'created_at INTEGER NOT NULL,' +
    'payload BLOB' +
    ')';

  SCHEMA_IDX_HISTORY = 'CREATE INDEX IF NOT EXISTS idx_history_group_ts ' +
    'ON clipboard_history(group_id, created_at DESC)';

{ ── Helpers internos ─────────────────────────────────────────────────────────── }

procedure TBrokerDB.LogDBError(const Context: string);
begin
  if Assigned(FLogger) then
    FLogger.Error('DB error [%s]: %s', [Context, string(sqlite3_errmsg(FDB))]);
end;

function TBrokerDB.ExecSQL(const SQL: string): Boolean;
var ErrMsg: PAnsiChar;
begin
  Result := sqlite3_exec(FDB, PAnsiChar(AnsiString(SQL)), nil, nil, @ErrMsg) = SQLITE_OK;
  if not Result then begin
    if Assigned(FLogger) then
      FLogger.Error('SQL exec error: %s | SQL: %s', [string(ErrMsg), SQL]);
    sqlite3_free(ErrMsg);
  end;
end;

function TBrokerDB.ExecSQLFmt(const Fmt: string; const Args: array of const): Boolean;
begin
  Result := ExecSQL(Format(Fmt, Args));
end;

{ ── Constructor / Destructor ─────────────────────────────────────────────────── }

constructor TBrokerDB.Create(const DBPath: string; ALogger: TBrokerLogger);
begin
  inherited Create;
  FLogger := ALogger;
  FDB := nil;
  { Abre em modo FULLMUTEX: a própria libsqlite3 serializa todos os acessos
    nesta conexão, tornando-a segura para uso compartilhado entre threads. }
  if sqlite3_open_v2(PAnsiChar(AnsiString(DBPath)), @FDB,
       SQLITE_OPEN_READWRITE or SQLITE_OPEN_CREATE or SQLITE_OPEN_FULLMUTEX,
       nil) <> SQLITE_OK then begin
    if Assigned(FLogger) then
      FLogger.Error('Cannot open database: %s', [DBPath]);
    raise Exception.CreateFmt('Cannot open SQLite DB: %s', [DBPath]);
  end;
  { Ativa WAL mode para melhor concorrência }
  ExecSQL('PRAGMA journal_mode=WAL');
  ExecSQL('PRAGMA foreign_keys=ON');
  { Aumenta timeout de busy para evitar SQLITE_BUSY quando threads concorrem }
  ExecSQL('PRAGMA busy_timeout=3000');
  InitSchema;
end;

destructor TBrokerDB.Destroy;
begin
  if FDB <> nil then sqlite3_close(FDB);
  inherited;
end;

procedure TBrokerDB.InitSchema;
begin
  ExecSQL(SCHEMA_NODES);
  ExecSQL(SCHEMA_GROUPS);
  ExecSQL(SCHEMA_NODE_GROUPS);
  ExecSQL(SCHEMA_HISTORY);
  ExecSQL(SCHEMA_IDX_HISTORY);
  { Garante grupo default }
  ExecSQL('INSERT OR IGNORE INTO groups(group_id, group_name, sync_mode, created_at) ' +
    'VALUES(''00000000000000000000000000000001'', ''default'', 2, ' +
    IntToStr(DateTimeToUnix(Now)) + ')');
end;

{ ── Nós ──────────────────────────────────────────────────────────────────────── }

function TBrokerDB.UpsertNode(const Rec: TNodeRecord): Boolean;
var SQL: string;
begin
  SQL := Format('INSERT OR REPLACE INTO nodes ' +
    '(node_id, hostname, os_type, os_version, profile, formats, cap_flags, ' +
    ' max_kb, sync_mode, active, last_seen, created_at) VALUES ' +
    '(''%s'', ''%s'', %d, ''%s'', ''%s'', %d, %d, %d, %d, %d, %d, %d)',
    [Rec.NodeIDHex, Rec.Hostname, Rec.OSType, Rec.OSVersion, Rec.Profile,
     Rec.Formats, Rec.CapFlags, Rec.MaxKB, Rec.SyncMode,
     Ord(Rec.Active), Rec.LastSeen, Rec.CreatedAt]);
  Result := ExecSQL(SQL);
end;

function TBrokerDB.GetNode(const NodeIDHex: string; out Rec: TNodeRecord): Boolean;
var Stmt: Psqlite3_stmt; RC: Integer;
begin
  Result := False;
  Initialize(Rec);
  FillChar(Rec, SizeOf(Rec), 0);
  if sqlite3_prepare_v2(FDB,
    PAnsiChar(AnsiString('SELECT node_id, hostname, os_type, os_version, profile, ' +
    'formats, cap_flags, max_kb, sync_mode, active, last_seen, created_at ' +
    'FROM nodes WHERE node_id=''' + NodeIDHex + '''')),
    -1, @Stmt, nil) <> SQLITE_OK then Exit;
  try
    RC := sqlite3_step(Stmt);
    if RC = SQLITE_ROW then begin
      Rec.NodeIDHex  := string(sqlite3_column_text(Stmt, 0));
      Rec.Hostname   := string(sqlite3_column_text(Stmt, 1));
      Rec.OSType     := sqlite3_column_int(Stmt, 2);
      Rec.OSVersion  := string(sqlite3_column_text(Stmt, 3));
      Rec.Profile    := string(sqlite3_column_text(Stmt, 4));
      Rec.Formats    := LongWord(sqlite3_column_int(Stmt, 5));
      Rec.CapFlags   := sqlite3_column_int(Stmt, 6);
      Rec.MaxKB      := sqlite3_column_int(Stmt, 7);
      Rec.SyncMode   := sqlite3_column_int(Stmt, 8);
      Rec.Active     := sqlite3_column_int(Stmt, 9) <> 0;
      Rec.LastSeen   := sqlite3_column_int64(Stmt, 10);
      Rec.CreatedAt  := sqlite3_column_int64(Stmt, 11);
      Result := True;
    end;
  finally sqlite3_finalize(Stmt); end;
end;

function TBrokerDB.UpdateNodeLastSeen(const NodeIDHex: string; TS: Int64): Boolean;
begin
  Result := ExecSQLFmt(
    'UPDATE nodes SET last_seen=%d, active=1 WHERE node_id=''%s''',
    [TS, NodeIDHex]);
end;

function TBrokerDB.SetNodeActive(const NodeIDHex: string; Active: Boolean): Boolean;
begin
  Result := ExecSQLFmt(
    'UPDATE nodes SET active=%d WHERE node_id=''%s''',
    [Ord(Active), NodeIDHex]);
end;

function TBrokerDB.GetAllNodes(out Nodes: array of TNodeRecord): Integer;
begin
  Result := 0;  { TODO: implementar com cursor se necessário }
end;

{ ── Grupos ───────────────────────────────────────────────────────────────────── }

function TBrokerDB.UpsertGroup(const Rec: TGroupRecord): Boolean;
begin
  Result := ExecSQLFmt(
    'INSERT OR REPLACE INTO groups(group_id, group_name, sync_mode, created_at) ' +
    'VALUES(''%s'', ''%s'', %d, %d)',
    [Rec.GroupIDHex, Rec.GroupName, Rec.SyncMode, Rec.CreatedAt]);
end;

function TBrokerDB.GetGroup(const GroupIDHex: string; out Rec: TGroupRecord): Boolean;
var Stmt: Psqlite3_stmt;
begin
  Result := False;
  Initialize(Rec);
  FillChar(Rec, SizeOf(Rec), 0);
  if sqlite3_prepare_v2(FDB,
    PAnsiChar(AnsiString('SELECT group_id, group_name, sync_mode, created_at ' +
    'FROM groups WHERE group_id=''' + GroupIDHex + '''')),
    -1, @Stmt, nil) <> SQLITE_OK then Exit;
  try
    if sqlite3_step(Stmt) = SQLITE_ROW then begin
      Rec.GroupIDHex := string(sqlite3_column_text(Stmt, 0));
      Rec.GroupName  := string(sqlite3_column_text(Stmt, 1));
      Rec.SyncMode   := sqlite3_column_int(Stmt, 2);
      Rec.CreatedAt  := sqlite3_column_int64(Stmt, 3);
      Result := True;
    end;
  finally sqlite3_finalize(Stmt); end;
end;

function TBrokerDB.GetGroupByName(const Name: string; out Rec: TGroupRecord): Boolean;
var Stmt: Psqlite3_stmt;
begin
  Result := False;
  Initialize(Rec);
  FillChar(Rec, SizeOf(Rec), 0);
  if sqlite3_prepare_v2(FDB,
    PAnsiChar(AnsiString('SELECT group_id, group_name, sync_mode, created_at ' +
    'FROM groups WHERE group_name=''' + Name + '''')),
    -1, @Stmt, nil) <> SQLITE_OK then Exit;
  try
    if sqlite3_step(Stmt) = SQLITE_ROW then begin
      Rec.GroupIDHex := string(sqlite3_column_text(Stmt, 0));
      Rec.GroupName  := string(sqlite3_column_text(Stmt, 1));
      Rec.SyncMode   := sqlite3_column_int(Stmt, 2);
      Rec.CreatedAt  := sqlite3_column_int64(Stmt, 3);
      Result := True;
    end;
  finally sqlite3_finalize(Stmt); end;
end;

{ ── Relação nó ↔ grupo ────────────────────────────────────────────────────────── }

function TBrokerDB.AddNodeToGroup(const NodeIDHex, GroupIDHex: string; Mode: Integer): Boolean;
begin
  Result := ExecSQLFmt(
    'INSERT OR REPLACE INTO node_groups(node_id, group_id, mode) VALUES(''%s'', ''%s'', %d)',
    [NodeIDHex, GroupIDHex, Mode]);
end;

function TBrokerDB.RemoveNodeFromGroup(const NodeIDHex, GroupIDHex: string): Boolean;
begin
  Result := ExecSQLFmt(
    'DELETE FROM node_groups WHERE node_id=''%s'' AND group_id=''%s''',
    [NodeIDHex, GroupIDHex]);
end;

function TBrokerDB.GetGroupMembers(const GroupIDHex: string; out Members: TStringArray): Boolean;
var Stmt: Psqlite3_stmt; Count: Integer;
begin
  Result := False;
  Members := nil;
  Count := 0;
  if sqlite3_prepare_v2(FDB,
    PAnsiChar(AnsiString('SELECT node_id FROM node_groups WHERE group_id=''' + GroupIDHex + '''')),
    -1, @Stmt, nil) <> SQLITE_OK then Exit;
  try
    while sqlite3_step(Stmt) = SQLITE_ROW do begin
      SetLength(Members, Count + 1);
      Members[Count] := string(sqlite3_column_text(Stmt, 0));
      Inc(Count);
    end;
    Result := True;
  finally sqlite3_finalize(Stmt); end;
end;

function TBrokerDB.GetNodeGroups(const NodeIDHex: string; out Groups: TStringArray): Boolean;
var Stmt: Psqlite3_stmt; Count: Integer;
begin
  Result := False;
  Groups := nil;
  Count := 0;
  if sqlite3_prepare_v2(FDB,
    PAnsiChar(AnsiString('SELECT group_id FROM node_groups WHERE node_id=''' + NodeIDHex + '''')),
    -1, @Stmt, nil) <> SQLITE_OK then Exit;
  try
    while sqlite3_step(Stmt) = SQLITE_ROW do begin
      SetLength(Groups, Count + 1);
      Groups[Count] := string(sqlite3_column_text(Stmt, 0));
      Inc(Count);
    end;
    Result := True;
  finally sqlite3_finalize(Stmt); end;
end;

{ ── Histórico ────────────────────────────────────────────────────────────────── }

function TBrokerDB.InsertClipHistory(const Rec: TClipHistoryRecord): Boolean;
var Stmt: Psqlite3_stmt; SQL: AnsiString;
begin
  Result := False;
  SQL := 'INSERT OR REPLACE INTO clipboard_history' +
    '(clip_id, source_node_id, group_id, format_type, hash, created_at, payload) ' +
    'VALUES(?, ?, ?, ?, ?, ?, ?)';
  if sqlite3_prepare_v2(FDB, PAnsiChar(SQL), -1, @Stmt, nil) <> SQLITE_OK then Exit;
  try
    sqlite3_bind_text(Stmt, 1, PAnsiChar(AnsiString(Rec.ClipIDHex)),       -1, CB_SQLITE_TRANSIENT);
    sqlite3_bind_text(Stmt, 2, PAnsiChar(AnsiString(Rec.SourceNodeIDHex)), -1, CB_SQLITE_TRANSIENT);
    sqlite3_bind_text(Stmt, 3, PAnsiChar(AnsiString(Rec.GroupIDHex)),      -1, CB_SQLITE_TRANSIENT);
    sqlite3_bind_int (Stmt, 4, Rec.FormatType);
    sqlite3_bind_text(Stmt, 5, PAnsiChar(AnsiString(Rec.HashHex)),         -1, CB_SQLITE_TRANSIENT);
    sqlite3_bind_int64(Stmt, 6, Rec.CreatedAt);
    if Length(Rec.Payload) > 0 then
      sqlite3_bind_blob(Stmt, 7, @Rec.Payload[0], Length(Rec.Payload), CB_SQLITE_TRANSIENT)
    else
      sqlite3_bind_null(Stmt, 7);
    Result := sqlite3_step(Stmt) = SQLITE_DONE;
  finally sqlite3_finalize(Stmt); end;
end;

function TBrokerDB.PruneHistory(const GroupIDHex: string; MaxItems: Integer): Boolean;
begin
  Result := ExecSQLFmt(
    'DELETE FROM clipboard_history WHERE clip_id IN (' +
    '  SELECT clip_id FROM clipboard_history WHERE group_id=''%s'' ' +
    '  ORDER BY created_at DESC LIMIT -1 OFFSET %d)',
    [GroupIDHex, MaxItems]);
end;

function TBrokerDB.GetLastClipForGroup(const GroupIDHex: string;
  out Rec: TClipHistoryRecord): Boolean;
var Stmt: Psqlite3_stmt; BlobPtr: Pointer; BlobLen: Integer;
begin
  Result := False;
  Initialize(Rec);
  FillChar(Rec, SizeOf(Rec), 0);
  if sqlite3_prepare_v2(FDB,
    PAnsiChar(AnsiString('SELECT clip_id, source_node_id, group_id, format_type, hash, ' +
    'created_at, payload FROM clipboard_history WHERE group_id=''' + GroupIDHex +
    ''' ORDER BY created_at DESC LIMIT 1')),
    -1, @Stmt, nil) <> SQLITE_OK then Exit;
  try
    if sqlite3_step(Stmt) = SQLITE_ROW then begin
      Rec.ClipIDHex       := string(sqlite3_column_text(Stmt, 0));
      Rec.SourceNodeIDHex := string(sqlite3_column_text(Stmt, 1));
      Rec.GroupIDHex      := string(sqlite3_column_text(Stmt, 2));
      Rec.FormatType      := sqlite3_column_int(Stmt, 3);
      Rec.HashHex         := string(sqlite3_column_text(Stmt, 4));
      Rec.CreatedAt       := sqlite3_column_int64(Stmt, 5);
      BlobLen             := sqlite3_column_bytes(Stmt, 6);
      BlobPtr             := sqlite3_column_blob(Stmt, 6);
      SetLength(Rec.Payload, BlobLen);
      if BlobLen > 0 then Move(BlobPtr^, Rec.Payload[0], BlobLen);
      Result := True;
    end;
  finally sqlite3_finalize(Stmt); end;
end;

end.
