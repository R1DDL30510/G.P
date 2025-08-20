README — Remote-Setup für GARVIS (Vorlage)

Ziel: Sichere Einrichtung von Git-Remote (Bare-Repo) und VSCode Remote-SSH für eine neue Instanz.
Prinzip: VPN-first, SSH-Keys only, kein WAN-Expose.
Stil: Schrittfolge ohne überflüssige Erklärungen.

⸻

0) Instanz-Variablen (zentrale Platzhalter)

Werte in `config/remote.env` setzen (Vorlage: `config/remote.env.example`).
Alle Verweise unten nutzen nur diese Platzhalter.

{{INSTANCE_ID}}                # kurze ID, z.B. `hostname -s`
{{HOST_KIND}}                  # windows|linux
{{HOST_NAME}}                  # Anzeigename des Hosts (`hostname`)
{{WG_HOST_V6}}                 # WireGuard IPv6, `ip -6 addr show wg0`
{{WG_SUBNET_V4}}               # WG-IPv4-Subnetz, aus WG-Konfig
{{WG_SUBNET_V6}}               # WG-IPv6-Subnetz, aus WG-Konfig
{{GIT_USER}}                   # dedizierter Git-User (keine Adminrechte)
{{DEV_USER}}                   # Arbeitsuser für Remote-SSH/Editor
{{CLIENT_TAG}}                 # Kommentar für SSH-Key, z.B. macbook-andrey
{{REPO_NAME}}                  # GARVIS
{{DEFAULT_BRANCH}}             # main
{{WIN_GIT_BIN}}                # z.B. "C:\\Program Files\\Git\\bin\\git.exe"
{{WIN_REPO_ROOT}}              # z.B. C:\\Users\\{{GIT_USER}}\\repos
{{LINUX_REPO_ROOT}}            # z.B. /home/{{GIT_USER}}/repos
{{WORK_TREE_WIN}}              # z.B. C:\\Users\\{{DEV_USER}}\\GARVIS
{{WORK_TREE_LINUX}}            # z.B. /home/{{DEV_USER}}/GARVIS
{{SSH_PORT}}                   # i.d.R. 22 (`sshd_config`)
{{ALLOW_USERS_ADDITIONAL}}     # optionale Whitelist, Leer lassen oder "user1 user2"
{{POST_RECEIVE_ENABLE}}        # true|false für Auto-Checkout
{{RUN_TESTS_ON_DEPLOY}}        # true|false

To-Do-Liste „für neue Instanz prüfen/setzen“ (alle an einer Stelle):
•{{INSTANCE_ID}}
•{{HOST_KIND}}
•{{WG_HOST_V6}}, {{WG_SUBNET_V4}}, {{WG_SUBNET_V6}}
•{{GIT_USER}}, {{DEV_USER}}, {{CLIENT_TAG}}
•{{REPO_NAME}}, {{DEFAULT_BRANCH}}
•{{WIN_GIT_BIN}}, {{WIN_REPO_ROOT}}, {{LINUX_REPO_ROOT}}
•{{WORK_TREE_WIN}}, {{WORK_TREE_LINUX}}
•{{SSH_PORT}}, {{ALLOW_USERS_ADDITIONAL}}
•{{POST_RECEIVE_ENABLE}}, {{RUN_TESTS_ON_DEPLOY}}

⸻

1) Voraussetzungen (MUSS)
•Zugriff ausschließlich über WireGuard (kein Port-Forwarding für {{SSH_PORT}}/TCP ins Internet).
•SSH-Passwortlogin AUS, nur Public-Key.
•Git installiert (Windows oder Linux entsprechend).

⸻

2) Host absichern (SSH)

2.1 Windows ({{HOST_KIND}} == windows)

Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0
Start-Service sshd; Set-Service sshd -StartupType Automatic

$cfg = 'C:\\ProgramData\\ssh\\sshd_config'
(Get-Content $cfg) `
  -replace '#?PasswordAuthentication.*','PasswordAuthentication no' `
  -replace '#?PubkeyAuthentication.*','PubkeyAuthentication yes' `
  -replace '#?PermitRootLogin.*','PermitRootLogin no' `
  | Set-Content $cfg -Encoding ascii

