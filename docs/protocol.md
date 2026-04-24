# ClipBrdComp — Etapa B: Especificação Formal do Protocolo

## Versão do Protocolo: 1 (0x01)
## Porta padrão TCP: 6543

---

## 1. Framing (Estrutura do Frame)

Cada mensagem na rede é um **frame completo** com a seguinte estrutura:

```
┌────────────────────────────────────────────────────────────────────┐
│                         FRAME CBSYNC v1                            │
├──────────┬─────┬──────────┬───────┬────────────┬─────┬────────────┤
│ MAGIC    │ VER │ MSG_TYPE │ FLAGS │ RESERVED   │ ... │ ...        │
│ 2 bytes  │1B   │ 1 byte   │ 1 byte│ 3 bytes    │     │            │
├──────────┴─────┴──────────┴───────┴────────────┴─────┴────────────┤
│                     NODE_ID (16 bytes, UUID binary)                │
├────────────────────────────────────────────────────────────────────┤
│  SEQ_NUM (4 bytes, uint32 big-endian)                              │
├────────────────────────────────────────────────────────────────────┤
│  TIMESTAMP (4 bytes, uint32 big-endian, Unix seconds)              │
├────────────────────────────────────────────────────────────────────┤
│  PAYLOAD_LEN (4 bytes, uint32 big-endian)                          │
├────────────────────────────────────────────────────────────────────┤
│  PAYLOAD (PAYLOAD_LEN bytes)                                       │
├────────────────────────────────────────────────────────────────────┤
│  CRC32 (4 bytes, uint32 big-endian, IEEE 802.3 polynomial)         │
│  [cobre header + payload inteiros]                                 │
└────────────────────────────────────────────────────────────────────┘

Total overhead fixo: 36 (header) + 4 (CRC32) = 40 bytes
```

### 1.1 Detalhamento do Header (36 bytes, packed)

| Offset | Tamanho | Campo        | Descrição                                           |
|--------|---------|--------------|-----------------------------------------------------|
| 0      | 2       | MAGIC        | `0x43 0x42` (ASCII 'CB')                            |
| 2      | 1       | VERSION      | `0x01`                                              |
| 3      | 1       | MSG_TYPE     | Tipo da mensagem (ver tabela abaixo)                |
| 4      | 1       | FLAGS        | Bitmask de flags                                    |
| 5      | 3       | RESERVED     | Zeros (padding para alinhamento de 4 bytes)         |
| 8      | 16      | NODE_ID      | UUID do nó remetente (16 bytes binários)            |
| 24     | 4       | SEQ_NUM      | Número de sequência monotônico do nó (big-endian)   |
| 28     | 4       | TIMESTAMP    | Unix timestamp em segundos (big-endian)             |
| 32     | 4       | PAYLOAD_LEN  | Tamanho do payload em bytes (big-endian)            |

### 1.2 FLAGS

| Bit | Nome        | Descrição                                    |
|-----|-------------|----------------------------------------------|
| 0   | COMPRESSED  | Payload comprimido com zlib/deflate          |
| 1   | ENCRYPTED   | Payload cifrado (reservado para v2)          |
| 2   | RESP_REQ    | Resposta esperada                            |
| 3-7 | —           | Reservados, devem ser 0                      |

### 1.3 NODE_ID

UUID v4 (16 bytes, formato RFC 4122), gerado na primeira execução e persistido no `agent.ini`. Transportado como bytes raw (não como string hexadecimal).

Quando usado pelo **broker**, o NODE_ID no header é o UUID do broker (`00000000-0000-0000-0000-000000000000` indica sistema, qualquer outro é o UUID registrado do broker).

### 1.4 CRC32

CRC32 com polinômio IEEE 802.3 (0xEDB88320, forma refletida). Cobre **todos os 36 bytes do header** + **todos os bytes do payload**. Ausente quando PAYLOAD_LEN = 0 (frames de controle sem payload ainda têm CRC32 cobrindo apenas o header de 36 bytes, ou seja, CRC32 é **sempre presente**).

