# Guida Completa: Montare Dischi Windows da Mac con FUSE-T + SSHFS

## Cos'e FUSE-T?

FUSE-T e un'alternativa a macFUSE che **non richiede kernel extension**. Funziona interamente in userspace traducendo le chiamate FUSE in NFS v4. Non serve riavviare il Mac in Recovery Mode, non serve abbassare la sicurezza, non si rompe con gli aggiornamenti di macOS.

| | macFUSE | FUSE-T |
|---|---|---|
| Kernel extension | Si (kext) | No |
| Recovery Mode boot | Si (Apple Silicon) | No |
| Ridurre sicurezza SIP | Si | No |
| Si rompe con aggiornamenti macOS | Spesso | Raramente |
| Performance | Leggermente migliore | Adeguata |
| File locking (flock) | Si | No (limitazione NFS) |
| Licenza | Proprietaria | Open source |

---

## Parte 1: Configurare Windows (il PC remoto)

### 1.1 Installare OpenSSH Server

OpenSSH e gia incluso in Windows 10 (1809+) e Windows 11. Basta attivarlo.

**Metodo GUI:**
1. Apri **Impostazioni > Sistema > Funzionalita facoltative**
2. Clicca **Aggiungi una funzionalita**
3. Cerca **Server OpenSSH**
4. Clicca **Installa**

**Metodo PowerShell (come Amministratore):**
```powershell
# Verifica se e gia installato
Get-WindowsCapability -Online | Where-Object Name -like 'OpenSSH.Server*'

# Installa
Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0
```

### 1.2 Avviare il servizio SSH

```powershell
# Avvia il servizio
Start-Service sshd

# Imposta avvio automatico al boot
Set-Service -Name sshd -StartupType 'Automatic'
```

### 1.3 Verificare il firewall

Windows crea la regola automaticamente, ma verifica:
```powershell
Get-NetFirewallRule -Name *ssh*
```

Se non esiste:
```powershell
New-NetFirewallRule -Name sshd -DisplayName 'OpenSSH Server' -Enabled True -Direction Inbound -Protocol TCP -Action Allow -LocalPort 22
```

### 1.4 Trovare l'indirizzo IP del PC

```powershell
ipconfig
```

Cerca **Indirizzo IPv4** sotto l'adattatore Ethernet o Wi-Fi attivo (es. `192.168.1.100`).

### 1.5 Trovare il MAC Address (per Wake-on-LAN)

```powershell
getmac /v /fo list
```

Cerca l'adattatore connesso (non "Supporto disconnesso") e annota l'**Indirizzo fisico** (es. `10-FF-E0-C9-BD-85`).

---

## Parte 2: Configurare il Mac

### 2.1 Installare Homebrew (se non l'hai gia)

```bash
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
```

### 2.2 Installare FUSE-T + SSHFS

```bash
# Aggiungi il tap di FUSE-T
brew tap macos-fuse-t/homebrew-cask

# Installa FUSE-T (il framework)
brew install fuse-t

# Installa SSHFS per FUSE-T
brew install fuse-t-sshfs
```

**Se hai gia macFUSE installato**, disinstallalo prima per evitare conflitti:
```bash
brew uninstall sshfs      # versione macFUSE
brew uninstall macfuse
```

### 2.3 Verificare l'installazione

```bash
sshfs --version
```

Dovresti vedere un output che include `FUSE library version: 2.9.x` o simile.

---

## Parte 3: Creare la chiave SSH

### 3.1 Generare la chiave sul Mac

```bash
ssh-keygen -t ed25519 -C "mac-to-windows"
```

Premi Enter per accettare il path di default (`~/.ssh/id_ed25519`).
Puoi impostare una passphrase o lasciare vuota per accesso senza password.

### 3.2 Copiare la chiave pubblica su Windows

**Sul Mac**, mostra la chiave pubblica:
```bash
cat ~/.ssh/id_ed25519.pub
```

