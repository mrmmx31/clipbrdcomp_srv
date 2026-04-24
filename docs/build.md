# Guia de Build e Testes — ClipBrdComp

## Pré-requisitos

### Linux (broker + agente Linux)

```bash
# FPC 3.2.x
sudo apt install fpc

# Lazarus (para o agente Linux)
sudo apt install lazarus

# Dependência do broker: SQLite3
sudo apt install libsqlite3-dev

# Dependências do widgetset GTK2 (para Lazarus/TClipboard)
sudo apt install libgtk2.0-dev

# Cross-compile para Win98 (opcional, no mesmo host Linux)
sudo apt install fpc-i386       # ou fpc-cross, dependendo da distro
```

Verifique as versões:
```bash
fpc --version       # deve ser >= 3.2.0
lazbuild --version  # deve ser >= 2.0.0
```

### Windows 98 (compilação nativa, alternativa ao cross-compile)

1. Baixe FPC 3.2.0 para Win32: https://www.freepascal.org/download.html
2. Instale em `C:\FPC`
3. Adicione `C:\FPC\bin\i386-win32` ao PATH
4. Abra um prompt MS-DOS e compile:
   ```
   cd C:\clipbrdcomp\agent\win98
   fpc -Fu..\..\protocol -Fu..\..\compat -Fu. clipbrd_agent_w98.lpr
   ```

> **Nota**: FPC 3.2.x funciona no Windows 98 SE para compilação nativa.
> Para compilar via 16-bit DOS, **não é possível** — use o cross-compile a partir do Linux.

---

## Compilando

### 1. Broker (Linux)

```bash
chmod +x build/build_broker.sh
./build/build_broker.sh release
# Binário: bin/clipbrd_broker
```

Compilação manual:
```bash
cd broker
fpc \
  -Fu../protocol \
  -Fu../compat \
  -Fu. \
  -O2 -Xs \
  clipbrd_broker.lpr \
  -o ../bin/clipbrd_broker
```

### 2. Agente Linux

```bash
chmod +x build/build_agent_linux.sh
./build/build_agent_linux.sh release
# Binário: bin/clipbrd_agent_linux
```

Compilação manual via lazbuild:
```bash
cd agent/linux
lazbuild --build-mode=Release clipbrd_agent_linux.lpi
```

### 3. Agente Win98 (cross-compile do Linux)

```bash
chmod +x build/build_agent_win98.sh
./build/build_agent_win98.sh release
# Binário: bin/clipbrd_agent_w98.exe
```

Compilação manual:
```bash
cd agent/win98
fpc \
  -Pi386 -Twin32 -WG \
  -Fu../../protocol \
  -Fu../../compat \
  -Fu. \
  -O2 -Xs \
  clipbrd_agent_w98.lpr \
  -o ../../bin/clipbrd_agent_w98.exe
```

---

## Configuração Rápida

### Broker

```bash
# Gera config padrão
./bin/clipbrd_broker --gen-config broker.ini

# Edite o token e o caminho do banco
nano broker.ini

# Inicia o broker
./bin/clipbrd_broker broker.ini
```

Saída esperada:
```
[INFO] ClipBrdComp Broker v1.0 starting
[INFO] Listening on 0.0.0.0:6543
[INFO] Database: ./broker.db (OK)
[INFO] Ready.
```

### Agente Linux

```bash
mkdir -p ~/.config/clipbrdcomp
cp config/agent_linux.ini.example ~/.config/clipbrdcomp/agent_linux.ini

# Edite: broker_host, auth_token
nano ~/.config/clipbrdcomp/agent_linux.ini

# Inicia (em sessão gráfica X11)
./bin/clipbrd_agent_linux
```

Saída esperada:
```
ClipBrdComp Agent (Linux/X11) v1.0
Config: /home/user/.config/clipbrdcomp/agent_linux.ini
Generated node_id: 3f2a1b4c-...
[AgentCore] Starting. Node=3f2a1b4c-...
[AgentCore] Broker=192.168.1.100:6543
[NetClient] Connected and active. NodeID=3f2a1b4c-...
```

### Agente Win98

1. Copie `bin/clipbrd_agent_w98.exe` para a máquina Win98
2. Copie `config/agent_win98.ini.example` como `agent_win98.ini` na mesma pasta
3. Edite `agent_win98.ini`:
   - `broker_host` = IP do Linux com o broker
   - `auth_token` = mesmo token do broker
4. Execute `clipbrd_agent_w98.exe`
5. Um ícone aparecerá no system tray

---

## Plano de Testes

### Teste 1: Conectividade básica

```bash
# Terminal 1: broker
./bin/clipbrd_broker broker.ini

# Terminal 2: agente Linux
./bin/clipbrd_agent_linux

# Esperado nos logs do broker:
# [INFO] New connection from 127.0.0.1:xxxxx
# [INFO] Node registered: <uuid> LINUX_X11
# [INFO] Node subscribed to group: default
```