### 1.5 Exemplo de frame PING (payload vazio)

```
Hex: 43 42 01 20 00 00 00 00
     [M][M][V][T][F][R][R][R]
     XX XX XX XX XX XX XX XX XX XX XX XX XX XX XX XX  <- NODE_ID (16 bytes)
     00 00 00 01                                      <- SEQ_NUM = 1
     67 80 AB CD                                      <- TIMESTAMP
     00 00 00 00                                      <- PAYLOAD_LEN = 0
     YY YY YY YY                                      <- CRC32
```
Total: 40 bytes.

---

## 2. Tipos de Mensagem

| Código  | Nome              | Direção         | Descrição                              |
|---------|-------------------|-----------------|----------------------------------------|
| `0x01`  | HELLO             | Agente → Broker | Inicia conexão, identifica versão e OS |
| `0x02`  | HELLO_ACK         | Broker → Agente | Confirma aceite ou rejeição            |
| `0x03`  | AUTH              | Agente → Broker | Envia token de autenticação            |
| `0x04`  | AUTH_ACK          | Broker → Agente | Resultado da autenticação              |
| `0x05`  | ANNOUNCE          | Agente → Broker | Declara capacidades do nó              |
| `0x06`  | ANNOUNCE_ACK      | Broker → Agente | Confirma registro                      |
| `0x10`  | CLIP_PUBLISH      | Agente → Broker | Publica item de clipboard              |
| `0x11`  | CLIP_PUSH         | Broker → Agente | Entrega item a nó subscrito            |
| `0x12`  | CLIP_ACK          | Agente → Broker | Confirma recebimento/aplicação         |
| `0x20`  | PING              | Qualquer        | Keepalive                              |
| `0x21`  | PONG              | Qualquer        | Resposta ao PING                       |
| `0x30`  | ERROR             | Qualquer        | Indica erro                            |
| `0x40`  | REQUEST_STATE     | Agente → Broker | Solicita estado atual do grupo         |
| `0x41`  | STATE_RESPONSE    | Broker → Agente | Responde com último item do grupo      |
| `0x50`  | SUBSCRIBE_GROUP   | Agente → Broker | Entra em grupo                         |
| `0x51`  | SUBSCRIBE_ACK     | Broker → Agente | Confirma inscrição no grupo            |
| `0x60`  | POLICY_UPDATE     | Broker → Agente | Atualiza política de compatibilidade   |
| `0xFF`  | GOODBYE           | Qualquer        | Encerra sessão limpamente              |

---

## 3. Formato dos Payloads

### 3.1 HELLO payload (Agente → Broker)

```
┌────────────────────────────────────────┐
│ CLIENT_VERSION  (4 bytes, uint32 BE)   │  Versão do agente (ex.: 0x00010000)
├────────────────────────────────────────┤
│ MIN_VERSION     (4 bytes, uint32 BE)   │  Versão mínima do protocolo aceita
├────────────────────────────────────────┤
│ OS_TYPE         (1 byte)               │  Constante OS_xxx
├────────────────────────────────────────┤
│ HOSTNAME_LEN    (1 byte, uint8)        │  Comprimento do hostname em bytes
├────────────────────────────────────────┤
│ HOSTNAME        (HOSTNAME_LEN bytes)   │  Hostname em ASCII, sem null terminator
└────────────────────────────────────────┘
Tamanho mínimo: 10 bytes + hostname
```

### 3.2 HELLO_ACK payload (Broker → Agente)

```
┌────────────────────────────────────────┐
│ STATUS          (1 byte)               │  0x00=ok, 0x01=versão incompatível
├────────────────────────────────────────┤
│ BROKER_VERSION  (4 bytes, uint32 BE)   │  Versão do broker
├────────────────────────────────────────┤
│ SERVER_TIME     (4 bytes, uint32 BE)   │  Unix timestamp atual do servidor
└────────────────────────────────────────┘
Tamanho: 9 bytes
```