# Optional: explizit zulassen
Add-Content $cfg "`nAllowUsers {{DEV_USER}} {{GIT_USER}} {{ALLOW_USERS_ADDITIONAL}}"
Restart-Service sshd

# Firewall: nur WG-Subnetze auf {{SSH_PORT}}
New-NetFirewallRule -DisplayName "OpenSSH (WireGuard only)" -Direction Inbound `
  -Protocol TCP -LocalPort {{SSH_PORT}} -Action Allow `
  -RemoteAddress {{WG_SUBNET_V4}},{{WG_SUBNET_V6}}

2.2 Linux ({{HOST_KIND}} == linux)

sudo apt-get update && sudo apt-get install -y openssh-server git
sudo sed -i 's/^#\\?PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
echo "AllowUsers {{DEV_USER}} {{GIT_USER}} {{ALLOW_USERS_ADDITIONAL}}" | sudo tee -a /etc/ssh/sshd_config
sudo systemctl restart ssh

# Firewall-Beispiel (ufw)
sudo ufw allow from {{WG_SUBNET_V4}} to any port {{SSH_PORT}} proto tcp
sudo ufw allow from {{WG_SUBNET_V6}} to any port {{SSH_PORT}} proto tcp


⸻

3) Git-Remote bereitstellen (Bare-Repo, nur Git-Befehle)

3.1 User/Verzeichnisse

Windows

# dedizierter Git-User ohne Admin
net user {{GIT_USER}} (New-Guid).Guid /add

# Repo-Struktur
$root = "{{WIN_REPO_ROOT}}"
New-Item -ItemType Directory -Force -Path "$root\\{{REPO_NAME}}.git" | Out-Null

# Bare Repo
& {{WIN_GIT_BIN}} init --bare "$root\\{{REPO_NAME}}.git"

# Git-Shell erzwingen (keine TTY)
$gitShell='"{{WIN_GIT_BIN}}" -c "%SSH_ORIGINAL_COMMAND%"'
Add-Content 'C:\\ProgramData\\ssh\\sshd_config' "`nMatch User {{GIT_USER}}`n  ForceCommand $gitShell`n  AllowTcpForwarding no`n  X11Forwarding no`n  PermitTTY no"
Restart-Service sshd

Linux

sudo adduser --disabled-password --gecos "" {{GIT_USER}}
sudo -u {{GIT_USER}} mkdir -p {{LINUX_REPO_ROOT}}/{{REPO_NAME}}.git
sudo -u {{GIT_USER}} git init --bare {{LINUX_REPO_ROOT}}/{{REPO_NAME}}.git

# Option: git-shell als Login-Shell
echo "/usr/bin/git-shell" | sudo tee -a /etc/shells
sudo chsh -s /usr/bin/git-shell {{GIT_USER}}


⸻

4) Client-Keys erstellen & deployen (pro Entwicklergerät)

ssh-keygen -t ed25519 -C "{{CLIENT_TAG}}"

ssh -p {{SSH_PORT}} {{GIT_USER}}@{{WG_HOST_V6}} "mkdir -p ~/.ssh && chmod 700 ~/.ssh"
cat ~/.ssh/id_ed25519.pub \
| ssh -p {{SSH_PORT}} {{GIT_USER}}@{{WG_HOST_V6}} "cat >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys"

Optional (empfohlen): authorized_keys restriktiv — ersetze den PubKey-Prefix:

command="git-shell -c \"$SSH_ORIGINAL_COMMAND\"",no-port-forwarding,no-X11-forwarding,no-agent-forwarding,no-pty 


⸻

5) Projekt lokal → Remote hinzufügen

git remote remove {{INSTANCE_ID}} 2>/dev/null || true
git remote add {{INSTANCE_ID}} ssh://{{GIT_USER}}@{{WG_HOST_V6}}/~/repos/{{REPO_NAME}}.git
git fetch {{INSTANCE_ID}}
git push -u {{INSTANCE_ID}} {{DEFAULT_BRANCH}}
git ls-remote {{INSTANCE_ID}}


