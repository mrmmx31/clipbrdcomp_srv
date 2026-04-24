# ClipBrdComp — Etapa A: Arquitetura Completa

## 1. Visão Geral do Sistema

ClipBrdComp é um sistema de sincronização de área de transferência em rede, projetado para operar entre máquinas heterogêneas — de Windows 98 a Linux moderno — usando um protocolo binário leve sobre TCP.

O sistema é dividido em três papéis fundamentais:

```
┌──────────────────────────────────────────────────────────────────────┐
│                        REDE LOCAL (LAN)                              │
│                                                                      │
│   ┌──────────────┐       TCP/6543       ┌──────────────────────┐    │
│   │  Linux Host  │◄────────────────────►│                      │    │
│   │  (Agente)    │                      │   BROKER CENTRAL     │    │
│   └──────────────┘                      │   (Linux, FPC)       │    │
│                                         │                      │    │
│   ┌──────────────┐       TCP/6543       │  - Registro de nós   │    │
│   │  Win98 Host  │◄────────────────────►│  - Grupos            │    │
│   │  (Agente)    │                      │  - Histórico         │    │
│   └──────────────┘                      │  - Roteamento        │    │
│                                         │  - Auditoria         │    │
│   ┌──────────────┐       TCP/6543       │                      │    │
│   │  Win Modern  │◄────────────────────►│                      │    │
│   │  (Agente)    │                      └──────────────────────┘    │
│   └──────────────┘                                                   │
└──────────────────────────────────────────────────────────────────────┘
```

---

## 2. Componentes Detalhados

### 2.1 Broker Central (`clipbrd_broker`)

**Linguagem:** FreePascal 3.2.x, sem Lazarus (console daemon).  
**Plataforma:** Linux (x86_64 ou i386).  
**Persistência:** SQLite3 via unit `sqlite3` do FPC.

Responsabilidades:
- Aceitar conexões TCP dos agentes (um thread por conexão).
- Autenticar nós via token compartilhado.
- Manter o **Registro de Nós** (capacidades, perfis, grupos, status).
- Rotear itens de clipboard de um nó publicador para todos os nós subscritores do mesmo grupo.
- Filtrar por capacidade: não enviar formato não suportado ao destino.
- Manter histórico opcional dos últimos N itens (configurável).
- Gravar logs com nível configurável.
- Ler configuração de `broker.ini`.

**Threads:**
- `TBrokerServer`: thread do acceptor (accept loop principal).
- `TClientSession` (um por conexão ativa): lê frames, despacha ao roteador.
- Todos os acessos ao estado compartilhado (registry, histórico) protegidos por `TCriticalSection`.

### 2.2 Agente Linux (`clipbrd_agent_linux`)

**Linguagem:** FreePascal / Lazarus (para acesso ao clipboard via `TClipboard`).  
**Plataforma:** Linux com X11 (preparado para Wayland via abstração).

**Arquitetura de processo (Linux):**

```
 ┌──────────────────────────────────────────────────┐
 │          clipbrd_agent_linux (processo único)     │
 │  ┌────────────────────┐  ┌──────────────────────┐ │
 │  │  TClipboardPoller  │  │  TNetClient (Thread) │ │
 │  │  (timer/poll)      │  │  Conexão com Broker  │ │
 │  │  TClipboard X11    │  │  Read/Write frames   │ │
 │  └────────┬───────────┘  └───────────┬──────────┘ │
 │           │    TAgentCore (coordena) │            │
 │           └────────────┬────────────┘            │
 │                        │                         │
 │              Anti-loop + dedup + conv            │
 └──────────────────────────────────────────────────┘
```

Justificativa para processo único: no Linux com X11, `TClipboard` exige conexão com o display. O processo do agente roda na sessão do usuário (não como serviço do sistema), o que é correto — clipboard é recurso de sessão. Para evitar o problema "clipboard some com o processo", usamos `xfixes` (futuro) ou mantemos o processo ativo.