### 3.3 AUTH payload (Agente → Broker)

```
┌────────────────────────────────────────┐
│ TOKEN_LEN       (1 byte, uint8)        │  Comprimento do token em bytes
├────────────────────────────────────────┤
│ TOKEN           (TOKEN_LEN bytes)      │  Token compartilhado (UTF-8)
└────────────────────────────────────────┘
Tamanho mínimo: 2 bytes
Nota: token nunca é transmitido em claro em modo seguro (v2 usará HMAC)
```

### 3.4 AUTH_ACK payload (Broker → Agente)

```
┌────────────────────────────────────────┐
│ STATUS          (1 byte)               │  0x00=ok, 0x01=token inválido
├────────────────────────────────────────┤
│ MSG_LEN         (1 byte, uint8)        │  Comprimento da mensagem de erro
├────────────────────────────────────────┤
│ MSG             (MSG_LEN bytes)        │  Mensagem de erro (ASCII)
└────────────────────────────────────────┘
```

### 3.5 ANNOUNCE payload (Agente → Broker)

```
┌────────────────────────────────────────┐
│ OS_TYPE         (1 byte)               │  Constante OS_xxx
├────────────────────────────────────────┤
│ PROFILE_LEN     (1 byte, uint8)        │  Comprimento do nome do perfil
├────────────────────────────────────────┤
│ PROFILE         (PROFILE_LEN bytes)    │  Nome do perfil (ASCII)
├────────────────────────────────────────┤
│ FORMATS         (4 bytes, uint32 BE)   │  Bitmask de formatos suportados
│                                        │  bit0=TEXT_UTF8, bit4=IMAGE_PNG
│                                        │  bit5=IMAGE_BMP, bit8=HTML_UTF8
├────────────────────────────────────────┤
│ MAX_PAYLOAD_KB  (2 bytes, uint16 BE)   │  Tamanho máximo de payload em KB
├────────────────────────────────────────┤
│ CAP_FLAGS       (1 byte)               │  bit0=compress, bit1=bidirecional
│                                        │  bit2=images, bit3=html
├────────────────────────────────────────┤
│ OSVER_LEN       (1 byte, uint8)        │  Comprimento da versão do OS
├────────────────────────────────────────┤
│ OSVER           (OSVER_LEN bytes)      │  Versão do OS (ASCII)
└────────────────────────────────────────┘
```

### 3.6 CLIP_PUBLISH payload (Agente → Broker) — **payload central**

```
┌────────────────────────────────────────┐
│ CLIP_ID         (16 bytes)             │  UUID do item de clipboard (novo por publicação)
├────────────────────────────────────────┤
│ GROUP_ID        (16 bytes)             │  UUID do grupo alvo (zeros = grupo padrão)
├────────────────────────────────────────┤
│ FORMAT_TYPE     (1 byte)               │  FMT_TEXT_UTF8=0x01, FMT_IMAGE_PNG=0x10, etc.
├────────────────────────────────────────┤
│ ORIG_OS_FORMAT  (1 byte)               │  Informativo: formato original no SO local
│                                        │  0x00=desconhecido, 0x01=CF_TEXT, 0x02=CF_DIB
│                                        │  0x03=X11_UTF8, 0x04=X11_BITMAP
├────────────────────────────────────────┤
│ ENCODING        (1 byte)               │  0x01=UTF8, 0x02=ANSI_1252, 0x03=binary
├────────────────────────────────────────┤
│ RESERVED        (1 byte)               │  0x00
├────────────────────────────────────────┤
│ HASH            (16 bytes)             │  MD5 do campo CONTENT
├────────────────────────────────────────┤
│ CONTENT_LEN     (4 bytes, uint32 BE)   │  Comprimento do conteúdo em bytes
├────────────────────────────────────────┤
│ CONTENT         (CONTENT_LEN bytes)    │  Conteúdo no formato canônico de rede
└────────────────────────────────────────┘
Tamanho mínimo: 40 bytes (sem conteúdo)
```