### Teste 2: Sincronização de texto Linux → Linux

Com dois agentes Linux em máquinas diferentes (ou no mesmo host com configs distintas):

```bash
# Máquina A: copie um texto no terminal ou em qualquer app
echo "Hello ClipBrdComp" | xclip -selection clipboard

# Máquina B: verifique
xclip -selection clipboard -o
# Esperado: "Hello ClipBrdComp"
```

### Teste 3: Sincronização de texto Linux → Win98

1. Copie texto em qualquer aplicativo Linux (Ctrl+C)
2. No Win98, pressione Ctrl+V em qualquer editor
3. O texto deve aparecer (em ANSI, possivelmente com ajuste de caracteres acentuados)

### Teste 4: Sincronização de imagem

```bash
# Captura screenshot e coloca no clipboard Linux
import -window root -format png png:- | xclip -selection clipboard -t image/png

# No Win98, tente colar em MS Paint
```

### Teste 5: Anti-loop

Copie o mesmo texto em dois terminais rapidamente. O broker deve deduplicar:
```
[WARN] Ignoring duplicate clip_id from node <uuid>
```
Não deve haver loop infinito de re-publicações.

### Teste 6: Reconexão

```bash
# Mate o broker e reinicie
killall clipbrd_broker
sleep 3
./bin/clipbrd_broker broker.ini

# O agente deve reconectar automaticamente dentro de reconnect_interval_sec
# Log esperado:
# [NetClient] Connection lost
# [NetClient] Connected and active.
```

---

## Estrutura de Logs

### Broker (`broker.log`)
```
2025-01-15 10:23:01 [INFO] New connection from 192.168.1.50:52341
2025-01-15 10:23:01 [INFO] HELLO from OS=0x10 (WIN98)
2025-01-15 10:23:01 [INFO] AUTH OK for node abc123...
2025-01-15 10:23:01 [INFO] ANNOUNCE: profile=WIN98_LEGACY formats=0x13
2025-01-15 10:23:01 [INFO] SUBSCRIBE group=00000000-...0001 mode=bidir
2025-01-15 10:23:45 [INFO] CLIP_PUBLISH from abc123... fmt=0x01 size=128
2025-01-15 10:23:45 [INFO] CLIP_PUSH to def456... (1 of 1 targets)
```

### Agente Linux
```
[AgentCore] Published text (42 bytes)
[AgentCore] CLIP_PUSH fmt=0x01 size=42 from=def456...
[AgentCore] Applied text to clipboard (42 bytes)
```

### Agente Win98 (em `clipbrd_agent.log`)
```
[NetW98] Connected. NodeID=abc123...
[CoreW98] Published fmt=0x01 size=42
[CoreW98] Applied text to clipboard (42 bytes)
```

---

## Solução de Problemas

| Problema | Causa provável | Solução |
|---|---|---|
| "AUTH failed" | auth_token diferente | Verifique broker.ini e agent*.ini |
| "Connect failed" | broker não acessível | Verifique IP, porta, firewall |
| Texto com caracteres errados | Codepage incorreta | Ajuste `text_codepage` no agent_win98.ini |
| Imagem não sincroniza | Formato não suportado | Verifique `formats` no perfil do agente |
| Loop de re-publicação | Supressão muito curta | Aumente `dedup_window_ms` |
| Win98: ícone não aparece | Shell32.dll antiga | Normal em Win95; use Win98 SE |
| Broker: "sqlite3: symbol not found" | libsqlite3 não instalada | `sudo apt install libsqlite3-dev` |

---

## Implantação em Produção

### Broker como serviço systemd

```ini
# /etc/systemd/system/clipbrdcomp-broker.service
[Unit]
Description=ClipBrdComp Clipboard Broker
After=network.target

[Service]
Type=simple
User=clipbrdcomp
ExecStart=/usr/local/bin/clipbrd_broker /etc/clipbrdcomp/broker.ini
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
```

```bash
sudo systemctl enable --now clipbrdcomp-broker
```

### Agente Linux como serviço de sessão

Crie `~/.config/autostart/clipbrdcomp-agent.desktop`:
```ini
[Desktop Entry]
Type=Application
Name=ClipBrdComp Agent
Exec=/usr/local/bin/clipbrd_agent_linux
Hidden=false
NoDisplay=false
X-GNOME-Autostart-enabled=true
```

### Agente Win98 na inicialização

Adicione `clipbrd_agent_w98.exe` ao registro do Windows 98:
- `HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\Run`
- Valor: `ClipBrdComp` = `C:\ClipBrdComp\clipbrd_agent_w98.exe`

Ou coloque um atalho no grupo `StartUp` do menu Iniciar.