Nota Wayland: `TClipboard` do Lazarus, com widgetset Qt5/GTK3, funciona em XWayland. Para Wayland nativo, a camada `clipboard_linux.pas` terá uma interface abstrata pronta para substituição.

### 2.3 Agente Windows 98 (`clipbrd_agent_w98`)

**Linguagem:** FreePascal para alvo `i386-win32`.  
**Compilado em:** Linux (cross-compile) ou diretamente em Win98 com FPC 2.6.x instalado.  
**Sem Lazarus:** usa apenas Win32 API pura (sem widgetsets).

**Arquitetura de processo (Win98):**

```
 ┌─────────────────────────────────────────────────────┐
 │            clipbrd_agent_w98.exe (processo único)    │
 │                                                      │
 │  Thread principal (GUI thread)                       │
 │  ┌─────────────────────────────────────────────────┐ │
 │  │  Win32 Message Loop                             │ │
 │  │  Hidden Window (HWND) ─── WM_DRAWCLIPBOARD      │ │
 │  │  Shell_NotifyIcon (tray)                        │ │
 │  │  WM_CHANGECBCHAIN (chain maintenance)           │ │
 │  └──────────────────────┬──────────────────────────┘ │
 │                         │                            │
 │  Thread de rede (TNetClientW98)                      │
 │  ┌─────────────────────────────────────────────────┐ │
 │  │  Winsock TCP ──► Broker                         │ │
 │  │  Read loop + heartbeat (ping/pong)              │ │
 │  │  Shared queue (CritSec) para envio              │ │
 │  └─────────────────────────────────────────────────┘ │
 │                                                      │
 │  TAgentCoreW98 (coordena as duas threads)            │
 └─────────────────────────────────────────────────────┘
```

**Técnica de detecção de mudança de clipboard no Win98:**  
A API `GetClipboardSequenceNumber()` só existe desde Windows XP. Para Win98, usamos a cadeia de clipboard viewers:
1. `SetClipboardViewer(hWnd)` registra nossa janela.
2. `WM_DRAWCLIPBOARD` é enviado a cada mudança de clipboard.
3. A janela deve propagar para o próximo na cadeia via `SendMessage`.
4. No encerramento, `ChangeClipboardChain(hWnd, hwndNextViewer)` remove da cadeia.

---

## 3. Camadas do Sistema

```
┌─────────────────────────────────────────────────────────────┐
│                    CAMADA DE APLICAÇÃO                      │
│  clipbrd_broker  │  clipbrd_agent_linux  │  clipbrd_agent_w98│
├──────────────────┼───────────────────────┼───────────────────┤
│              CAMADA DE PROTOCOLO (cbmessage, cbprotocol)    │
│  Serialização de frames │ Build/Parse de payloads           │
├─────────────────────────────────────────────────────────────┤
│                CAMADA DE COMPATIBILIDADE                    │
│  compat_profiles │ text_convert │ image_convert             │
├──────────────────────────────────────────────────────────────┤
│               CAMADA DE ACESSO AO CLIPBOARD                 │
│  clipboard_linux (X11/Lazarus) │ clipboard_win32 (CF_*)     │
├──────────────────────────────────────────────────────────────┤
│                    TRANSPORTE (TCP)                         │
│  ssockets (Linux) │ WinSock (Win32) │ CRC32 + framing       │
└─────────────────────────────────────────────────────────────┘
```

### 3.1 Camada de Formatos

| Formato Lógico  | Código | Uso na rede | Uso local Linux | Uso local Win98 |
|-----------------|--------|-------------|-----------------|-----------------|
| `FMT_TEXT_UTF8` | 0x01   | Sempre      | AsText (UTF-8)  | CF_TEXT (ANSI)  |
| `FMT_TEXT_ANSI` | 0x02   | Nunca       | —               | Interno         |
| `FMT_IMAGE_PNG` | 0x10   | Sempre      | TBitmap → PNG   | CF_DIB → PNG    |
| `FMT_IMAGE_BMP` | 0x11   | Nunca       | —               | Interno         |
| `FMT_IMAGE_DIB` | 0x12   | Nunca       | —               | Interno         |
| `FMT_HTML_UTF8` | 0x20   | Futuro v1.1 | —               | —               |