### 3.7 CLIP_PUSH payload (Broker → Agente)

```
┌────────────────────────────────────────┐
│ CLIP_ID         (16 bytes)             │  UUID do item (mesmo do PUBLISH original)
├────────────────────────────────────────┤
│ SOURCE_NODE_ID  (16 bytes)             │  UUID do nó que originou o item
├────────────────────────────────────────┤
│ GROUP_ID        (16 bytes)             │  UUID do grupo
├────────────────────────────────────────┤
│ FORMAT_TYPE     (1 byte)               │  Formato do conteúdo (sempre canônico)
├────────────────────────────────────────┤
│ ENCODING        (1 byte)               │  Encoding do conteúdo
├────────────────────────────────────────┤
│ RESERVED        (2 bytes)              │  Zeros
├────────────────────────────────────────┤
│ HASH            (16 bytes)             │  MD5 do CONTENT
├────────────────────────────────────────┤
│ CONTENT_LEN     (4 bytes, uint32 BE)   │  Comprimento do conteúdo
├────────────────────────────────────────┤
│ CONTENT         (CONTENT_LEN bytes)    │  Conteúdo no formato canônico de rede
└────────────────────────────────────────┘
Tamanho mínimo: 54 bytes
```

### 3.8 CLIP_ACK payload (Agente → Broker)

```
┌────────────────────────────────────────┐
│ CLIP_ID         (16 bytes)             │  UUID do item confirmado
├────────────────────────────────────────┤
│ STATUS          (1 byte)               │  0x00=ok/applied
│                                        │  0x01=format_unsupported
│                                        │  0x02=payload_too_large
│                                        │  0x03=apply_failed
│                                        │  0x04=deduplicated (já tinha)
└────────────────────────────────────────┘
Tamanho: 17 bytes
```

### 3.9 PING payload

Payload vazio (PAYLOAD_LEN = 0). O SEQ_NUM do header é usado para correlação com PONG.

### 3.10 PONG payload

```
┌────────────────────────────────────────┐
│ ORIG_SEQ        (4 bytes, uint32 BE)   │  SEQ_NUM do PING original
└────────────────────────────────────────┘
```

### 3.11 ERROR payload

```
┌────────────────────────────────────────┐
│ ERROR_CODE      (1 byte)               │  Ver tabela de códigos de erro
├────────────────────────────────────────┤
│ MSG_LEN         (1 byte, uint8)        │  Comprimento da mensagem
├────────────────────────────────────────┤
│ MSG             (MSG_LEN bytes)        │  Mensagem de erro (ASCII)
└────────────────────────────────────────┘
```

### 3.12 SUBSCRIBE_GROUP payload

```
┌────────────────────────────────────────┐
│ GROUP_ID        (16 bytes)             │  UUID do grupo (pode ser bem-conhecido)
├────────────────────────────────────────┤
│ MODE            (1 byte)               │  0=recv_only, 1=send_only, 2=bidirecional
└────────────────────────────────────────┘
```

### 3.13 GOODBYE payload

Payload vazio. Encerramento limpo; a outra parte deve fechar o socket após receber.

---

## 4. Constantes

### 4.1 OS Types

| Constante               | Valor  | Descrição                      |
|-------------------------|--------|--------------------------------|
| `OS_UNKNOWN`            | `0x00` | Desconhecido                   |
| `OS_LINUX_X11`          | `0x01` | Linux com X11                  |
| `OS_LINUX_WAYLAND`      | `0x02` | Linux com Wayland nativo       |
| `OS_WIN98`              | `0x10` | Windows 95/98/ME               |
| `OS_WINNT_ANSI`         | `0x11` | Windows NT 4.0 / 2000          |
| `OS_WIN_MODERN`         | `0x12` | Windows XP ou posterior        |
| `OS_MACOS`              | `0x20` | macOS / OS X                   |

