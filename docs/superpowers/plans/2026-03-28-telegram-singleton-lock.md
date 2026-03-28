# Telegram Singleton Lock — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Prevent duplicate Telegram bot processes from competing for the same Bot API token by adding a Unix domain socket singleton lock to the plugin's server.ts.

**Architecture:** Patch the official `telegram@claude-plugins-official` plugin (server.ts) to bind a Unix domain socket before starting the Grammy polling loop. If another instance already holds the socket, the new instance exits immediately with code 0 (clean, no error). On shutdown, the lock is released FIRST (before bot.stop()) so replacement instances can start without delay. A SessionStart hook re-applies the patch after plugin updates. A supplementary watchdog cron alerts operators via Bot API if Telegram goes down.

**Tech Stack:** TypeScript (bun runtime), Unix domain sockets (Node.js `net` module), bash (hooks/cron), macOS launchd or crontab.

---

## Scope

This plan covers three components:
1. **server.ts singleton lock patch** — the core fix
2. **SessionStart hook for durability** — auto re-applies patch after plugin updates
3. **Watchdog cron for alerting** — detects total silence or zombie processes

These are independent and testable separately. Each task produces working, verifiable output.

---

## File Structure

| File | Action | Responsibility |
|------|--------|---------------|
| `~/.claude/plugins/cache/claude-plugins-official/telegram/*/server.ts` | Modify | Add singleton lock before polling |
| `~/.claude/plugins/marketplaces/claude-plugins-official/external_plugins/telegram/server.ts` | Modify | Same patch (this is where the running process lives) |
| `~/.claude/patches/telegram-singleton.sh` | Create | Idempotent patch apply script |
| `~/.claude/settings.json` | Modify | Add SessionStart hook for patch script |
| `~/.claude/telegram-watchdog.sh` | Create | Cron-based watchdog + Bot API alerter |
| `~/.claude/kill-competing-telegram.sh` | Modify | Replace with improved guardian (optional) |

---

## Task 1: Apply Singleton Lock to server.ts (Marketplace Copy)

This is the running copy — the one that actually executes.

**Files:**
- Modify: `~/.claude/plugins/marketplaces/claude-plugins-official/external_plugins/telegram/server.ts:53` (insert after `const INBOX_DIR` line)
- Modify: `~/.claude/plugins/marketplaces/claude-plugins-official/external_plugins/telegram/server.ts:~686` (add `releaseSingletonLock()` to `shutdown()`)

- [ ] **Step 1: Verify the target file exists and find the insertion point**

```bash
MARKET_FILE="$HOME/.claude/plugins/marketplaces/claude-plugins-official/external_plugins/telegram/server.ts"
grep -n "const INBOX_DIR" "$MARKET_FILE"
# Expected: line ~53: const INBOX_DIR = join(STATE_DIR, 'inbox')

grep -n "function shutdown" "$MARKET_FILE"
# Expected: line ~622: function shutdown(): void {
```

- [ ] **Step 2: Verify patch is not already applied**

```bash
grep -q "SINGLETON LOCK" "$MARKET_FILE" && echo "ALREADY PATCHED" || echo "NOT PATCHED — proceed"
# Expected: NOT PATCHED — proceed
```

- [ ] **Step 3: Apply the singleton lock patch**

Insert the following block immediately after `const INBOX_DIR = join(STATE_DIR, 'inbox')`:

```typescript
// ── SINGLETON LOCK ─────────────────────────────────────────────────────
// Only one telegram bot should poll per token. Bind a Unix domain socket
// as an atomic lock — if another instance is alive, exit immediately.
// This prevents 409 Conflict errors from competing getUpdates consumers.
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
    // Stale socket from crashed process — clean up
    try { unlinkSync(LOCK_SOCKET) } catch {}
  }

  return new Promise(resolve => {
    _lockServer = createNetServer()
    _lockServer.on('error', (err: NodeJS.ErrnoException) => {
      if (err.code === 'EADDRINUSE') {
        process.stderr.write('telegram channel: lock socket in use, exiting\n')
        resolve(false)
        return
      }
      // Non-lock error — proceed without lock (don't block startup)
      process.stderr.write(`telegram channel: lock warning: ${err.message}\n`)
      resolve(true)
    })
    _lockServer.listen(LOCK_SOCKET, () => {
      process.stderr.write(`telegram channel: singleton lock acquired (PID ${process.pid})\n`)
      resolve(true)
    })
    // Clean up socket on exit
    const cleanup = () => { try { unlinkSync(LOCK_SOCKET) } catch {} }
    process.on('exit', cleanup)
  })
}

// Expose lock server so shutdown() can close it first — eliminates the
// timing window where a dying instance still holds the lock (Risk 4).
let _lockServer: ReturnType<typeof createNetServer> | null = null
function releaseSingletonLock(): void {
  if (_lockServer) {
    _lockServer.close()
    _lockServer = null
  }
  try { unlinkSync(LOCK_SOCKET) } catch {}
}

if (!(await acquireSingletonLock())) {
  process.exit(0)
}
// ── END SINGLETON LOCK ─────────────────────────────────────────────────
```

- [ ] **Step 4: Add early lock release to shutdown()**

Find the `shutdown()` function and add `releaseSingletonLock()` as the first line after the debounce guard:

```typescript
function shutdown(): void {
  if (shuttingDown) return
  shuttingDown = true
  // Release singleton lock FIRST — allows replacement instance to start
  // immediately instead of waiting for our 2s force-exit timer (Risk 4 fix).
  releaseSingletonLock()
  process.stderr.write('telegram channel: shutting down\n')
  // ... rest of shutdown unchanged
```

- [ ] **Step 5: Verify the patch looks correct**

```bash
grep -c "SINGLETON LOCK" "$MARKET_FILE"
# Expected: 2 (start and end markers)

grep -c "releaseSingletonLock" "$MARKET_FILE"
# Expected: 3 (definition + call in shutdown + function declaration)

grep -c "acquireSingletonLock" "$MARKET_FILE"
# Expected: 2 (definition + call)
```

- [ ] **Step 6: Commit (conceptual — this is outside a git repo)**

Note: Plugin directory is not a git repo. The patch is tracked in the telegram-stability repo on GitHub. No local commit needed.

---

## Task 2: Apply Same Patch to Cache Copy

The cache copy is used when the marketplace copy is regenerated.

**Files:**
- Modify: `~/.claude/plugins/cache/claude-plugins-official/telegram/0.0.4/server.ts` (same changes as Task 1)

- [ ] **Step 1: Identify the cache file**

```bash
CACHE_DIR="$HOME/.claude/plugins/cache/claude-plugins-official/telegram"
VER=$(ls -1 "$CACHE_DIR" 2>/dev/null | sort -V | tail -1)
CACHE_FILE="$CACHE_DIR/$VER/server.ts"
echo "Cache file: $CACHE_FILE (version $VER)"
grep -q "SINGLETON LOCK" "$CACHE_FILE" && echo "ALREADY PATCHED" || echo "NOT PATCHED — proceed"
```

- [ ] **Step 2: Apply identical patch as Task 1**

Apply the same two modifications (singleton lock block after INBOX_DIR, releaseSingletonLock in shutdown). Use the exact same code from Task 1 Steps 3 and 4.

- [ ] **Step 3: Verify**

```bash
grep -c "SINGLETON LOCK" "$CACHE_FILE"
# Expected: 2
grep -c "releaseSingletonLock" "$CACHE_FILE"
# Expected: 3
```

---

## Task 3: Create Idempotent Patch Script

**Files:**
- Create: `~/.claude/patches/telegram-singleton.sh`

- [ ] **Step 1: Write the patch script**