⸻

6) VSCode Remote-SSH (Editor auf Host, getrennt vom Git-User)

~/.ssh/config (Client):

Host {{INSTANCE_ID}}
  HostName {{WG_HOST_V6}}
  User {{DEV_USER}}
  Port {{SSH_PORT}}
  IdentitiesOnly yes
  IdentityFile ~/.ssh/id_ed25519
  PubkeyAuthentication yes
  PasswordAuthentication no

VSCode: „Remote Explorer → SSH Targets → {{INSTANCE_ID}} → Connect → Open Folder…“
Windows-Worktree: {{WORK_TREE_WIN}} • Linux-Worktree: {{WORK_TREE_LINUX}}

Wichtig: {{DEV_USER}} ≠ {{GIT_USER}}.

⸻

7) Auto-Deploy per Hook (optional)

Nur wenn {{POST_RECEIVE_ENABLE}}=true.

post-receive in Bare-Repo ({{WIN_REPO_ROOT}}\\{{REPO_NAME}}.git\\hooks\\post-receive oder {{LINUX_REPO_ROOT}}/{{REPO_NAME}}.git/hooks/post-receive):

#!/usr/bin/env bash
set -euo pipefail
read old new ref
branch="{{DEFAULT_BRANCH}}"
if [ "$ref" = "refs/heads/$branch" ]; then
  if [ "{{HOST_KIND}}" = "windows" ]; then
    GIT_WORK_TREE="{{WORK_TREE_WIN}}" git checkout -f "$branch"
  else
    GIT_WORK_TREE="{{WORK_TREE_LINUX}}" git checkout -f "$branch"
  fi

  if [ "{{RUN_TESTS_ON_DEPLOY}}" = "true" ]; then
    # hier Build/Test/Format ausführen (idempotent halten)
    echo "[deploy] running tests…"
    # z.B.: ./scripts/validate.sh || exit 1
  fi
fi

chmod +x <hook-pfad>/post-receive


⸻

8) Verifikation (Sollzustand)

# SSH-Reachability (git-user, ohne TTY)
ssh -p {{SSH_PORT}} -T {{GIT_USER}}@{{WG_HOST_V6}}

# Git-Remote funktionsfähig
git push {{INSTANCE_ID}} HEAD:refs/heads/{{DEFAULT_BRANCH}}
git ls-remote {{INSTANCE_ID}}

# VSCode Remote-SSH
# (via UI verbinden; alternativ:)
code --remote ssh-remote+{{INSTANCE_ID}} --reuse-window

Netzwerkscope:
•Kein Port-Forward für {{SSH_PORT}}/TCP auf WAN/Fritz!Box.
•Host-Firewall: nur {{WG_SUBNET_V4}}, {{WG_SUBNET_V6}} auf {{SSH_PORT}} zulassen.

⸻

9) Rollback / Cleanup

# Client
git remote remove {{INSTANCE_ID}} || true

# Host Windows
Remove-Item "{{WIN_REPO_ROOT}}\\{{REPO_NAME}}.git" -Recurse -Force

# Host Linux
sudo rm -rf "{{LINUX_REPO_ROOT}}/{{REPO_NAME}}.git"

# Keys: auf Host in ~/.ssh/authorized_keys entfernen


⸻

10) Quick-Checks (CI-geeignet)

test -n "{{WG_HOST_V6}}" && test -n "{{GIT_USER}}" && test -n "{{REPO_NAME}}"
git ls-remote {{INSTANCE_ID}} >/dev/null 2>&1
[ $? -eq 0 ] && echo "REMOTE_OK"


⸻

11) Kurzverweise
•git remote, git init --bare, git-shell
•ssh_config, sshd_config
•VSCode: Remote-SSH (Command Palette: „Remote: Connect to Host…“)

⸻

Hinweis zu Platzhaltern
•Alle Variablen stehen ausschließlich in Abschnitt 0.
•Keine Hardcodes in Befehlen unten; nur {{…}}.
•Das System kann durch einmaliges Ersetzen oben die komplette Datei instanzspezifisch konkretisieren.

⸻

Ende der Vorlage.