**Regra:** Na rede, somente formatos canônicos (UTF-8 para texto, PNG para imagem). Cada agente converte do formato local para o canônico antes de publicar, e do canônico para o local ao aplicar.

### 3.2 Perfis de Compatibilidade

| Perfil                    | Texto local | Texto rede | Imagem local | Imagem rede | HTML | Bidirecional |
|---------------------------|-------------|------------|--------------|-------------|------|--------------|
| `WIN98_LEGACY`            | ANSI CP1252 | UTF-8      | CF_DIB       | PNG         | Não  | Sim          |
| `WINNT_ANSI`              | ANSI        | UTF-8      | CF_DIB       | PNG         | Não  | Sim          |
| `LINUX_X11`               | UTF-8       | UTF-8      | TBitmap/PNG  | PNG         | Sim  | Sim          |
| `LINUX_WAYLAND_SESSION`   | UTF-8       | UTF-8      | PNG          | PNG         | Sim  | Sim          |
| `WINDOWS_MODERN_UNICODE`  | Unicode     | UTF-8      | CF_PNG/DIB   | PNG         | Sim  | Sim          |

---

## 4. Modelo de Dados

### 4.1 Registro de Nós (broker_registry)

```pascal
type
  TNodeInfo = record
    NodeID      : TNodeID;       // UUID 16 bytes
    Hostname    : string;
    OSType      : Byte;          // constante OS_xxx
    OSVersion   : string;
    Profile     : string;        // nome do perfil de compatibilidade
    Formats     : LongWord;      // bitmask de formatos suportados
    MaxPayloadKB: Word;
    CapFlags    : Byte;          // compressão, imagem, html, bidirecional
    Active      : Boolean;
    LastSeen    : Int64;         // Unix timestamp
    CreatedAt   : Int64;
    Groups      : TStringList;   // lista de group_ids (hex)
    SyncMode    : Byte;          // 0=recv_only, 1=send_only, 2=bidirecional
  end;
```

### 4.2 Item de Clipboard (histórico)

```pascal
type
  TClipItem = record
    ClipID       : TNodeID;      // UUID do item
    SourceNodeID : TNodeID;
    GroupID      : TNodeID;
    FormatType   : Byte;
    Hash         : TMD5Digest;   // MD5 do conteúdo
    Content      : TBytes;       // conteúdo no formato canônico de rede
    Timestamp    : Int64;
  end;
```

### 4.3 Esquema SQLite (broker)

```sql
CREATE TABLE nodes (
    node_id    TEXT PRIMARY KEY,
    hostname   TEXT NOT NULL,
    os_type    INTEGER NOT NULL,
    os_version TEXT,
    profile    TEXT NOT NULL,
    formats    INTEGER DEFAULT 0,
    cap_flags  INTEGER DEFAULT 0,
    max_kb     INTEGER DEFAULT 4096,
    sync_mode  INTEGER DEFAULT 2,
    active     INTEGER DEFAULT 1,
    last_seen  INTEGER,
    created_at INTEGER
);

CREATE TABLE groups (
    group_id   TEXT PRIMARY KEY,
    group_name TEXT NOT NULL UNIQUE,
    sync_mode  INTEGER DEFAULT 2,
    created_at INTEGER
);

CREATE TABLE node_groups (
    node_id  TEXT NOT NULL,
    group_id TEXT NOT NULL,
    mode     INTEGER DEFAULT 2,
    PRIMARY KEY (node_id, group_id)
);

CREATE TABLE clipboard_history (
    clip_id        TEXT PRIMARY KEY,
    source_node_id TEXT NOT NULL,
    group_id       TEXT NOT NULL,
    format_type    INTEGER NOT NULL,
    hash           TEXT NOT NULL,
    created_at     INTEGER NOT NULL,
    payload        BLOB
);
```

---

## 5. Fluxo de Mensagens

