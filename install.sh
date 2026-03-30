#!/usr/bin/env bash
# install.sh — Installe le hook optimise pour Claude Island
# ─────────────────────────────────────────────────────────────────────────────
set -e

HOOKS_DIR="$HOME/.claude/hooks"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "=== Claude Island Hook — Installation ==="
echo ""

# Verifier les prerequis
command -v perl >/dev/null 2>&1 || { echo "ERREUR: perl requis (pre-installe sur macOS)"; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "ERREUR: jq requis (brew install jq)"; exit 1; }
perl -e 'use JSON::PP' 2>/dev/null || { echo "ERREUR: JSON::PP requis (normalement en core Perl)"; exit 1; }

# Backup de l'original
if [ -f "$HOOKS_DIR/claude-island-state.py" ]; then
  cp "$HOOKS_DIR/claude-island-state.py" "$HOOKS_DIR/claude-island-state.py.backup"
  echo "[OK] Backup: claude-island-state.py.backup"
fi

# Copier les scripts optimises
cp "$SCRIPT_DIR/hooks/claude-island-state-fast.sh" "$HOOKS_DIR/"
cp "$SCRIPT_DIR/hooks/claude-island-state-fast.pl" "$HOOKS_DIR/"
chmod +x "$HOOKS_DIR/claude-island-state-fast.sh"
chmod +x "$HOOKS_DIR/claude-island-state-fast.pl"
echo "[OK] Scripts installes dans $HOOKS_DIR"

# Mettre a jour settings.json
SETTINGS="$HOME/.claude/settings.json"
if [ -f "$SETTINGS" ]; then
  # Remplacer toutes les references au script Python par le script bash
  if command -v sed >/dev/null 2>&1; then
    sed -i.backup 's|python3 ~\/.claude\/hooks\/claude-island-state.py|bash ~/.claude/hooks/claude-island-state-fast.sh|g' "$SETTINGS"
    echo "[OK] settings.json mis a jour (backup: settings.json.backup)"
  else
    echo "[WARN] sed non disponible — modifier settings.json manuellement"
    echo "       Remplacer: python3 ~/.claude/hooks/claude-island-state.py"
    echo "       Par:       bash ~/.claude/hooks/claude-island-state-fast.sh"
  fi
fi

echo ""
echo "=== Installation terminee ==="
echo "Redemarrer Claude Code pour appliquer les changements."
echo ""
echo "Pour revenir a l'original:"
echo "  cp $HOOKS_DIR/claude-island-state.py.backup $HOOKS_DIR/claude-island-state.py"
echo "  # Et restaurer settings.json.backup"