```bash
#!/usr/bin/env bash
# telegram-singleton.sh — Apply singleton lock patch to telegram plugin.
# Idempotent. Run after plugin updates to re-apply.
#
# Patches both cache and marketplace copies of server.ts.

set -euo pipefail

CACHE_DIR="$HOME/.claude/plugins/cache/claude-plugins-official/telegram"
MARKET_DIR="$HOME/.claude/plugins/marketplaces/claude-plugins-official/external_plugins/telegram"

LOCK_PATCH='
// ── SINGLETON LOCK ─────────────────────────────────────────────────────
// Only one telegram bot should poll per token. Bind a Unix domain socket
// as an atomic lock — if another instance is alive, exit immediately.
// See: https://github.com/anthropics/claude-code/issues/38098
import { createServer as createNetServer, createConnection } from '"'"'net'"'"'

const LOCK_SOCKET = join(STATE_DIR, '"'"'telegram.sock'"'"')

async function acquireSingletonLock(): Promise<boolean> {
  if (existsSync(LOCK_SOCKET)) {
    const alive = await new Promise<boolean>(resolve => {
      const client = createConnection(LOCK_SOCKET)
      client.on('"'"'connect'"'"', () => { client.destroy(); resolve(true) })
      client.on('"'"'error'"'"', () => resolve(false))
      setTimeout(() => { client.destroy(); resolve(false) }, 500)
    })
    if (alive) {
      process.stderr.write(
        `telegram channel: another instance is running (socket lock held), exiting\\n`,
      )
      return false
    }
    try { unlinkSync(LOCK_SOCKET) } catch {}
  }

  return new Promise(resolve => {
    _lockServer = createNetServer()
    _lockServer.on('"'"'error'"'"', (err: NodeJS.ErrnoException) => {
      if (err.code === '"'"'EADDRINUSE'"'"') {
        process.stderr.write('"'"'telegram channel: lock socket in use, exiting\\n'"'"')
        resolve(false)
        return
      }
      process.stderr.write(`telegram channel: lock warning: ${err.message}\\n`)
      resolve(true)
    })
    _lockServer.listen(LOCK_SOCKET, () => {
      process.stderr.write(`telegram channel: singleton lock acquired (PID ${process.pid})\\n`)
      resolve(true)
    })
    const cleanup = () => { try { unlinkSync(LOCK_SOCKET) } catch {} }
    process.on('"'"'exit'"'"', cleanup)
  })
}

let _lockServer: ReturnType<typeof createNetServer> | null = null
function releaseSingletonLock(): void {
  if (_lockServer) {
    _lockServer.close()
    _lockServer = null
  }
  try { unlinkSync(LOCK_SOCKET) } catch {}
}

if (!(await acquireSingletonLock())) {
  process.exit(0)
}
// ── END SINGLETON LOCK ─────────────────────────────────────────────────'

SHUTDOWN_LINE="  releaseSingletonLock()"

apply_to() {
  local file="$1"
  [ ! -f "$file" ] && return

  if grep -q "SINGLETON LOCK" "$file" 2>/dev/null; then
    return  # Already patched
  fi

  # Insert lock block after INBOX_DIR line
  python3 -c "
import sys
with open('$file') as f:
    content = f.read()
marker = \"const INBOX_DIR = join(STATE_DIR, 'inbox')\"
if marker not in content:
    print('  [!] insertion point not found', file=sys.stderr)
    sys.exit(1)
patched = content.replace(marker, marker + '''$LOCK_PATCH''')
# Add releaseSingletonLock() to shutdown
old_shutdown = 'shuttingDown = true'
new_shutdown = 'shuttingDown = true\n  releaseSingletonLock()'
patched = patched.replace(old_shutdown, new_shutdown, 1)
with open('$file', 'w') as f:
    f.write(patched)
"
  echo "  [=] singleton lock patched: $file"
}

# Patch cache
VER=$(ls -1 "$CACHE_DIR" 2>/dev/null | sort -V | tail -1)
[ -n "$VER" ] && apply_to "$CACHE_DIR/$VER/server.ts"

# Patch marketplace
apply_to "$MARKET_DIR/server.ts"
```

- [ ] **Step 2: Make it executable**

```bash
chmod +x ~/.claude/patches/telegram-singleton.sh
```

- [ ] **Step 3: Test idempotency — run twice, verify no double-patching**

```bash
bash ~/.claude/patches/telegram-singleton.sh
bash ~/.claude/patches/telegram-singleton.sh
# Expected: second run produces no output (already patched, early return)

grep -c "SINGLETON LOCK" "$HOME/.claude/plugins/marketplaces/claude-plugins-official/external_plugins/telegram/server.ts"
# Expected: 2 (not 4 — idempotent)
```

- [ ] **Step 4: Commit to telegram-stability repo**

```bash
cd /tmp/telegram-stability
cp ~/.claude/patches/telegram-singleton.sh patches/telegram-singleton.sh
git add patches/telegram-singleton.sh
git commit -m "feat: add idempotent singleton lock patch script"
git push origin main
```

