#!/usr/bin/env bash
# telegram-singleton.sh — Apply singleton lock patch to telegram plugin.
# Idempotent. Run after plugin updates to re-apply.
# Uses a template file (singleton-lock-block.ts) to avoid escaping issues.

PATCH_DIR="$(cd "$(dirname "$0")" && pwd)"
BLOCK_FILE="$PATCH_DIR/singleton-lock-block.ts"
CACHE_DIR="$HOME/.claude/plugins/cache/claude-plugins-official/telegram"
MARKET_DIR="$HOME/.claude/plugins/marketplaces/claude-plugins-official/external_plugins/telegram"

if [ ! -f "$BLOCK_FILE" ]; then
  echo "  [!] singleton-lock-block.ts not found at $BLOCK_FILE" >&2
  exit 1
fi

apply_to() {
  local file="$1"
  [ ! -f "$file" ] && return

  # Idempotency check
  if grep -q "SINGLETON LOCK" "$file" 2>/dev/null; then
    return
  fi

  python3 -c "
import sys

with open('$file') as f:
    content = f.read()

with open('$BLOCK_FILE') as f:
    block = f.read()

# 1. Add existsSync and unlinkSync to fs import if missing
old_import = \"import { readFileSync, writeFileSync, mkdirSync, readdirSync, rmSync, statSync, renameSync, realpathSync, chmodSync } from 'fs'\"
new_import = \"import { readFileSync, writeFileSync, mkdirSync, readdirSync, rmSync, statSync, renameSync, realpathSync, chmodSync, existsSync, unlinkSync } from 'fs'\"
if old_import in content:
    content = content.replace(old_import, new_import)

# 2. Insert lock block after INBOX_DIR line
marker = \"const INBOX_DIR = join(STATE_DIR, 'inbox')\"
if marker not in content:
    print('  [!] insertion point not found', file=sys.stderr)
    sys.exit(1)
content = content.replace(marker, marker + '\n' + block)

# 3. Add releaseSingletonLock() to shutdown
old_shutdown = 'shuttingDown = true'
new_shutdown = 'shuttingDown = true\n  // Release singleton lock FIRST (Risk 4 fix).\n  releaseSingletonLock()'
content = content.replace(old_shutdown, new_shutdown, 1)

with open('$file', 'w') as f:
    f.write(content)
print('  [=] singleton lock patched: $file')
" 2>/dev/null
}

# Patch cache
VER=$(ls -1 "$CACHE_DIR" 2>/dev/null | sort -V | tail -1)
[ -n "$VER" ] && apply_to "$CACHE_DIR/$VER/server.ts"

# Patch marketplace
apply_to "$MARKET_DIR/server.ts"
