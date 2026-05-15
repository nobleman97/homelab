#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VENV_DIR="$SCRIPT_DIR/.venv"

python3 -m venv "$VENV_DIR"

source "$VENV_DIR/bin/activate"

pip install --upgrade pip
pip install ansible requests netaddr

ansible-galaxy collection install community.proxmox ansible.utils

echo ""
echo "Ansible venv ready. Activate with:"
echo "  source $VENV_DIR/bin/activate"
