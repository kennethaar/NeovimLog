#!/data/data/com.termux/files/usr/bin/bash
# NeovimLog Termux Setup Script
# Run this once after cloning the repo to Termux.

set -e

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
NVIM_CONFIG="$HOME/.config/nvim"
VAULT_PATH="$HOME/storage/shared/Documents/Logseq/QAIA-Clean"

echo "=== NeovimLog Termux Setup ==="
echo ""

# ── 1. Shared storage ─────────────────────────────────────────────────
echo "[1/5] Setting up shared storage access..."
if [ ! -d "$HOME/storage/shared" ]; then
  echo "    Running termux-setup-storage (grant permission when prompted)..."
  termux-setup-storage
  # Wait a moment for storage to be mounted
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

# ── 5. Vault directory ────────────────────────────────────────────────
echo "[5/5] Checking vault path..."
if [ -d "$VAULT_PATH" ]; then
  echo "    Vault found: $VAULT_PATH"
else
  echo "    Vault NOT found at: $VAULT_PATH"
  echo ""
  echo "    Create it now? This will make an empty vault structure."
  read -r -p "    [y/N] " choice
  case "$choice" in
    y|Y)
      mkdir -p "$VAULT_PATH/journals" "$VAULT_PATH/pages"
      echo "    Created vault at $VAULT_PATH"
      ;;
    *)
      echo "    Skipped. Create the vault manually or sync Logseq first."
      ;;
  esac
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
