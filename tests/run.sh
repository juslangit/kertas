#!/usr/bin/env bash
# Runs every headless check: the Python helper, then the app's Swift side.
set -euo pipefail
cd "$(dirname "$0")/.."
PY="$HOME/Library/Application Support/Kertas/venv/bin/python"
echo "== helper"
"$PY" tests/test_helper.py
echo; echo "== app"
mkdir -p .build/checks
# Top-level code is only allowed in a file called main.swift.
cp tests/app_checks.swift .build/checks/main.swift
swiftc -O -o .build/checks/app_checks .build/checks/main.swift Sources/Kertas/Convert.swift Sources/Kertas/Helper.swift
KERTAS_HELPER="$PWD/tools/helper.py" .build/checks/app_checks
