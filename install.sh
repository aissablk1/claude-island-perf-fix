#!/usr/bin/env bash
# install.sh — Installe le hook optimise pour Claude Island
# ─────────────────────────────────────────────────────────────────────────────
set -e

HOOKS_DIR="$HOME/.claude/hooks"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SETTINGS="$HOME/.claude/settings.json"

echo "=== Claude Island Hook — Installation ==="
echo ""

# Prerequis
command -v perl >/dev/null 2>&1 || { echo "ERREUR: perl requis"; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "ERREUR: jq requis (brew install jq)"; exit 1; }
command -v nc >/dev/null 2>&1 || { echo "ERREUR: nc (netcat) requis"; exit 1; }
perl -e 'use JSON::PP; use IO::Socket::UNIX; use IO::Select' 2>/dev/null || { echo "ERREUR: modules Perl core manquants"; exit 1; }

# Creer le dossier hooks s'il n'existe pas
if [ ! -d "$HOOKS_DIR" ]; then
  echo "[WARN] $HOOKS_DIR n'existe pas — creation..."
  mkdir -p "$HOOKS_DIR"
fi

# Backup original
if [ -f "$HOOKS_DIR/claude-island-state.py" ]; then
  cp "$HOOKS_DIR/claude-island-state.py" "$HOOKS_DIR/claude-island-state.py.backup"
  echo "[OK] Backup: claude-island-state.py.backup"
fi

# Copier les scripts
cp "$SCRIPT_DIR/hooks/claude-island-state-fast.sh" "$HOOKS_DIR/"
cp "$SCRIPT_DIR/hooks/claude-island-state-fast.pl" "$HOOKS_DIR/"
chmod +x "$HOOKS_DIR/claude-island-state-fast.sh"
chmod +x "$HOOKS_DIR/claude-island-state-fast.pl"
echo "[OK] Scripts installes dans $HOOKS_DIR"

# Mettre a jour settings.json avec jq (remplacement structurel)
if [ -f "$SETTINGS" ] && command -v jq >/dev/null 2>&1; then
  cp "$SETTINGS" "$SETTINGS.backup"

  jq 'walk(
    if type == "string" and (. == "python3 ~/.claude/hooks/claude-island-state.py"
                          or . == "python3 ~\\/.claude\\/hooks\\/claude-island-state.py")
    then "bash ~/.claude/hooks/claude-island-state-fast.sh"
    else .
    end
  )' "$SETTINGS.backup" > "$SETTINGS"

  # Valider le JSON
  if ! jq empty "$SETTINGS" 2>/dev/null; then
    echo "[ERREUR] settings.json corrompu — restauration du backup"
    cp "$SETTINGS.backup" "$SETTINGS"
    exit 1
  fi

  echo "[OK] settings.json mis a jour (backup: settings.json.backup)"
else
  echo "[WARN] Modifier settings.json manuellement :"
  echo "  Remplacer: python3 ~/.claude/hooks/claude-island-state.py"
  echo "  Par:       bash ~/.claude/hooks/claude-island-state-fast.sh"
fi

echo ""
echo "=== Installation terminee ==="
echo "Redemarrer Claude Code pour appliquer."
echo ""
echo "Desinstallation:"
echo "  cp $HOOKS_DIR/claude-island-state.py.backup $HOOKS_DIR/claude-island-state.py"
echo "  cp $SETTINGS.backup $SETTINGS"
