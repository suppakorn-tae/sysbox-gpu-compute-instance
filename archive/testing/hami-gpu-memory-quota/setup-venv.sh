#!/usr/bin/env bash
set -euo pipefail

VENV_DIR="$(pwd)/.venv"
PYTHON="${PYTHON:-python3}"

# Create virtual environment
"$PYTHON" -m venv "$VENV_DIR"

# Install PyTorch with CUDA 13.0 support
"$VENV_DIR/bin/python" -m pip install --upgrade pip
"$VENV_DIR/bin/python" -m pip install torch \
  --index-url https://download.pytorch.org/whl/cu130

# Verify installation
"$VENV_DIR/bin/python" -c '
import torch
print("PyTorch:", torch.__version__)
print("CUDA build:", torch.version.cuda)
print("CUDA available:", torch.cuda.is_available())
if torch.cuda.is_available():
    print("GPU:", torch.cuda.get_device_name(0))
'