# Claude Island Hook — Correctif Performance

**Drop-in replacement** du hook `claude-island-state.py` pour [Claude Island](https://github.com/anthropics/claude-island) — l'app macOS qui affiche l'etat de tes sessions Claude Code en temps reel.

## Le probleme

Le hook original `claude-island-state.py` est configure sur **11 evenements** Claude Code. A chaque outil utilise (Read, Write, Edit, Bash...), il se declenche **2 fois** (PreToolUse + PostToolUse). En session active, ca represente :

- **30-40 spawns Python3 par minute**
- Chaque spawn = ~73ms (startup Python + import json/socket/subprocess)
- **~2-3 secondes de CPU par minute** juste pour les hooks
- Sur un MacBook 18 Go RAM, ca contribue a des **crashs OOM** (Out of Memory)

### Anatomie d'un spawn Python

```
python3 claude-island-state.py
  ├── Python interpreter startup     (~30ms)
  ├── import json                    (~5ms)
  ├── import socket                  (~3ms)
  ├── import os, sys                 (~2ms)
  ├── subprocess.run(["ps", ...])    (~20ms — spawne un AUTRE process)
  ├── JSON parse                     (~3ms)
  ├── socket.connect()               (~5ms)
  └── socket.sendall()               (~2ms)
  Total: ~73ms, 2 processes (python3 + ps)
```

### Impact sur une session de 2 heures

| Metrique | Original (Python) | Corrige (Bash+Perl) |
|---|---|---|
| Temps par spawn | ~73ms | **~20ms** |
| CPU hooks/minute | 2-3s | **~0.6-0.8s** |
| Guard si app fermee | non (73ms quand meme) | **~0ms (exit immediat)** |
| Processes par event | 2 (python3 + ps) | **3 (bash + jq + nc)** |
| Securite socket | aucune verification | **verification proprietaire** |
| tool_input expose | complet (commandes, fichiers) | **filtre (metadata seule)** |

## La solution

Deux scripts de remplacement, utilisant des outils plus legers :

### `claude-island-state-fast.sh` (principal)

Script bash qui remplace Python pour **tous les evenements sauf PermissionRequest** :

```
bash claude-island-state-fast.sh
  ├── Guard: [ -S /tmp/claude-island.sock ] || exit 0   (~0ms)
  ├── cat (read stdin)                                    (~1ms)
  ├── jq (1 seul appel, extraction batch)                 (~10ms)
  ├── ps -p $PPID (TTY)                                   (~5ms)
  ├── String concatenation (pure bash, pas de jq)          (~1ms)
  └── nc -U (fire-and-forget socket)                       (~3ms)
  Total: ~20ms, 3 processes (bash + jq + nc)
```

**Gain : ~3.5x plus rapide que Python**, et le guard `[ -S socket ]` coupe-circuite immediatement si Claude Island n'est pas lance (~0ms).

### `claude-island-state-fast.pl` (PermissionRequest)

Script Perl pour le cas special `PermissionRequest` qui necessite une communication **bidirectionnelle** (envoyer la demande, attendre la decision de l'utilisateur) :

```
perl claude-island-state-fast.pl
  ├── Perl interpreter startup        (~10ms)
  ├── JSON::PP (core module)           (~5ms)
  ├── IO::Socket::UNIX (core module)   (~2ms)
  ├── Parse JSON + build state         (~2ms)
  ├── Socket connect + send            (~3ms)
  └── Wait for response (blocking)     (~0-300s)
  Total: ~22ms + attente decision
```

**Zero dependance externe** — JSON::PP et IO::Socket::UNIX sont dans le core Perl (pre-installe sur macOS depuis 2011).

## Installation

```bash
git clone https://github.com/aissablk1/claude-island-perf-fix.git
cd claude-island-perf-fix
chmod +x install.sh
./install.sh
```

L'installateur :
1. Sauvegarde l'original (`claude-island-state.py.backup`)
2. Copie les scripts optimises dans `~/.claude/hooks/`
3. Met a jour `~/.claude/settings.json` automatiquement

### Installation manuelle

1. Copier les scripts :
```bash
cp hooks/claude-island-state-fast.sh ~/.claude/hooks/
cp hooks/claude-island-state-fast.pl ~/.claude/hooks/
chmod +x ~/.claude/hooks/claude-island-state-fast.*
```

2. Dans `~/.claude/settings.json`, remplacer toutes les occurrences de :
```
"python3 ~/.claude/hooks/claude-island-state.py"
```
par :
```
"bash ~/.claude/hooks/claude-island-state-fast.sh"
```

3. Redemarrer Claude Code.

## Desinstallation

```bash
cp ~/.claude/hooks/claude-island-state.py.backup ~/.claude/hooks/claude-island-state.py
cp ~/.claude/settings.json.backup ~/.claude/settings.json
```

## Configuration

Le chemin du socket est configurable via variable d'environnement :

```bash
export CLAUDE_ISLAND_SOCKET="/path/to/custom/socket.sock"
```

Par defaut : `/tmp/claude-island.sock`

## Compatibilite

- macOS 12+ (Monterey et superieur)
- Perl 5.14+ (pre-installe sur macOS)
- jq (installer via `brew install jq` si absent)
- nc (netcat, pre-installe sur macOS)
- Claude Code CLI
- Claude Island app

## Architecture

```
hooks/
  claude-island-state-fast.sh   # Script principal (bash+jq+nc)
  claude-island-state-fast.pl   # Fallback Perl pour PermissionRequest
                                # (utilisable aussi en standalone pour tous les events)
  claude-island-state.py        # Original Python (inclus pour reference/comparaison)
install.sh                      # Installateur automatique
LICENSE                         # MIT
.gitignore
README.md                       # Ce fichier
```

### Flux de decision

```
Hook event
  │
  ├── PermissionRequest ?
  │     └── OUI → Perl (bidirectionnel, attend la decision)
  │
  └── NON → Bash (fire-and-forget)
        │
        ├── Socket existe ?
        │     └── NON → exit 0 immediatement (~0ms)
        │
        └── OUI → jq parse + nc envoie (~20ms)
```

## Contexte

Ce correctif a ete developpe apres un **crash OOM** (Out of Memory) sur un MacBook Pro M3 Pro 18 Go le 23 mars 2026. L'analyse a revele que `claude-island-state.py`, configure sur 11 evenements avec Claude Code, generait ~4000 spawns Python3 par session de 2 heures, contribuant a une saturation memoire.

## Auteur

Aissa Belkoussa — [@aissablk1](https://github.com/aissablk1)

## Licence

MIT