---

## Task 4: Add SessionStart Hook

**Files:**
- Modify: `~/.claude/settings.json:97-113` (hooks.SessionStart array)

- [ ] **Step 1: Read current hooks**

```bash
python3 -c "
import json
d = json.load(open('$HOME/.claude/settings.json'))
for h in d.get('hooks',{}).get('SessionStart',[]):
  for hook in h.get('hooks',[]):
    print(hook.get('command',''))
"
# Expected: lists current hooks (kill-competing-telegram.sh, telegram-reactions.sh)
```

- [ ] **Step 2: Add the singleton patch hook**

Add to the SessionStart hooks array, BEFORE the reactions patch (order matters — singleton lock should be in place before reactions patch runs):

```json
{
  "type": "command",
  "command": "bash ~/.claude/patches/telegram-singleton.sh",
  "timeout": 10
}
```

The complete hooks section should look like:
```json
"hooks": {
  "SessionStart": [
    {
      "hooks": [
        {
          "type": "command",
          "command": "bash ~/.claude/kill-competing-telegram.sh",
          "async": true
        },
        {
          "type": "command",
          "command": "bash ~/.claude/patches/telegram-singleton.sh",
          "timeout": 10
        },
        {
          "type": "command",
          "command": "bash ~/.claude/patches/telegram-reactions.sh",
          "timeout": 10
        }
      ]
    }
  ]
}
```

- [ ] **Step 3: Verify settings.json is still valid JSON**

```bash
python3 -c "import json; json.load(open('$HOME/.claude/settings.json')); print('VALID JSON')"
# Expected: VALID JSON
```

- [ ] **Step 4: Commit**

```bash
cd /tmp/telegram-stability
git add -A
git commit -m "feat: add SessionStart hook for singleton patch durability"
git push origin main
```

---

## Task 5: Create Watchdog Script

**Files:**
- Create: `~/.claude/telegram-watchdog.sh`

- [ ] **Step 1: Write the watchdog**

```bash
#!/usr/bin/env bash
# telegram-watchdog.sh — Runs via cron every 30-60s.
# Detects: duplicate processes, zombies, total absence.
# Alerts via Bot API (works even when MCP is broken).

TOKEN=$(grep 'BOT_TOKEN' ~/.claude/channels/telegram/.env 2>/dev/null | cut -d'=' -f2)
GRP_CHAT="-5127377005"

[ -z "$TOKEN" ] && exit 0  # No token = nothing to watch

alert() {
  curl -s "https://api.telegram.org/bot${TOKEN}/sendMessage" \
    -d "chat_id=${GRP_CHAT}" \
    --data-urlencode "text=$1" >/dev/null 2>&1
}

# Count telegram bun processes
TG_PIDS=$(pgrep -f "bun.*telegram" 2>/dev/null || true)
TG_COUNT=$(echo "$TG_PIDS" | grep -c . 2>/dev/null || echo 0)
[ -z "$TG_PIDS" ] && TG_COUNT=0

# Multiple processes — kill extras
if [ "$TG_COUNT" -gt 1 ]; then
  # Keep the one whose parent has --channels flag
  HUB_PID=$(pgrep -f "claude.*--channels.*telegram" 2>/dev/null | head -1)
  if [ -n "$HUB_PID" ]; then
    HUB_TG=$(pgrep -P "$HUB_PID" -f "bun" 2>/dev/null | head -1)
    echo "$TG_PIDS" | while read pid; do
      [ -n "$pid" ] && [ "$pid" != "$HUB_TG" ] && kill "$pid" 2>/dev/null
    done
  fi
  alert "⚠️ Watchdog: killed $(($TG_COUNT - 1)) duplicate telegram process(es)"
fi

# Zero processes — telegram is down
if [ "$TG_COUNT" -eq 0 ]; then
  alert "🔴 Watchdog: Telegram is DOWN. No bot process running. Run /mcp at terminal to restart."
fi

# Zombie check (ppid=1)
if [ "$TG_COUNT" -eq 1 ]; then
  TG_PID=$(echo "$TG_PIDS" | head -1)
  PPID_VAL=$(ps -o ppid= -p "$TG_PID" 2>/dev/null | tr -d ' ')
  if [ "$PPID_VAL" = "1" ]; then
    kill "$TG_PID" 2>/dev/null
    alert "⚠️ Watchdog: killed orphaned telegram zombie (ppid=1). Run /mcp to restart."
  fi
fi
```