Copia l'output (inizia con `ssh-ed25519 AAAA...`).

**Su Windows**, apri PowerShell come Amministratore:

**Se il tuo utente Windows e un Amministratore** (caso piu comune):
```powershell
# Crea il file delle chiavi autorizzate per admin
Add-Content -Path C:\ProgramData\ssh\administrators_authorized_keys -Value "ssh-ed25519 AAAA... mac-to-windows"

# CRITICO: sistema i permessi (senza questo, SSH ignora il file)
icacls C:\ProgramData\ssh\administrators_authorized_keys /inheritance:r /grant "Administrators:F" /grant "SYSTEM:F"
```

**Se il tuo utente NON e Amministratore:**
```powershell
mkdir C:\Users\TuoNome\.ssh -Force
Add-Content -Path C:\Users\TuoNome\.ssh\authorized_keys -Value "ssh-ed25519 AAAA... mac-to-windows"
```

### 3.3 Riavviare il servizio SSH su Windows

```powershell
Restart-Service sshd
```

### 3.4 Testare la connessione dal Mac

```bash
ssh NomeUtenteWindows@192.168.1.100
```

Dovrebbe connettersi **senza chiedere la password** (solo la passphrase della chiave, se l'hai impostata).

**Se chiede ancora la password**, il problema e quasi sempre nei permessi del file `administrators_authorized_keys`. Ripeti il comando `icacls` del passo 3.2.

---

## Parte 4: Montare il disco

### 4.1 Creare il punto di mount

```bash
mkdir -p ~/workstation
```

### 4.2 Montare un disco Windows

**Montare il disco D:**
```bash
sshfs NomeUtente@192.168.1.100:/D:/ ~/workstation
```

**Montare il disco C:**
```bash
sshfs NomeUtente@192.168.1.100:/C:/ ~/workstation-C
```

**Montare una cartella specifica:**
```bash
sshfs NomeUtente@192.168.1.100:/D:/Progetti ~/progetti-remoti
```

**Note sui path Windows:**
- Usa `/` (slash), non `\` (backslash)
- I dischi sono accessibili come `/C:/`, `/D:/`, `/E:/`
- I path partono dalla root del disco: `/C:/Users/NomeUtente/Documents`

### 4.3 Verificare il mount

```bash
ls ~/workstation
```

Dovresti vedere i file del disco remoto.

### 4.4 Smontare

```bash
umount ~/workstation
```

Se non funziona:
```bash
diskutil unmount force ~/workstation
```

---

## Parte 5: Mount ottimizzato (performance)

Per uso quotidiano, usa queste opzioni per prestazioni migliori:

```bash
sshfs NomeUtente@192.168.1.100:/D:/ ~/workstation \
  -o reconnect \
  -o ServerAliveInterval=15 \
  -o ServerAliveCountMax=3 \
  -o Ciphers=aes128-gcm@openssh.com \
  -o Compression=no \
  -o cache=yes \
  -o auto_cache \
  -o kernel_cache \
  -o attr_timeout=115200 \
  -o entry_timeout=115200 \
  -o dcache_timeout=115200 \
  -o large_read \
  -o big_writes \
  -o noappledouble \
  -o noapplexattr \
  -o defer_permissions \
  -o follow_symlinks
```

**Spiegazione opzioni chiave:**

| Opzione | Effetto |
|---|---|
| `reconnect` | Riconnessione automatica se la connessione cade |
| `ServerAliveInterval=15` | Keepalive ogni 15 secondi (previene timeout) |
| `Ciphers=aes128-gcm` | Cifratura veloce (accelerata hardware) |
| `Compression=no` | Niente compressione su LAN (sarebbe overhead inutile) |
| `cache=yes` + `kernel_cache` | Cache dei file in memoria (molto piu veloce) |
| `attr_timeout=115200` | Cache attributi file per 32 ore (per uso singolo utente) |
| `noappledouble` | Non creare file `._*` (metadati macOS) su Windows |
| `defer_permissions` | Non controllare permessi Unix su filesystem Windows |

---

## Parte 6: Troubleshooting

### "Permission denied (publickey)"
Il file `authorized_keys` su Windows ha permessi sbagliati. Esegui su Windows:
```powershell
icacls C:\ProgramData\ssh\administrators_authorized_keys /inheritance:r /grant "Administrators:F" /grant "SYSTEM:F"
Restart-Service sshd
```

### "Connection refused" o "Connection timed out"
1. Verifica che `sshd` sia in esecuzione su Windows: `Get-Service sshd`
2. Verifica il firewall: `Get-NetFirewallRule -Name *ssh*`
3. Verifica l'IP: `ipconfig` su Windows, `ping 192.168.1.100` dal Mac

### Il mount si blocca dopo lo sleep del Mac
SSHFS perde la connessione quando il Mac va in sleep. Usa l'opzione `-o reconnect` e un keepalive:
```bash
-o reconnect -o ServerAliveInterval=15 -o ServerAliveCountMax=3
```

Oppure usa **AutoFuse** che gestisce questo automaticamente con auto-heal.

### Performance lenta (ls lento, IDE che si blocca)
Aumenta i timeout della cache:
```bash
-o attr_timeout=115200 -o entry_timeout=115200 -o dcache_timeout=115200
```

### "mount_nfs: Operation not permitted"
FUSE-T potrebbe non essere installato correttamente. Reinstalla:
```bash
brew reinstall fuse-t fuse-t-sshfs
```

### Nomi file con caratteri speciali non funzionano
Imposta PowerShell come shell di default su Windows SSH:
```powershell
New-ItemProperty -Path "HKLM:\SOFTWARE\OpenSSH" -Name DefaultShell -Value "C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe" -PropertyType String -Force
Restart-Service sshd
```

### File locking non funziona (database, alcune app)
Questa e una **limitazione nota** di FUSE-T. Poiche usa NFS come trasporto, `flock()` non e supportato. App che richiedono file locking (alcuni database, certi editor) non funzioneranno correttamente. In questo caso, usa macFUSE oppure lavora direttamente via SSH.

---

## Parte 7: Usare AutoFuse (il modo facile)

Invece di ricordare tutti questi comandi, puoi usare **AutoFuse** che fa tutto automaticamente:

1. Apri AutoFuse dalla barra menu
2. Clicca **Add Workstation...**
3. Inserisci nome, IP, utente (o clicca **Scan Network** per trovarlo automaticamente)
4. Clicca **Auto-Detect** per rilevare MAC address e dischi
5. Clicca **Save**
6. Clicca sul disco per montarlo con un click

AutoFuse gestisce automaticamente:
- Riconnessione dopo sleep/wake
- Riconnessione dopo cambio rete WiFi/VPN
- Wake-on-LAN per svegliare PC spenti
- Scelta automatica LAN o VPN
- Supporto sia macFUSE che FUSE-T

---

## Checklist Rapida

### Windows
- [ ] OpenSSH Server installato e avviato
- [ ] Servizio sshd impostato su Automatico
- [ ] Firewall: porta 22 aperta
- [ ] Chiave pubblica del Mac aggiunta a `administrators_authorized_keys`
- [ ] Permessi fissati con `icacls`
- [ ] Servizio sshd riavviato

### Mac
- [ ] Chiave SSH generata (`ssh-keygen -t ed25519`)
- [ ] Chiave pubblica copiata su Windows
- [ ] Test SSH funzionante (`ssh utente@ip`)
- [ ] FUSE-T installato (`brew install fuse-t`)
- [ ] SSHFS installato (`brew install fuse-t-sshfs`)
- [ ] Mount point creato (`mkdir -p ~/workstation`)
- [ ] Mount funzionante (`sshfs utente@ip:/D:/ ~/workstation`)
