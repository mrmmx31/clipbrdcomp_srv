# ClipBrdComp — Sincronização de Clipboard em Rede

Sistema profissional de sincronização de área de transferência via TCP, com suporte
a texto e imagens entre Linux (X11) e Windows 98/ME e sistemas modernos.

```
┌─────────────┐     TCP 6543      ┌──────────────────┐     TCP 6543      ┌─────────────┐
│  Linux X11  │ ◄──────────────► │  Broker (Linux)  │ ◄──────────────► │  Win98/ME   │
│  (Lazarus)  │                   │  (FreePascal)    │                   │  (FPC Win32)│
└─────────────┘                   └──────────────────┘                   └─────────────┘
  TClipboard                      SQLite + Threads                      WM_DRAWCLIPBOARD
  UTF-8 ↔ PNG                     Binary Protocol                       ANSI ↔ CF_DIB
```

## Características

- **Protocolo binário eficiente** — frames de 40 bytes de overhead + payload
- **Compatibilidade retro** — Windows 98 com Winsock 1.1 e CF_DIB
- **Conversão automática** — UTF-8 ↔ ANSI CP1252, PNG ↔ DIB/BMP
- **Anti-loop** — MD5 hash + janela de supressão de 800ms
- **Reconexão automática** — agentes reconectam após queda do broker
- **Grupos** — múltiplas máquinas podem ser organizadas em grupos de sync
- **SQLite** — histórico e registro de nós no broker
- **Thread-safe** — sessões isoladas no broker, critical sections nos agentes

## Estrutura do Projeto

```
clipbrdcomp_srv/
├── protocol/          # Unidades compartilhadas (protocolo wire)
│   ├── cbprotocol.pas     # Constantes, tipos, TCBHeader (36 bytes)
│   ├── cbcrc32.pas        # CRC32 IEEE 802.3 (puro Pascal)
│   ├── cbhash.pas         # MD5 para deduplicação
│   ├── cbuuid.pas         # Geração de UUID v4
│   └── cbmessage.pas      # Serialização/desserialização de frames
│
├── compat/            # Camada de compatibilidade
│   ├── compat_profiles.pas  # Perfis WIN98_LEGACY, LINUX_X11, etc.
│   ├── text_convert.pas     # CP1252 ↔ UTF-8 (tabela pura Pascal)
│   └── image_convert.pas    # PNG ↔ DIB/BMP via FPImage
│
├── broker/            # Servidor central (Linux)
│   ├── clipbrd_broker.lpr   # Programa principal
│   ├── broker_server.pas    # Loop de accept TCP
│   ├── broker_session.pas   # Thread por conexão (state machine)
│   ├── broker_router.pas    # Roteamento de clipboard entre nós
│   ├── broker_registry.pas  # Registro em memória (thread-safe)
│   ├── broker_db.pas        # Persistência SQLite
│   ├── broker_config.pas    # Configuração INI
│   └── broker_logger.pas    # Log thread-safe
│
├── agent/
│   ├── linux/         # Agente Linux (Lazarus/X11)
│   │   ├── clipbrd_agent_linux.lpr  # Main
│   │   ├── clipbrd_agent_linux.lpi  # Projeto Lazarus
│   │   ├── agent_core.pas           # Coordenação polling + rede
│   │   ├── agent_netclient.pas      # Cliente TCP (ssockets)
│   │   ├── clipboard_linux.pas      # TClipboard X11
│   │   └── agent_config.pas         # Configuração INI
│   │
│   └── win98/         # Agente Windows 98 (FPC Win32)
│       ├── clipbrd_agent_w98.lpr    # Main (GUI, message loop)
│       ├── agent_core_w98.pas       # Coordenação
│       ├── agent_netclient_w98.pas  # Cliente Winsock
│       ├── clipboard_win32.pas      # CF_TEXT + CF_DIB
│       ├── wintray_w98.pas          # System tray + WM_DRAWCLIPBOARD
│       └── agent_config_w98.pas     # Configuração INI
│
├── config/            # Exemplos de configuração
├── build/             # Scripts de compilação
└── docs/              # Documentação técnica
    ├── architecture.md  # Visão geral da arquitetura
    ├── protocol.md      # Especificação do protocolo wire
    └── build.md         # Guia de compilação e testes
```

## Quick Start

```bash
# 1. Compile o broker
./build/build_broker.sh release

# 2. Configure e inicie
cp config/broker.ini.example broker.ini
# edite broker.ini: auth_token
./bin/clipbrd_broker broker.ini

# 3. Configure e inicie o agente Linux
mkdir -p ~/.config/clipbrdcomp
cp config/agent_linux.ini.example ~/.config/clipbrdcomp/agent_linux.ini
# edite: broker_host, auth_token
./build/build_agent_linux.sh release
./bin/clipbrd_agent_linux

# 4. Cross-compile e deploy do agente Win98
./build/build_agent_win98.sh release
# Copie bin/clipbrd_agent_w98.exe + config para a máquina Win98
```

Veja [docs/build.md](docs/build.md) para o guia completo de build e testes.

## Protocolo

Frame wire: `[36-byte header][N-byte payload][4-byte CRC32]`

O header contém: magic `CB`, versão, tipo de mensagem, flags, Node ID (UUID 16 bytes),
número de sequência, timestamp Unix e tamanho do payload — tudo em big-endian.

Tipos de mensagem principais: `HELLO/ACK`, `AUTH/ACK`, `ANNOUNCE/ACK`,
`CLIP_PUBLISH`, `CLIP_PUSH`, `CLIP_ACK`, `PING/PONG`, `SUBSCRIBE_GROUP/ACK`.

Veja [docs/protocol.md](docs/protocol.md) para a especificação completa.

## Compatibilidade

| Sistema       | Texto | Imagem | Método de Detecção         |
|---------------|-------|--------|----------------------------|
| Linux X11     | ✅ UTF-8 | ✅ PNG | Polling TClipboard 500ms  |
| Linux Wayland | ✅ UTF-8 | ✅ PNG | Polling TClipboard 500ms  |
| Windows 98    | ✅ ANSI→UTF-8 | ✅ DIB→PNG | WM_DRAWCLIPBOARD   |
| Windows ME    | ✅ ANSI→UTF-8 | ✅ DIB→PNG | WM_DRAWCLIPBOARD   |
| Windows XP+   | ✅ ANSI→UTF-8 | ✅ DIB→PNG | WM_DRAWCLIPBOARD   |

## Requisitos de Compilação

| Componente       | Ferramenta                              |
|------------------|-----------------------------------------|
| Broker (Linux)   | FPC 3.2.x + libsqlite3-dev             |
| Agente Linux     | Lazarus 2.x + FPC 3.2.x + libgtk2-dev |
| Agente Win98     | FPC cross i386-win32 (do Linux)        |
|                  | ou FPC nativo no Windows               |

## Licença

Projeto educacional / prova de conceito. Use e modifique livremente.