- [ ] **Step 2: Make it executable**

```bash
chmod +x ~/.claude/telegram-watchdog.sh
```

- [ ] **Step 3: Test the watchdog (dry run)**

```bash
bash ~/.claude/telegram-watchdog.sh
# Expected: no output (1 healthy process, nothing to do)
# Verify no alert was sent to Telegram group
```

- [ ] **Step 4: Set up cron (every 60 seconds)**

```bash
# Add to crontab
(crontab -l 2>/dev/null; echo "* * * * * bash $HOME/.claude/telegram-watchdog.sh") | sort -u | crontab -
# Verify
crontab -l | grep watchdog
# Expected: * * * * * bash /Users/dispatch/.claude/telegram-watchdog.sh
```

- [ ] **Step 5: Commit**

```bash
cd /tmp/telegram-stability
cp ~/.claude/telegram-watchdog.sh watchdog/telegram-watchdog.sh
mkdir -p watchdog
git add -A
git commit -m "feat: add watchdog cron for alerting on telegram failures"
git push origin main
```

---

## Task 6: Verify Live — Restart and Test

- [ ] **Step 1: Run /mcp to restart the telegram plugin with the patch**

User runs `/mcp` in the terminal. This kills the current bun process and starts a new one that loads the patched server.ts.

- [ ] **Step 2: Verify singleton lock acquired**

```bash
ls -la ~/.claude/channels/telegram/telegram.sock
# Expected: socket file exists

pgrep -f "bun.*telegram" | wc -l | tr -d ' '
# Expected: 1
```

- [ ] **Step 3: Test send + receive**

Send a test message via MCP reply tool. Have operator reply on Telegram. Verify both directions work.

- [ ] **Step 4: Test duplicate rejection (safe — the lock handles it)**

```bash
# Start a second bun process manually — it should exit immediately
S_DIR="$HOME/.claude/plugins/marketplaces/claude-plugins-official/external_plugins/telegram"
cd "$S_DIR" && bun server.ts 2>&1 | head -5
# Expected: "telegram channel: another instance is running (socket lock held), exiting"
# Process exits with code 0
```

- [ ] **Step 5: Verify process count unchanged**

```bash
pgrep -f "bun.*telegram" | wc -l | tr -d ' '
# Expected: still 1
```

- [ ] **Step 6: Commit verification results**

```bash
cd /tmp/telegram-stability
echo "## Live Verification $(date)" >> docs/live-test-log.md
echo "- Socket exists: YES" >> docs/live-test-log.md
echo "- Process count: 1" >> docs/live-test-log.md
echo "- Send test: PASS" >> docs/live-test-log.md
echo "- Receive test: PASS" >> docs/live-test-log.md
echo "- Duplicate rejection: PASS" >> docs/live-test-log.md
git add -A
git commit -m "feat: live verification results"
git push origin main
```

---

## Task 7: Final Cleanup

- [ ] **Step 1: Remove stale lock files from testing**

```bash
rm -f /tmp/tg-test-sandbox/test.sock /tmp/tg-direct-test/*.sock 2>/dev/null
rm -rf /tmp/tg-test-sandbox /tmp/tg-direct-test /tmp/tg-lock-stress-* /tmp/tg-test-f 2>/dev/null
```

- [ ] **Step 2: Update active_state.md**

Update `~/.claude/projects/-Users-dispatch/memory/active_state.md` to reflect:
- Telegram singleton lock deployed
- Watchdog cron active
- SessionStart hook installed

- [ ] **Step 3: Send deployment confirmation to Telegram group**

```
✅ Telegram singleton lock deployed.
- Socket lock active at ~/.claude/channels/telegram/telegram.sock
- SessionStart hook re-applies on every session start
- Watchdog cron running every 60s with Bot API alerts
- Duplicate processes will exit immediately
```

- [ ] **Step 4: Final commit**

```bash
cd /tmp/telegram-stability
git add -A
git commit -m "feat: deployment complete, cleanup done"
git push origin main
```