### 5.1 Conexão e Handshake

```
Agente                          Broker
  │                               │
  │──── TCP connect ─────────────►│
  │                               │
  │──── HELLO (v, os, hostname) ─►│   Broker valida versão
  │◄─── HELLO_ACK ────────────────│
  │                               │
  │──── AUTH (token) ────────────►│   Broker verifica token
  │◄─── AUTH_ACK (ok/fail) ───────│
  │                               │
  │──── ANNOUNCE (capabilities) ─►│   Broker registra/atualiza nó
  │◄─── ANNOUNCE_ACK ─────────────│
  │                               │
  │──── SUBSCRIBE_GROUP (gid) ───►│   Nó entra no grupo
  │◄─── SUBSCRIBE_ACK ────────────│
  │                               │
  │         (sessão ativa)        │
```

### 5.2 Publicação de Clipboard

```
Agente A                    Broker                  Agente B (mesmo grupo)
  │                           │                           │
  │  [Clipboard muda]         │                           │
  │  [Verifica anti-loop]     │                           │
  │  [Converte para canônico] │                           │
  │──── CLIP_PUBLISH ────────►│                           │
  │                           │  [Valida]                 │
  │                           │  [Verifica capacidade B]  │
  │                           │  [Registra histórico]     │
  │◄─── CLIP_ACK (broker OK) ─│                           │
  │                           │──── CLIP_PUSH ───────────►│
  │                           │                           │  [Verifica dedup hash]
  │                           │                           │  [Converte de canônico]
  │                           │                           │  [Aplica ao clipboard]
  │                           │◄─── CLIP_ACK (applied) ───│
```

### 5.3 Keepalive

```
Agente ──── PING (seq=N) ────► Broker
Agente ◄─── PONG (seq=N) ───── Broker

(a cada 30s, configurável; timeout = 3× intervalo)
```

---

## 6. Mecanismo Anti-Loop

O problema: se o Agente A sincroniza para o Agente B, e o Agente B aplica a mudança, o Agente B pode detectar a "mudança" e republicá-la, criando um loop.

**Solução em camadas:**

1. **`source_node_id`**: cada item carrega o ID do nó de origem. Cada agente ignora itens cuja `source_node_id == seu próprio node_id`.

2. **`last_applied_hash`**: após aplicar um item recebido remotamente, o agente grava o hash do conteúdo aplicado.

3. **`suppression_window`** (padrão 800ms): após aplicar um item remoto, inicia-se uma janela de supressão. Se o clipboard local mudar para o mesmo hash durante essa janela, a mudança não é publicada.

4. **`monotonic_seq`**: cada nó incrementa um contador por mensagem. O broker ignora mensagens com seq repetido ou muito antigo da mesma origem.

5. **Broker deduplica**: o broker mantém os hashes recentes recebidos. Se dois nós publicarem o mesmo hash em sequência rápida, o segundo é descartado.

```pascal
// Pseudo-código do agente ao detectar mudança local:
procedure OnClipboardChanged;
var newHash: TMD5Digest;
begin
  newHash := ComputeHash(CurrentClipboardContent);
  // Anti-loop check 1: mesmo hash do que aplicamos recentemente?
  if (newHash = FLastAppliedHash) and
     (MilliSecondsBetween(Now, FLastApplyTime) < FSuppressWindowMs) then
    Exit; // suprimido
  // Anti-loop check 2: mesmo hash do que publicamos recentemente?
  if newHash = FLastPublishedHash then
    Exit;
  // Publicar
  FLastPublishedHash := newHash;
  PublishToNetwork(newHash, CurrentClipboardContent);
end;
```

---

## 7. Segurança — Modelo de Ameaças e Decisões

### Ambiente alvo (v1)
LAN privada/laboratório. Não se assume adversário externo sofisticado.