### 4.2 Format Types (em trânsito — somente formatos canônicos são aceitos)

| Constante               | Valor  | Descrição                          |
|-------------------------|--------|------------------------------------|
| `FMT_TEXT_UTF8`         | `0x01` | Texto em UTF-8 (sem BOM)           |
| `FMT_TEXT_ANSI`         | `0x02` | Texto em ANSI (uso interno, nunca na rede) |
| `FMT_IMAGE_PNG`         | `0x10` | Imagem PNG                         |
| `FMT_IMAGE_BMP`         | `0x11` | BMP (uso interno, nunca na rede)   |
| `FMT_IMAGE_DIB`         | `0x12` | DIB Win32 (uso interno)            |
| `FMT_HTML_UTF8`         | `0x20` | HTML em UTF-8 (v1.1)               |

### 4.3 Error Codes

| Constante               | Valor  | Descrição                          |
|-------------------------|--------|------------------------------------|
| `ERR_NONE`              | `0x00` | Sem erro                           |
| `ERR_AUTH_FAILED`       | `0x01` | Autenticação falhou                |
| `ERR_UNKNOWN_NODE`      | `0x02` | Nó desconhecido                    |
| `ERR_FORMAT_UNSUP`      | `0x03` | Formato não suportado              |
| `ERR_PAYLOAD_TOO_BIG`   | `0x04` | Payload excede limite              |
| `ERR_GROUP_NOTFOUND`    | `0x05` | Grupo não encontrado               |
| `ERR_PROTOCOL`          | `0x06` | Erro de protocolo (frame inválido) |
| `ERR_SEQ_INVALID`       | `0x07` | Número de sequência inválido       |
| `ERR_NOT_AUTHENTICATED` | `0x08` | Operação requer autenticação       |
| `ERR_INTERNAL`          | `0xFF` | Erro interno do servidor           |

### 4.4 Grupos Bem-Conhecidos

| UUID                                     | Nome       | Descrição          |
|------------------------------------------|------------|--------------------|
| `00000000-0000-0000-0000-000000000001`   | `default`  | Grupo padrão       |
| `00000000-0000-0000-0000-000000000002`   | `admins`   | Grupo administrativo (futuro) |

---

## 5. Máquina de Estados da Sessão

```
[CLOSED]
   │ TCP connect
   ▼
[HELLO_WAIT]     ← aguarda MSG_HELLO (timeout: 10s)
   │ HELLO válido
   ▼
[AUTH_WAIT]      ← aguarda MSG_AUTH (timeout: 10s)
   │ AUTH ok
   ▼
[ANNOUNCE_WAIT]  ← aguarda MSG_ANNOUNCE (timeout: 10s)
   │ ANNOUNCE recebido
   ▼
[ACTIVE]         ← sessão plena; aceita CLIP_PUBLISH, PING, SUBSCRIBE, GOODBYE
   │ GOODBYE ou erro
   ▼
[CLOSED]

Em qualquer estado:
  - Timeout sem mensagem → MSG_PING; sem PONG em 30s → CLOSED
  - MSG_GOODBYE → CLOSED
  - Erro de socket → CLOSED
  - Frame com CRC inválido → MSG_ERROR (ERR_PROTOCOL) → CLOSED
```

---

## 6. Exemplos de Payload em Binário

### 6.1 Texto "Hello World" do Win98 para Linux

**Agente Win98 enviando (CLIP_PUBLISH, após converter ANSI→UTF-8):**

