# GARVIS – Current State Snapshot (2025-08-21)

> **Scope**: Integrates the Git→Work-Tree→Router→Ollama pipeline sketch into the canonical project state. Minimal, reproducible, privacy-first. Use as the live reference for setup and operations.

---

## 0) High-Level Flow

```
┌───────────────────────┐
│          Client       │
│ (VS Code / Git / API) │
└───────┬───────────────┘
        │ SSH / HTTPS
        ▼
┌───────────────────────┐
│        Firewall       │
│    (WireGuard-only)   │
└───────┬───────────────┘
        │
        ▼
┌─────────────────────────────┐
│  Git-Bare-Repo (git user)   │
│  /home/git/repos/garvis.git │
└───────┬─────────────────────┘
        │
        ▼
┌───────────────────────┐
│   Post-Receive Hook   │
│     (auto-checkout)   │
└───────┬───────────────┘
        │
        ▼
┌──────────────────────────┐
│  Work-Tree (dev user)    │
│  /home/dev/GARVIS        │
└───────┬──────────────────┘
        │
        ▼
┌──────────────────────────┐
│ Router Service (FastAPI) │
│   router/router.yaml     │
└───────┬──────────────────┘
        │
        ▼
┌──────────────────────────┐
│  Ollama Instances        │
│  ├─ CPU (OllamaCPU/)     │
│  ├─ GPU0 (OllamaGPU0/)   │
│  └─ GPU1 (OllamaGPU1/)   │
└───────┬──────────────────┘
        │
        ▼
┌──────────────────────────┐
│  Model Stores            │
│  (ollama/Modelfiles)     │
└──────────────────────────┘
```

---

## 1) Component Matrix

| Component | Role | How to operate |
| --------- | ---- | --------------- |
| **Client** | Git-push / VS Code Remote-SSH | `~/.ssh/config`, VS Code, `git push` |
| **Firewall** | Restricts access to WG subnet only | Linux: `ufw` (allow WG net only), Windows: `netsh advfirewall` rules |
| **Git-Bare-Repo** | Source of truth | `git init --bare`, shell: `git-shell` (restricted) |
| **Post-Receive Hook** | Auto-checkout into work-tree | `hooks/post-receive` (secure umask, forced work-tree) |
| **Work-Tree** | DEV workspace | `GIT_WORK_TREE`, `git checkout -f` |
| **Router** | Chooses Ollama node | `router/router.yaml`, service via systemd/PS service |
| **Ollama Instances** | Serve models | `./start_all.sh` (Linux/macOS) / `start_all.ps1` (Windows) |
| **Model Stores** | Modelfiles and blueprints | `ollama/Modelfiles`, `ollama create ...` |

---

## 2) Identities, Paths, Permissions (baseline)

- **Users**:
  - `git` (nologin, home `/home/git`, shell `git-shell`) → owns bare repo: `/home/git/repos/garvis.git`.
  - `dev` (login) → owns work-tree: `/home/dev/GARVIS`.
- **Ownership**: bare repo `git:git`; work-tree `dev:dev`.
- **Permissions**: bare repo `0750`; hook files `0750`; work-tree `0755` (tighten if needed). Umask `027`.
- **WireGuard**: inbound allowed only from WG subnet (IPv6 entrypoint per existing setup). No public exposure of Git/Router/Ollama.

---

## 3) Networking & Access Control

- **SSH** (recommended):
  - Server: `sshd` bound to WG addresses only (e.g., `ListenAddress fdxx:...`).
  - Client: `~/.ssh/config` example:

    ```sshconfig
    Host garvis-host
      HostName [fdxx:yyyy:...]
      User dev
      IdentityFile ~/.ssh/dev_ed25519
      ProxyJump none
      PreferredAuthentications publickey
    ```
- **HTTPS Git (optional)**: behind Caddy/nginx bound to WG only; mTLS optional.
- **Firewall**: allow `{22/tcp, 9418/tcp?}` from WG; block from WAN. Rate-limit SSH.

---

## 4) Git Bare Repo & Hook (authoritative)

- Create:

  ```bash
  sudo -u git mkdir -p /home/git/repos/garvis.git
  sudo -u git git init --bare /home/git/repos/garvis.git
  ```
- Restrict shell:

  ```bash
  chsh -s $(command -v git-shell) git
  ```