### Mecanismos implementados (v1)
- **Token compartilhado**: configurado em `broker.ini` e `agent.ini`. Enviado no frame AUTH. Não transmitido em claro em produção (mas sem TLS no Win98, isso é uma limitação conhecida).
- **Bind por interface**: o broker pode ser configurado para escutar apenas em uma interface específica (ex.: `192.168.1.0/24`).
- **Whitelist de nós**: (v1.1) filtrar por node_id autorizado.
- **Modo inseguro controlado**: `allow_insecure=true` no broker permite conexões sem TLS, documentado explicitamente.

### Riscos documentados (v1)
| Risco | Mitigação v1 | Mitigação futura |
|-------|-------------|-----------------|
| Escuta na LAN (sniffing) | Isolar em VLAN/rede dedicada | TLS (incompatível com Win98) |
| Replay de mensagens AUTH | Curto TTL de sessão + seq counter | HMAC com nonce |
| Injeção de clipboard malicioso | Whitelist de nós + validação de tamanho | Sandbox por formato |
| Exfiltração via clipboard | Política de grupos separados | Auditoria + alertas |
| Token exposto em arquivo | Permissões de arquivo (chmod 600) | Keychain / secret store |

### Aviso formal
> **ClipBrdComp v1 NÃO deve ser exposto à internet ou redes não confiáveis.**
> O modo `allow_insecure=true` é para laboratório retro. Em produção, use uma rede isolada
> ou um túnel VPN externo (ex.: WireGuard no host Linux, não dependente do Win98).

---

## 8. Modelo de Implantação Detalhado

### Linux (broker + agente)

```
/etc/clipbrdcomp/broker.ini          → configuração do broker
/var/lib/clipbrdcomp/broker.db       → banco SQLite
/var/log/clipbrdcomp/broker.log      → log do broker
~/.config/clipbrdcomp/agent_linux.ini → configuração do agente
~/.local/share/clipbrdcomp/          → dados do agente

Inicialização do broker:
  systemd service OU script init.d OU manual

Inicialização do agente:
  ~/.config/autostart/clipbrd_agent.desktop  (para sessão gráfica)
  OU diretamente no terminal
```

### Windows 98

```
C:\Program Files\ClipBrdComp\
  clipbrd_agent_w98.exe
  agent_win98.ini
  clipbrd_agent.log

Inicialização automática:
  HKCU\Software\Microsoft\Windows\CurrentVersion\Run
  "ClipBrdAgent" = "C:\Program Files\ClipBrdComp\clipbrd_agent_w98.exe"
```

---

## 9. Decisões de Engenharia e Justificativas

| Decisão | Alternativas descartadas | Justificativa |
|---------|--------------------------|---------------|
| Protocolo binário com header fixo de 36 bytes | JSON, XML, HTTP | Simples de parsear em Pascal/C sem bibliotecas; funciona em Win98 sem JSON parser; menor overhead; depurável com hexdump |
| MD5 para hash de dedup | SHA256, SHA1 | Disponível em FPC como unit `md5`; suficiente para dedup (não é uso criptográfico); 16 bytes vs 20/32 |
| Thread por conexão no broker | select/epoll | Compatibilidade máxima com FPC; simples de raciocinar; adequado para dezenas de nós numa LAN |
| SQLite no broker | arquivos INI, PostgreSQL | Sem servidor externo; binário disponível em Linux; FPC tem binding nativo; queries simples |
| Token compartilhado | PKI, certificados | Suportável em Win98; simples de configurar em laboratório; não requer openssl |
| Agente Win98 como Win32 app com janela oculta | serviço Win9x | Win9x tem suporte limitado a serviços; janela oculta é idioma correto para clipboard viewers; mais simples |
| FPC para Win98 | Delphi 7, MSVC | FPC pode cross-compilar de Linux; é free software; RTL disponível para i386-win32; sem dependência de DLLs externas com linking estático |
| Polling no Linux (500ms) | XFixes extension | XFixes requer código Xlib externo; TClipboard polling é portável e suficientemente rápido para uso humano |
| Formato canônico somente na rede | converter no broker | Mantém o broker simples (sem lógica de format per-node); cada agente é responsável por sua conversão; escalável |
