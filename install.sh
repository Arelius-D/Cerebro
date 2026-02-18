#!/bin/bash
# Cerebro Installer

INSTALL_DIR="$HOME/cerebro"
REPO_RAW="https://raw.githubusercontent.com/Arelius-D/Cerebro/main"

echo "🧠 Installing Cerebro to $INSTALL_DIR..."

# 1. Create directory
mkdir -p "$INSTALL_DIR"

# 2. Download Script
echo "Downloading script..."
curl -sL "$REPO_RAW/cerebro.sh" -o "$INSTALL_DIR/cerebro.sh"
chmod +x "$INSTALL_DIR/cerebro.sh"

# 3. Download Config Template (Only if missing)
if [ -f "$INSTALL_DIR/cerebro.cfg" ]; then
    echo "ℹ️  Existing configuration found. Skipping config download."
else
    echo "Downloading default configuration..."
    curl -sL "$REPO_RAW/cerebro.cfg" -o "$INSTALL_DIR/cerebro.cfg"
fi

# 4. Create assets dir
mkdir -p "$INSTALL_DIR/assets"

echo ""
echo "✅ Installation Complete."
echo "1. Edit config: nano $INSTALL_DIR/cerebro.cfg"
echo "2. Run once:    $INSTALL_DIR/cerebro.sh"