```
Payload hex (CLIP_PUBLISH):
CLIP_ID:       A1 B2 C3 D4 E5 F6 07 08 09 0A 0B 0C 0D 0E 0F 10
GROUP_ID:      00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 01  (default)
FORMAT_TYPE:   01   (FMT_TEXT_UTF8)
ORIG_OS_FMT:   01   (CF_TEXT)
ENCODING:      01   (UTF8)
RESERVED:      00
HASH(MD5):     E5 9A 54 86 5A CF E9 8E E6 1E 9E E2 7D 54 F3 A6
CONTENT_LEN:   00 00 00 0B   (11 bytes)
CONTENT:       48 65 6C 6C 6F 20 57 6F 72 6C 64  ("Hello World")
```

**Broker envia CLIP_PUSH ao agente Linux:**

```
Payload hex (CLIP_PUSH):
CLIP_ID:       A1 B2 C3 D4 E5 F6 07 08 09 0A 0B 0C 0D 0E 0F 10
SRC_NODE_ID:   [UUID do Win98, 16 bytes]
GROUP_ID:      00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 01
FORMAT_TYPE:   01   (FMT_TEXT_UTF8)
ENCODING:      01   (UTF8)
RESERVED:      00 00
HASH(MD5):     E5 9A 54 86 5A CF E9 8E E6 1E 9E E2 7D 54 F3 A6
CONTENT_LEN:   00 00 00 0B
CONTENT:       48 65 6C 6C 6F 20 57 6F 72 6C 64
```

**Agente Linux aplica:** `Clipboard.AsText := 'Hello World'` (UTF-8, direto).

### 6.2 Handshake completo (frames sequenciais)

```
Frame 1: HELLO (agente Win98 → broker)
  Header: CB 01 01 00 00 00 00 [NodeID 16B] [seq=1 4B] [ts 4B] [len=12 4B]
  Payload: [cli_ver 4B] [min_ver 4B] [os=0x10] [hostname_len=1] [W]
  CRC32: [4B]

Frame 2: HELLO_ACK (broker → agente Win98)
  Header: CB 01 02 00 00 00 00 [BrokerNodeID 16B] [seq=1] [ts] [len=9]
  Payload: [status=0x00] [broker_ver 4B] [server_time 4B]
  CRC32: [4B]

Frame 3: AUTH (agente → broker)
  Payload: [token_len=1B] [token bytes]

Frame 4: AUTH_ACK
  Payload: [0x00] [0x00]  (ok, no message)

Frame 5: ANNOUNCE
  Payload: [os=0x10] [profile_len] [WIN98_LEGACY] [formats 4B] [max_kb 2B] [cap_flags] [osver_len] [98SE]

Frame 6: ANNOUNCE_ACK
  Payload: [status=0x00]

Frame 7: SUBSCRIBE_GROUP
  Payload: [group_id default 16B] [mode=0x02]

Frame 8: SUBSCRIBE_ACK
  Payload: [status=0x00] [group_name_len] [default]

... (sessão ativa) ...

Frame N: PING
  Payload: (vazio, len=0)

Frame N+1: PONG
  Payload: [orig_seq 4B]
```

---

## 7. Política de Compatibilidade

### 7.1 Regras de roteamento por formato

O broker, ao receber um `CLIP_PUBLISH`, decide para quais nós enviar com base nas capacidades:

```pascal
// Pseudo-código do roteador
for each TargetNode in Group.Nodes do begin
  if TargetNode.NodeID = SourceNodeID then Continue;
  if FormatType = FMT_TEXT_UTF8 then begin
    if not (CAP_TEXT in TargetNode.Formats) then Continue;
    // Envia como FMT_TEXT_UTF8; o agente converte para seu encoding local
  end else if FormatType = FMT_IMAGE_PNG then begin
    if not (CAP_IMAGE in TargetNode.Formats) then Continue;
    if ContentLen > TargetNode.MaxPayloadKB * 1024 then Continue; // mudar para ERROR
  end;
  SendClipPush(TargetNode.Session, ClipItem);
end;
```

