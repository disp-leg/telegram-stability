#!/bin/bash
# apply-patch.sh — Apply singleton lock patch to telegram plugin
# Safe to re-run — checks if already applied

CACHE_DIR="$HOME/.claude/plugins/cache/claude-plugins-official/telegram"
MARKET_DIR="$HOME/.claude/plugins/marketplaces/claude-plugins-official/external_plugins/telegram"

apply_to() {
  local dir="$1"
  local file="$dir/server.ts"
  
  if [ ! -f "$file" ]; then
    echo "  ⚠️  $file not found"
    return
  fi
  
  if grep -q "SINGLETON LOCK" "$file" 2>/dev/null; then
    echo "  ✅ Already patched: $file"
    return
  fi
  
  # Apply patch: insert after "const INBOX_DIR" line
  local patch_content
  patch_content=$(cat << 'PATCH'

// ── SINGLETON LOCK ─────────────────────────────────────────────────────
// Only one telegram bot should poll per token. Bind a Unix domain socket
// as an atomic lock — if another instance is alive, exit immediately.
// See: https://github.com/anthropics/claude-code/issues/38098
import { createServer as createNetServer, createConnection } from 'net'

const LOCK_SOCKET = join(STATE_DIR, 'telegram.sock')

async function acquireSingletonLock(): Promise<boolean> {
  if (existsSync(LOCK_SOCKET)) {
    const alive = await new Promise<boolean>(resolve => {
      const client = createConnection(LOCK_SOCKET)
      client.on('connect', () => { client.destroy(); resolve(true) })
      client.on('error', () => resolve(false))
      setTimeout(() => { client.destroy(); resolve(false) }, 500)
    })
    if (alive) {
      process.stderr.write(
        `telegram channel: another instance is running (socket lock held), exiting\n`,
      )
      return false
    }
    try { unlinkSync(LOCK_SOCKET) } catch {}
  }

  return new Promise(resolve => {
    const lockServer = createNetServer()
    lockServer.on('error', (err: NodeJS.ErrnoException) => {
      if (err.code === 'EADDRINUSE') {
        process.stderr.write('telegram channel: lock socket in use, exiting\n')
        resolve(false)
        return
      }
      process.stderr.write(`telegram channel: lock warning: ${err.message}\n`)
      resolve(true)
    })
    lockServer.listen(LOCK_SOCKET, () => {
      process.stderr.write(`telegram channel: singleton lock acquired (PID ${process.pid})\n`)
      resolve(true)
    })
    const cleanup = () => { try { unlinkSync(LOCK_SOCKET) } catch {} }
    process.on('exit', cleanup)
  })
}

if (!(await acquireSingletonLock())) {
  process.exit(0)
}
// ── END SINGLETON LOCK ─────────────────────────────────────────────────
PATCH
)

  # Use python for reliable insertion after the INBOX_DIR line
  python3 -c "
import sys
with open('$file') as f:
    content = f.read()
marker = \"const INBOX_DIR = join(STATE_DIR, 'inbox')\"
if marker not in content:
    print('  ❌ Could not find insertion point in $file')
    sys.exit(1)
patched = content.replace(marker, marker + '''$patch_content''')
with open('$file', 'w') as f:
    f.write(patched)
print('  ✅ Patched: $file')
"
}

echo "Applying singleton lock patch..."
echo ""

# Apply to cache version
VER=$(ls -1 "$CACHE_DIR" 2>/dev/null | sort -V | tail -1)
if [ -n "$VER" ]; then
  echo "Cache ($VER):"
  apply_to "$CACHE_DIR/$VER"
fi

# Apply to marketplace version
echo "Marketplace:"
apply_to "$MARKET_DIR"

echo ""
echo "Done. Restart Claude Code or run /mcp to pick up the patch."
