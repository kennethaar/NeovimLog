#!/data/data/com.termux/files/usr/bin/bash
# NeovimLog Termux Setup Script
# Run this once after cloning the repo to Termux.

set -e

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
NVIM_CONFIG="$HOME/.config/nvim"
VAULT_PATH_FILE="$HOME/.local/share/nvim/logseq_vault"

echo "=== NeovimLog Termux Setup ==="
echo ""

# ── 1. Shared storage ─────────────────────────────────────────────────
echo "[1/5] Setting up shared storage access..."
if [ ! -d "$HOME/storage/shared" ]; then
  echo "    Running termux-setup-storage (grant permission when prompted)..."
  termux-setup-storage
  sleep 2
else
  echo "    Storage already configured."
fi

# ── 2. System packages ────────────────────────────────────────────────
echo "[2/5] Installing packages (neovim, python, git)..."
pkg update -y -q
pkg install -y neovim python git

# ── 3. Python dependencies ────────────────────────────────────────────
echo "[3/5] Installing Python dependencies for calendar sync..."
pip install --quiet pytz icalendar recurring-ical-events

# ── 4. Link Neovim config ─────────────────────────────────────────────
echo "[4/5] Linking Neovim config..."
mkdir -p "$HOME/.config"

if [ -L "$NVIM_CONFIG" ]; then
  EXISTING=$(readlink "$NVIM_CONFIG")
  if [ "$EXISTING" = "$REPO_DIR" ]; then
    echo "    Already linked correctly."
  else
    echo "    Relinking from $EXISTING -> $REPO_DIR"
    rm "$NVIM_CONFIG"
    ln -s "$REPO_DIR" "$NVIM_CONFIG"
  fi
elif [ -d "$NVIM_CONFIG" ]; then
  echo "    WARNING: $NVIM_CONFIG is an existing directory, not a symlink."
  echo "    Backing it up to ${NVIM_CONFIG}.bak and linking this repo instead."
  mv "$NVIM_CONFIG" "${NVIM_CONFIG}.bak"
  ln -s "$REPO_DIR" "$NVIM_CONFIG"
else
  ln -s "$REPO_DIR" "$NVIM_CONFIG"
  echo "    Linked $NVIM_CONFIG -> $REPO_DIR"
fi

# ── 5. Vault path ─────────────────────────────────────────────────────
echo "[5/6] Setting vault path..."
echo ""

# Show current saved path if it exists
if [ -f "$VAULT_PATH_FILE" ]; then
  CURRENT_VAULT=$(cat "$VAULT_PATH_FILE")
  echo "    Current vault: $CURRENT_VAULT"
  read -r -p "    Change it? [y/N] " change
  if [ "$change" != "y" ] && [ "$change" != "Y" ]; then
    VAULT_PATH="$CURRENT_VAULT"
    echo "    Keeping: $VAULT_PATH"
  else
    VAULT_PATH=""
  fi
else
  VAULT_PATH=""
fi

# Ask for path if not set
if [ -z "$VAULT_PATH" ]; then
  echo "    Enter the full path to your vault folder."
  echo "    Example: /storage/emulated/0/Documents/QAIA Clean"
  echo "    (This is the folder that contains your 'journals' and 'pages' folders)"
  echo ""
  read -r -p "    Vault path: " VAULT_PATH
  VAULT_PATH="${VAULT_PATH%/}"  # strip trailing slash
fi

# Validate and optionally create
if [ -d "$VAULT_PATH" ]; then
  echo "    Vault found: $VAULT_PATH"
else
  echo ""
  echo "    Folder not found: $VAULT_PATH"
  read -r -p "    Create it now (with journals/ and pages/ folders)? [y/N] " choice
  case "$choice" in
    y|Y)
      mkdir -p "$VAULT_PATH/journals" "$VAULT_PATH/pages"
      echo "    Created: $VAULT_PATH"
      ;;
    *)
      echo "    Skipped. Make sure the folder exists before opening Neovim."
      ;;
  esac
fi

# Save the vault path
mkdir -p "$(dirname "$VAULT_PATH_FILE")"
printf '%s' "$VAULT_PATH" > "$VAULT_PATH_FILE"
echo "    Saved vault path to $VAULT_PATH_FILE"

# ── 6. URL opener (share-to-journal) ──────────────────────────────────
echo "[6/6] Installing termux-url-opener..."
mkdir -p "$HOME/bin"
TARGET="$HOME/bin/termux-url-opener"

if [ -L "$TARGET" ] && [ "$(readlink "$TARGET")" = "$REPO_DIR/termux-url-opener" ]; then
  echo "    Already installed."
else
  ln -sf "$REPO_DIR/termux-url-opener" "$TARGET"
  chmod +x "$REPO_DIR/termux-url-opener"
  echo "    Linked $TARGET -> $REPO_DIR/termux-url-opener"
fi

# ── Done ──────────────────────────────────────────────────────────────
echo ""
echo "=== Setup complete! ==="
echo ""
echo "Start Neovim with:  nvim"
echo ""
echo "On first run:"
echo "  - Opens today's journal automatically"
echo "  - Calendar sync requires ICS URL(s) — run :Caladd to add them"
echo "  - Set reminder lead time with :Calremind"
echo ""
echo "Vault path: $VAULT_PATH"
echo "Neovim config: $NVIM_CONFIG -> $REPO_DIR"
echo ""
echo "To change vault path later, re-run this script."
echo ""
echo "Share any URL to Termux and it will be appended to today's journal."