### 7.2 Tabela de conversão por perfil

| Perfil            | Recebe TEXT_UTF8 | Aplica como      | Recebe IMAGE_PNG | Aplica como |
|-------------------|------------------|------------------|------------------|-------------|
| WIN98_LEGACY      | Sim              | CF_TEXT (CP1252) | Sim (se <4MB)   | CF_DIB      |
| WINNT_ANSI        | Sim              | CF_TEXT + CF_UNICODETEXT | Sim     | CF_DIB      |
| LINUX_X11         | Sim              | X11 UTF-8 string | Sim             | X11 bitmap  |
| WINDOWS_MODERN    | Sim              | CF_UNICODETEXT   | Sim             | CF_PNG/DIB  |

### 7.3 Deduplicação no broker

O broker mantém um hash ring de tamanho configurável dos últimos hashes vistos por grupo. Antes de fazer push para cada nó:

```pascal
if GroupRecentHashes.Contains(ContentHash) then begin
  // Hash já foi distribuído recentemente — verificar se o nó específico
  // ainda não recebeu (pode ter entrado depois)
  if NodeHashLog.Contains(TargetNodeID, ContentHash) then
    Continue; // nó já recebeu este conteúdo
end;
```

---

## 8. Dimensionamento e Limites

| Parâmetro                | Padrão | Mínimo | Máximo   |
|--------------------------|--------|--------|----------|
| Tamanho máximo de payload| 4 MB   | 1 KB   | 64 MB    |
| Histórico de itens       | 50     | 0      | 1000     |
| Conexões simultâneas     | 100    | 1      | ilimitado|
| Janela de supressão      | 800 ms | 100 ms | 10000 ms |
| Intervalo de ping        | 30 s   | 5 s    | 300 s    |
| Timeout de ping          | 90 s   | 15 s   | 900 s    |
| Tamanho do token         | 8-255B | 4B     | 255B     |
| Tamanho do hostname      | 1-255B | 1B     | 255B     |

---

## 9. Notas de Implementação por Plataforma

### 9.1 FreePascal — byte order

```pascal
// cbprotocol.pas (usados em cbmessage.pas)
function HostToBE32(V: LongWord): LongWord; inline;
begin
  Result := ((V and $FF) shl 24) or (((V shr 8) and $FF) shl 16)
          or (((V shr 16) and $FF) shl 8) or ((V shr 24) and $FF);
end;
function BE32ToHost(V: LongWord): LongWord; inline;
begin
  Result := HostToBE32(V); // CRC32 por simetria
end;
```

### 9.2 Leitura bloqueante confiável (ReadExact)

Fundamental para parsear frames, pois `Read()`/`Recv()` podem retornar menos bytes:

```pascal
function ReadExact(S: TStream; var Buf; Len: Integer): Boolean;
var Bytes, Got: Integer; P: PByte;
begin
  Result := False; P := @Buf; Bytes := 0;
  while Bytes < Len do begin
    Got := S.Read(P[Bytes], Len - Bytes);
    if Got <= 0 then Exit;
    Inc(Bytes, Got);
  end;
  Result := True;
end;
```

### 9.3 Win98 — Winsock

```pascal
// Inicialização (uma vez no início do programa)
var WSAData: TWSAData;
WSAStartup(MAKEWORD(1, 1), WSAData);
// ... no final:
WSACleanup;
```

Usar `MAKEWORD(1, 1)` para compatibilidade máxima com Win95/98.

### 9.4 UUID no Win98

Win98 não tem `UuidCreate` de forma confiável sem dependência de RPC. Gerar com:
```pascal
// Semente: GetTickCount XOR (GetCurrentProcessId SHL 16) XOR random
// + loop de 16 bytes de RandInt, depois fixar bits version=4 e variant=RFC4122
```
O UUID resultante é armazenado em `agent_win98.ini` e reutilizado em todas as sessões.
