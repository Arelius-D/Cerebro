#!/bin/bash

INSTALL_DIR="$HOME/cerebro"
REPO_RAW="https://raw.githubusercontent.com/Arelius-D/Cerebro/main"

download_file() {
    local url="$1"
    local dest="$2"
    
    if command -v curl >/dev/null 2>&1; then
        curl -sL "$url" -o "$dest"
    elif command -v wget >/dev/null 2>&1; then
        wget -qO "$dest" "$url"
    else
        echo "❌ Error: Neither curl nor wget found. Please install one."
        exit 1
    fi
}

echo "🧠 Installing Cerebro to $INSTALL_DIR..."

mkdir -p "$INSTALL_DIR"

echo "Downloading script..."
download_file "$REPO_RAW/cerebro.sh" "$INSTALL_DIR/cerebro.sh"
chmod +x "$INSTALL_DIR/cerebro.sh"

if [ -f "$INSTALL_DIR/cerebro.cfg" ]; then
    echo "ℹ️  Existing configuration found. Skipping config download."
else
    echo "Downloading default configuration..."
    download_file "$REPO_RAW/cerebro.cfg" "$INSTALL_DIR/cerebro.cfg"
fi

mkdir -p "$INSTALL_DIR/assets"

echo ""
echo "✅ Installation Complete."
echo "1. Edit config: nano $INSTALL_DIR/cerebro.cfg"
echo "2. Run once:    sudo $INSTALL_DIR/cerebro.sh"
