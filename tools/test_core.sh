#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
build_dir=$(mktemp -d /tmp/bl616-ios-tests.XXXXXX)
"${CC:-cc}" -std=c11 -Wall -Wextra -Werror -g -O1 -fsanitize=address,undefined \
    -fno-omit-frame-pointer -IBL616Camera/Core \
    BL616Camera/Core/HBProtocol.c tests/test_protocol.c -o "$build_dir/test_protocol"
ASAN_OPTIONS=detect_leaks=0 "$build_dir/test_protocol"
python3 tools/generate_project.py --check
python3 - <<'PY'
import plistlib
from pathlib import Path
p=plistlib.loads(Path('BL616Camera/Resources/Info.plist').read_bytes())
assert p['NSLocalNetworkUsageDescription']
assert p['CFBundleDisplayName'] == 'BL616 摄像板'
print('Project generation and Info.plist checks passed')
PY
