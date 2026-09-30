#!/usr/bin/env bash
# One-time setup: the private Python Kertas uses for text editing, compressing,
# Word export and OCR text layers. Lives in ~/Library/Application Support/Kertas.
set -euo pipefail
DIR="$HOME/Library/Application Support/Kertas"
mkdir -p "$DIR"
[[ -x "$DIR/venv/bin/python" ]] || python3 -m venv "$DIR/venv"
"$DIR/venv/bin/pip" install -q --upgrade pymupdf pdf2docx
echo "→ ready: $("$DIR/venv/bin/python" -c 'import pymupdf; print("PyMuPDF", pymupdf.VersionBind)')"
