#!/bin/bash

# Assets directory path
ASSETS_DIR="KokoroAssets"
MODEL_FILE="$ASSETS_DIR/kokoro-v1_0.safetensors"
# VOICES_FILE="$ASSETS_DIR/voices.npz"
# CONFIG_FILE="$ASSETS_DIR/config.json"

BASE_URL="https://huggingface.co/mlx-community/Kokoro-82M-bf16/resolve/main"

echo "📦 Checking assets..."

mkdir -p "$ASSETS_DIR"

download_if_missing() {
    local file_path=$1
    local url=$2
    local name=$3

    if [ ! -f "$file_path" ]; then
        echo "⬇️ Downloading $name..."
        curl -L -o "$file_path" "$url"
        if [ $? -eq 0 ]; then
            echo "✅ $name downloaded successfully."
        else
            echo "❌ Failed to download $name."
            return 1
        fi
    else
        echo "✅ $name already exists."
    fi
}

download_if_missing "$MODEL_FILE" "$BASE_URL/kokoro-v1_0.safetensors" "Kokoro model (327MB)"
# download_if_missing "$VOICES_FILE" "$BASE_URL/voices.npz" "Voices (25MB)"
# download_if_missing "$CONFIG_FILE" "$BASE_URL/config.json" "Config"

echo "🚀 Ready to build Koro!"