- **`hooks/post-receive`** (Linux) template:

  ```bash
  #!/usr/bin/env bash
  set -euo pipefail
  umask 027
  REPO="/home/git/repos/garvis.git"
  WORKTREE="/home/dev/GARVIS"
  BRANCH="refs/heads/main"

  while read oldrev newrev ref; do
    [ "$ref" = "$BRANCH" ] || continue
    sudo -u dev mkdir -p "$WORKTREE"
    git --work-tree="$WORKTREE" --git-dir="$REPO" checkout -f main
    sudo -u dev bash -lc "cd '$WORKTREE' && ./scripts/post_checkout_validate.sh"
    sudo systemctl restart garvis-router.service || true
  done
  ```

  - On Windows host, use `hooks\post-receive` PowerShell analog and restart the PS service.

---

## 5) Work-Tree Layout (canonical)

```
/home/dev/GARVIS/
├── router/
│   ├── router.yaml
│   ├── evaluator_proxy.py
│   └── gar_router.py
├── ollama/
│   ├── Modelfiles/
│   └── scripts/
├── scripts/
│   ├── start_all.sh
│   ├── post_checkout_validate.sh
│   └── validate_config.py
├── windows/
│   └── start_all.ps1
├── config/
│   ├── project.yml
│   ├── environments/{dev,prod}.json
│   └── cookiecutter.json
├── tests/
│   └── test_gar_router.py
└── .pre-commit-config.yaml
```

---

## 6) Router & Instances (operational)

- **`router/router.yaml`** drives:
  - endpoints, hardware traits, model aliases, default models
  - keyword heuristics, inventory tiers, evaluator proxy
- **Services**:
  - Linux: `garvis-router.service`, `ollama-cpu.service`, `ollama-gpu0.service`, `ollama-gpu1.service` (bind to localhost/WG only)
  - Windows: equivalent via NSSM/SC with `start_all.ps1`

---

## 7) Usage – Operator Path

1. Connect WireGuard → `ssh garvis-host` (dev or git user as needed).
2. **Dev loop**:
   - local edit → `git push` to `git@garvis-host:/home/git/repos/garvis.git`
   - post-receive → auto checkout into `/home/dev/GARVIS`
   - hook runs `scripts/post_checkout_validate.sh` → restart router service
3. Verify:

   ```bash
   curl http://127.0.0.1:8000/api/generate -d '{"model":"alias","prompt":"ping"}'
   ```
4. VS Code: Remote-SSH to `dev@garvis-host`.

---

## 8) Validation & CI (baseline)

- **Local pre-commit**: `pre-commit run --all-files` (YAML, Python, shell, powershell linters).
- **Tests**: `pytest -q` (router unit + config schema).
- **CI suggestion** (GitHub Actions or local runner):
  - steps: checkout → setup Python → `pip install -r requirements-dev.txt` → `pre-commit` → `pytest` → `python scripts/validate_config.py config/environments/prod.json`.

---

## 9) Security Notes

- WG-only ingress; **no public** exposure.
- Separate users (`git` vs `dev`), least privilege, `git-shell`.
- Hooks run with minimal env; avoid secrets in repo. Service files use `ProtectSystem=strict`, `ProtectHome=read-only` (Linux).
- Audit: log all pushes (`receive.denyDeletes=true`, `receive.denyNonFastforwards=true` unless explicitly allowed).

---

## 10) Open TODOs

- [ ] Add Windows `post-receive.ps1` with robust error handling and logging.
- [ ] Finalize `router/router.yaml` schema & validation script.
- [ ] Systemd/NSSM unit files checked into `ops/` with hardening flags.
- [ ] Inventory sync: ensure Modelfiles ↔ router aliases consistency.
- [ ] Document rollback procedure: `git revert` + service restart.

---

## 11) Quick Templates

**`scripts/post_checkout_validate.sh`**

```bash
#!/usr/bin/env bash
set -euo pipefail
python3 scripts/validate_config.py config/environments/dev.json
pytest -q || true
```

**Example `~/.ssh/config`**

```sshconfig
Host garvis-host
  HostName [fd91:3456:...:4902]
  User git
  IdentityFile ~/.ssh/garvis_git
  IdentitiesOnly yes
  ProxyJump none
```

---

**Status**: *This snapshot is active as of 2025-08-21 and should be treated as the operative baseline for development and operations.*
