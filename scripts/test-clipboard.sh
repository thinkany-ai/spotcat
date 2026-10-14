#!/bin/bash
# Runs an isolated WebKit fixture; never reads real clipboard history or settings.
set -euo pipefail
cd "$(dirname "$0")/.."
TEST_DIR="$PWD/.build/clipboard-view-tests"
mkdir -p "$TEST_DIR"
python3 - <<'PY'
from pathlib import Path
import shutil
root = Path('.build/clipboard-view-tests')
source = Path('Resources/extensions/clipboard')
for name in ['main.js', 'style.css']:
    shutil.copy2(source / name, root / name)
for name in ['mock.js', 'tests.js']:
    shutil.copy2(Path('Tests/ClipboardView') / name, root / name)
messages = (source / 'locales/zh-Hans.json').read_text()
html = (source / 'index.html').read_text().replace('<script src="main.js"></script>', '<script>window.fixtureMessages=' + messages + ';</script>\n<script src="mock.js"></script>\n<script src="main.js"></script>')
(root / 'index.html').write_text(html)
PY
node --check Resources/extensions/clipboard/main.js
swiftc Sources/Spotcat/Builtin/ClipboardShelfLayout.swift Tests/ClipboardShelf/main.swift -o "$TEST_DIR/test-layout"
"$TEST_DIR/test-layout"
swiftc Tests/ClipboardView/run-webkit.swift -o "$TEST_DIR/test-webkit"
"$TEST_DIR/test-webkit" "$TEST_DIR" "${1:-1200}" "${2:-466}" "${3:-}"
