# Telegram Singleton Lock — Implementation Plan (v2)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Prevent duplicate Telegram bot processes from competing for the same Bot API token by adding a Unix domain socket singleton lock to the plugin's server.ts.

**Architecture:** Patch the official `telegram@claude-plugins-official` plugin (server.ts) to bind a Unix domain socket before starting the Grammy polling loop. If another instance already holds the socket, the new instance exits immediately with code 0 (clean, no error). On shutdown, the lock is released FIRST (before bot.stop()) so replacement instances can start without delay. A SessionStart hook re-applies the patch after plugin updates. A supplementary watchdog cron alerts operators via Bot API if Telegram goes down.

**Tech Stack:** TypeScript (bun runtime), Unix domain sockets (Node.js `net` module), bash (hooks/cron), macOS crontab.

---

## Skills Used

| Skill | Where Applied | Why |
|-------|--------------|-----|
| **systematic-debugging** | Entire investigation phase (recon → validate → prototype) | Root cause analysis before proposing any fix. Phase 1-4 followed strictly. 5 prior failed fixes triggered "question architecture" rule. |
| **test-driven-development** | Tasks 1-5 below | Each task starts with a failing test that defines success, then implements to make it pass. |
| **writing-plans** | This document | Structured plan with bite-sized steps, exact file paths, complete code. |
| **verification-before-completion** | Task 7 below | Formal verification of all claims before marking deployment complete. No success claims without evidence. |

**Skills considered and not used:**
- **brainstorming** — Should have been used before the solution design phase (proposing 9 options was creative work). Skipped. Acknowledged as a process gap.
- **code-review** — Will be used after implementation if operator requests formal review.

---

## Scope

Three independent, testable components:
1. **server.ts singleton lock patch** — the core fix (Tasks 1-2)
2. **Durability layer** — patch script + SessionStart hook (Tasks 3-4)
3. **Alerting layer** — watchdog cron (Task 5)

Each produces working, verifiable output independently.

---

## File Structure

| File | Action | Responsibility |
|------|--------|---------------|
| `~/.claude/plugins/marketplaces/claude-plugins-official/external_plugins/telegram/server.ts` | Modify | Add singleton lock (running copy) |
| `~/.claude/plugins/cache/claude-plugins-official/telegram/*/server.ts` | Modify | Add singleton lock (cache copy) |
| `~/.claude/patches/telegram-singleton.sh` | Create | Idempotent patch apply script |
| `~/.claude/settings.json` | Modify | Add SessionStart hook |
| `~/.claude/telegram-watchdog.sh` | Create | Cron-based watchdog + Bot API alerter |

---

## Task 1: Write Failing Tests for Singleton Lock

Before touching server.ts, write the tests that define what "working" means.

**Files:**
- Create: `/tmp/tg-singleton-tests/test-lock.sh`

- [ ] **Step 1: Create the test harness**

```bash
mkdir -p /tmp/tg-singleton-tests
```

- [ ] **Step 2: Write the failing test script**

```bash
cat > /tmp/tg-singleton-tests/test-lock.sh << 'EOF'
#!/bin/bash
# Tests for the singleton lock behavior.
# These tests use an isolated socket path — they never touch the live plugin.
set -euo pipefail

SOCK_DIR="/tmp/tg-singleton-tests/sockets-$$"
mkdir -p "$SOCK_DIR"
PASS=0; FAIL=0; TOTAL=0

SIM="$SOCK_DIR/sim.ts"
cat > "$SIM" << 'TSEOF'
import { createServer, createConnection } from "net";
import { existsSync, unlinkSync } from "fs";
const SOCK = process.env.S!;
async function acq(): Promise<boolean> {
  if (existsSync(SOCK)) {
    const alive = await new Promise<boolean>(r => {
      const c = createConnection(SOCK);
      c.on("connect", () => { c.destroy(); r(true); });
      c.on("error", () => r(false));
      setTimeout(() => { c.destroy(); r(false); }, 500);
    });
    if (alive) { process.stdout.write("REJECTED\n"); return false; }
    try { unlinkSync(SOCK); } catch {}
  }
  return new Promise(r => {
    const s = createServer();
    s.on("error", (e: any) => {
      if (e.code==="EADDRINUSE") { process.stdout.write("REJECTED\n"); r(false); return; }
      r(true);
    });
    s.listen(SOCK, () => { process.stdout.write("ACQUIRED\n"); r(true); });
    process.on("exit", () => { try { unlinkSync(SOCK); } catch {} });
  });
}
if (!(await acq())) process.exit(1);
const h = parseInt(process.env.H || "5");
await new Promise(r => setTimeout(r, h * 1000));
process.exit(0);
TSEOF

check() {
  ((TOTAL++))
  if [ "$1" = "PASS" ]; then ((PASS++)); echo "  ✅ $2"
  else ((FAIL++)); echo "  ❌ $2 — $3"; fi
}

cleanup() { rm -rf "$SOCK_DIR"; }
trap cleanup EXIT

echo "═══════════════════════════════════"
echo "  SINGLETON LOCK TEST SUITE"
echo "═══════════════════════════════════"

# Test 1: Single instance acquires lock
echo "▸ T1: Single instance"
OUT=$(S="$SOCK_DIR/t1.sock" H=1 bun "$SIM")
echo "$OUT" | grep -q "ACQUIRED" && check PASS "Acquires lock" || check FAIL "Did not acquire" "got: $OUT"

# Test 2: Second concurrent instance rejected
echo "▸ T2: Concurrent rejection"
S="$SOCK_DIR/t2.sock" H=5 bun "$SIM" &
PID1=$!; sleep 2
OUT=$(S="$SOCK_DIR/t2.sock" H=1 bun "$SIM" || true)
echo "$OUT" | grep -q "REJECTED" && check PASS "Second rejected" || check FAIL "Second NOT rejected" "got: $OUT"
kill $PID1 2>/dev/null; wait $PID1 2>/dev/null

# Test 3: Stale socket recovery after crash
echo "▸ T3: Stale socket recovery"
S="$SOCK_DIR/t3.sock" H=30 bun "$SIM" &
PID2=$!; sleep 1
kill -9 $PID2 2>/dev/null; wait $PID2 2>/dev/null; sleep 1
[ -e "$SOCK_DIR/t3.sock" ] || check FAIL "Stale socket not left behind" "socket missing"
OUT=$(S="$SOCK_DIR/t3.sock" H=1 bun "$SIM")
echo "$OUT" | grep -q "ACQUIRED" && check PASS "Recovered stale socket" || check FAIL "Failed recovery" "got: $OUT"

# Test 4: Three concurrent — only first wins
echo "▸ T4: Triple concurrent"
S="$SOCK_DIR/t4.sock" H=5 bun "$SIM" &
PID_A=$!; sleep 2
OUT_B=$(S="$SOCK_DIR/t4.sock" H=1 bun "$SIM" || true)
OUT_C=$(S="$SOCK_DIR/t4.sock" H=1 bun "$SIM" || true)
B=$(echo "$OUT_B" | grep -c "REJECTED"); C=$(echo "$OUT_C" | grep -c "REJECTED")
[ "$B" -eq 1 ] && [ "$C" -eq 1 ] && check PASS "Both extras rejected" || check FAIL "Not all rejected" "B=$B C=$C"
kill $PID_A 2>/dev/null; wait $PID_A 2>/dev/null

# Test 5: Sequential handoff
echo "▸ T5: Sequential handoff"
S="$SOCK_DIR/t5.sock" H=2 bun "$SIM" &
PID_D=$!; sleep 3; wait $PID_D 2>/dev/null
OUT=$(S="$SOCK_DIR/t5.sock" H=1 bun "$SIM")
echo "$OUT" | grep -q "ACQUIRED" && check PASS "Handoff works" || check FAIL "Handoff failed" "got: $OUT"

# Test 6: Rapid fire (5 concurrent)
echo "▸ T6: Rapid fire"
S="$SOCK_DIR/t6.sock" H=5 bun "$SIM" &
PID_F=$!; sleep 2
REJ=0
for i in 2 3 4 5; do
  OUT=$(S="$SOCK_DIR/t6.sock" H=1 bun "$SIM" || true)
  echo "$OUT" | grep -q "REJECTED" && ((REJ++))
done
[ "$REJ" -eq 4 ] && check PASS "4/4 extras rejected" || check FAIL "Rapid fire" "only $REJ/4 rejected"
kill $PID_F 2>/dev/null; wait $PID_F 2>/dev/null

echo ""
echo "═══════════════════════════════════"
echo "  RESULTS: $PASS/$TOTAL passed, $FAIL failed"
echo "═══════════════════════════════════"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
EOF
chmod +x /tmp/tg-singleton-tests/test-lock.sh
```

- [ ] **Step 3: Run the tests — verify they PASS (these test the lock logic in isolation)**

```bash
bash /tmp/tg-singleton-tests/test-lock.sh
# Expected: 6/6 passed, 0 failed
```

These tests validate the lock algorithm works. They use an isolated socket path and never touch the live plugin. This is our regression suite — we'll re-run after patching server.ts.

- [ ] **Step 4: Write the integration test (this one SHOULD FAIL before patching)**

```bash
cat > /tmp/tg-singleton-tests/test-no-duplicate.sh << 'EOF'
#!/bin/bash
# Integration test: verify that the LIVE plugin rejects a duplicate instance.
# Before patching: this test FAILS (second instance starts polling).
# After patching: this test PASSES (second instance exits immediately).

MARKET_DIR="$HOME/.claude/plugins/marketplaces/claude-plugins-official/external_plugins/telegram"

echo "Starting second bun instance against live plugin..."
cd "$MARKET_DIR"
OUTPUT=$(timeout 10 bun server.ts 2>&1 || true)

if echo "$OUTPUT" | grep -q "singleton lock"; then
  echo "✅ PASS: Second instance detected lock and exited"
  exit 0
else
  echo "❌ FAIL: Second instance did NOT detect lock"
  echo "Output: $OUTPUT" | head -5
  exit 1
fi
EOF
chmod +x /tmp/tg-singleton-tests/test-no-duplicate.sh
```

- [ ] **Step 5: Run the integration test — verify it FAILS (patch not yet applied)**

```bash
bash /tmp/tg-singleton-tests/test-no-duplicate.sh
# Expected: ❌ FAIL: Second instance did NOT detect lock
# This is CORRECT — the patch hasn't been applied yet. TDD: red first.
```

**IMPORTANT:** After running this test, immediately kill any duplicate telegram processes:
```bash
HUB_TG=$(pgrep -P $(pgrep -f "claude.*--channels.*telegram" | head -1) -f "bun" 2>/dev/null | head -1)
pgrep -f "bun.*telegram" 2>/dev/null | while read pid; do
  [ -n "$pid" ] && [ "$pid" != "$HUB_TG" ] && kill "$pid" 2>/dev/null
done
```

- [ ] **Step 6: Commit tests**

```bash
cd /tmp/telegram-stability
cp -r /tmp/tg-singleton-tests tests/
git add tests/
git commit -m "test: add singleton lock test suite (6 unit + 1 integration)"
git push origin main
```

---

## Task 2: Apply Singleton Lock to server.ts

Now make the failing integration test pass.

**Files:**
- Modify: `~/.claude/plugins/marketplaces/claude-plugins-official/external_plugins/telegram/server.ts`
- Modify: `~/.claude/plugins/cache/claude-plugins-official/telegram/0.0.4/server.ts`

- [ ] **Step 1: Verify target files and find insertion points**

```bash
MARKET_FILE="$HOME/.claude/plugins/marketplaces/claude-plugins-official/external_plugins/telegram/server.ts"
CACHE_DIR="$HOME/.claude/plugins/cache/claude-plugins-official/telegram"
VER=$(ls -1 "$CACHE_DIR" 2>/dev/null | sort -V | tail -1)
CACHE_FILE="$CACHE_DIR/$VER/server.ts"

echo "Marketplace: $MARKET_FILE"
grep -n "const INBOX_DIR" "$MARKET_FILE"
grep -n "shuttingDown = true" "$MARKET_FILE"

echo "Cache: $CACHE_FILE"
grep -n "const INBOX_DIR" "$CACHE_FILE"
grep -n "shuttingDown = true" "$CACHE_FILE"
```

- [ ] **Step 2: Verify neither file is already patched**

```bash
grep -q "SINGLETON LOCK" "$MARKET_FILE" && echo "MARKET: ALREADY PATCHED" || echo "MARKET: clean"
grep -q "SINGLETON LOCK" "$CACHE_FILE" && echo "CACHE: ALREADY PATCHED" || echo "CACHE: clean"
# Expected: both clean
```

- [ ] **Step 3: Apply the patch to both files**

Use python3 for reliable insertion. Insert the singleton lock block after `const INBOX_DIR = join(STATE_DIR, 'inbox')` and add `releaseSingletonLock()` to `shutdown()`:

```bash
apply_lock_patch() {
  local file="$1"
  python3 << PYEOF
with open("$file") as f:
    content = f.read()

LOCK_BLOCK = '''

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
        \`telegram channel: another instance is running (socket lock held), exiting\\n\`,
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
        process.stderr.write('telegram channel: lock socket in use, exiting\\n')
        resolve(false)
        return
      }
      // Non-lock error — proceed without lock (don\\'t block startup)
      process.stderr.write(\`telegram channel: lock warning: \\${err.message}\\n\`)
      resolve(true)
    })
    _lockServer.listen(LOCK_SOCKET, () => {
      process.stderr.write(\`telegram channel: singleton lock acquired (PID \\${process.pid})\\n\`)
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
// ── END SINGLETON LOCK ─────────────────────────────────────────────────'''

marker = "const INBOX_DIR = join(STATE_DIR, 'inbox')"
assert marker in content, f"Insertion point not found in $file"
content = content.replace(marker, marker + LOCK_BLOCK)

# Add releaseSingletonLock() to shutdown
old = "shuttingDown = true"
new = "shuttingDown = true\\n  // Release singleton lock FIRST (Risk 4 fix).\\n  releaseSingletonLock()"
content = content.replace(old, new, 1)

with open("$file", "w") as f:
    f.write(content)
print(f"Patched: $file")
PYEOF
}

apply_lock_patch "$MARKET_FILE"
apply_lock_patch "$CACHE_FILE"
```

- [ ] **Step 4: Verify patch structure**

```bash
for f in "$MARKET_FILE" "$CACHE_FILE"; do
  echo "=== $(basename $(dirname $f)) ==="
  echo "  SINGLETON LOCK markers: $(grep -c 'SINGLETON LOCK' "$f")"   # Expected: 2
  echo "  releaseSingletonLock refs: $(grep -c 'releaseSingletonLock' "$f")"  # Expected: 4
  echo "  acquireSingletonLock refs: $(grep -c 'acquireSingletonLock' "$f")"  # Expected: 2
done
```

- [ ] **Step 5: Run the integration test — verify it NOW PASSES**

```bash
bash /tmp/tg-singleton-tests/test-no-duplicate.sh
# Expected: ✅ PASS: Second instance detected lock and exited
# TDD: green!
```

- [ ] **Step 6: Re-run the unit test suite to verify no regressions**

```bash
bash /tmp/tg-singleton-tests/test-lock.sh
# Expected: 6/6 passed
```

- [ ] **Step 7: Commit**

```bash
cd /tmp/telegram-stability
git add -A
git commit -m "feat: apply singleton lock patch to server.ts (TDD green)"
git push origin main
```

---

## Task 3: Create Idempotent Patch Script

For durability — auto re-applies after plugin updates.

**Files:**
- Create: `~/.claude/patches/telegram-singleton.sh`

- [ ] **Step 1: Write the failing test for idempotency**

```bash
cat > /tmp/tg-singleton-tests/test-idempotent.sh << 'EOF'
#!/bin/bash
# Test: running the patch script twice should not double-patch.

MARKET_FILE="$HOME/.claude/plugins/marketplaces/claude-plugins-official/external_plugins/telegram/server.ts"

COUNT_BEFORE=$(grep -c "SINGLETON LOCK" "$MARKET_FILE")
bash ~/.claude/patches/telegram-singleton.sh 2>/dev/null
bash ~/.claude/patches/telegram-singleton.sh 2>/dev/null
COUNT_AFTER=$(grep -c "SINGLETON LOCK" "$MARKET_FILE")

if [ "$COUNT_BEFORE" -eq "$COUNT_AFTER" ]; then
  echo "✅ PASS: Idempotent ($COUNT_AFTER markers, unchanged)"
  exit 0
else
  echo "❌ FAIL: Double-patched ($COUNT_BEFORE → $COUNT_AFTER markers)"
  exit 1
fi
EOF
chmod +x /tmp/tg-singleton-tests/test-idempotent.sh
```

- [ ] **Step 2: Write the patch script**

Create `~/.claude/patches/telegram-singleton.sh` with the content from the original plan Task 3 Step 1. (Full script with `apply_to()` function, idempotency check via `grep -q "SINGLETON LOCK"`, and python3 patching.)

- [ ] **Step 3: Make executable and run idempotency test**

```bash
chmod +x ~/.claude/patches/telegram-singleton.sh
bash /tmp/tg-singleton-tests/test-idempotent.sh
# Expected: ✅ PASS: Idempotent (2 markers, unchanged)
```

- [ ] **Step 4: Commit**

```bash
cd /tmp/telegram-stability
cp ~/.claude/patches/telegram-singleton.sh patches/
git add -A
git commit -m "feat: idempotent patch script with TDD verification"
git push origin main
```

---

## Task 4: Add SessionStart Hook

**Files:**
- Modify: `~/.claude/settings.json` (hooks.SessionStart array)

- [ ] **Step 1: Write the failing test**

```bash
cat > /tmp/tg-singleton-tests/test-hook.sh << 'EOF'
#!/bin/bash
# Test: settings.json contains the singleton patch hook.
python3 -c "
import json, sys
d = json.load(open('$HOME/.claude/settings.json'))
hooks = d.get('hooks',{}).get('SessionStart',[])
cmds = [h.get('command','') for entry in hooks for h in entry.get('hooks',[])]
if any('telegram-singleton' in c for c in cmds):
    print('✅ PASS: Hook found')
else:
    print('❌ FAIL: Hook not found')
    print('  Commands:', cmds)
    sys.exit(1)
"
EOF
chmod +x /tmp/tg-singleton-tests/test-hook.sh

bash /tmp/tg-singleton-tests/test-hook.sh
# Expected: ❌ FAIL: Hook not found (TDD red)
```

- [ ] **Step 2: Add the hook to settings.json**

Add `{"type": "command", "command": "bash ~/.claude/patches/telegram-singleton.sh", "timeout": 10}` to the SessionStart hooks array, between kill-competing-telegram.sh and telegram-reactions.sh.

- [ ] **Step 3: Verify JSON is valid**

```bash
python3 -c "import json; json.load(open('$HOME/.claude/settings.json')); print('VALID JSON')"
# Expected: VALID JSON
```

- [ ] **Step 4: Run the hook test — verify it PASSES**

```bash
bash /tmp/tg-singleton-tests/test-hook.sh
# Expected: ✅ PASS: Hook found (TDD green)
```

- [ ] **Step 5: Commit**

```bash
cd /tmp/telegram-stability
git add -A
git commit -m "feat: add SessionStart hook for patch durability (TDD green)"
git push origin main
```

---

## Task 5: Create Watchdog Script + Cron

**Files:**
- Create: `~/.claude/telegram-watchdog.sh`

- [ ] **Step 1: Write the failing test**

```bash
cat > /tmp/tg-singleton-tests/test-watchdog.sh << 'EOF'
#!/bin/bash
# Test: watchdog script exists, is executable, and produces no output
# when system is healthy (1 process, no zombies).

if [ ! -x "$HOME/.claude/telegram-watchdog.sh" ]; then
  echo "❌ FAIL: watchdog script missing or not executable"
  exit 1
fi

# Run the watchdog — should produce no output when healthy
OUTPUT=$(bash "$HOME/.claude/telegram-watchdog.sh" 2>&1)
if [ -z "$OUTPUT" ]; then
  echo "✅ PASS: Watchdog silent when healthy"
else
  echo "❌ FAIL: Watchdog produced output on healthy system"
  echo "  Output: $OUTPUT"
  exit 1
fi

# Verify cron is set up
if crontab -l 2>/dev/null | grep -q "telegram-watchdog"; then
  echo "✅ PASS: Cron entry exists"
else
  echo "❌ FAIL: Cron entry missing"
  exit 1
fi
EOF
chmod +x /tmp/tg-singleton-tests/test-watchdog.sh

bash /tmp/tg-singleton-tests/test-watchdog.sh
# Expected: ❌ FAIL: watchdog script missing (TDD red)
```

- [ ] **Step 2: Write the watchdog script**

Create `~/.claude/telegram-watchdog.sh` with the content from the original plan Task 5 Step 1. (Counts processes, kills extras, detects zombies, alerts via Bot API.)

- [ ] **Step 3: Make executable, set up cron**

```bash
chmod +x ~/.claude/telegram-watchdog.sh
(crontab -l 2>/dev/null; echo "* * * * * bash $HOME/.claude/telegram-watchdog.sh") | sort -u | crontab -
```

- [ ] **Step 4: Run the watchdog test — verify it PASSES**

```bash
bash /tmp/tg-singleton-tests/test-watchdog.sh
# Expected: both checks ✅ PASS (TDD green)
```

- [ ] **Step 5: Commit**

```bash
cd /tmp/telegram-stability
cp ~/.claude/telegram-watchdog.sh watchdog/
git add -A
git commit -m "feat: watchdog cron with Bot API alerts (TDD green)"
git push origin main
```

---

## Task 6: Restart Plugin and Run Live Verification

User must run `/mcp` at the terminal to restart the telegram plugin with the patched server.ts.

- [ ] **Step 1: User runs `/mcp`**

- [ ] **Step 2: Verify singleton lock acquired**

```bash
ls -la ~/.claude/channels/telegram/telegram.sock
# Expected: socket file exists (srwxr-xr-x)

pgrep -f "bun.*telegram" | wc -l | tr -d ' '
# Expected: 1
```

- [ ] **Step 3: Test send (outbound)**

Use MCP reply tool to send a test message to the group chat. Verify it arrives on Telegram.

- [ ] **Step 4: Test receive (inbound)**

Have operator send a message on Telegram. Verify `<channel>` tag appears in the CC session.

- [ ] **Step 5: Test duplicate rejection**

```bash
S_DIR="$HOME/.claude/plugins/marketplaces/claude-plugins-official/external_plugins/telegram"
cd "$S_DIR" && timeout 10 bun server.ts 2>&1 | head -5
# Expected: "telegram channel: another instance is running (socket lock held), exiting"

pgrep -f "bun.*telegram" | wc -l | tr -d ' '
# Expected: still 1
```

- [ ] **Step 6: Run the full integration test**

```bash
bash /tmp/tg-singleton-tests/test-no-duplicate.sh
# Expected: ✅ PASS
```

- [ ] **Step 7: Commit results**

```bash
cd /tmp/telegram-stability
cat > docs/live-test-log.md << LOGEOF
## Live Verification — $(date '+%Y-%m-%d %H:%M')

| Check | Result |
|-------|--------|
| Socket file exists | ✅ / ❌ |
| Process count = 1 | ✅ / ❌ |
| Outbound send | ✅ / ❌ |
| Inbound receive | ✅ / ❌ |
| Duplicate rejected | ✅ / ❌ |
| Integration test | ✅ / ❌ |
LOGEOF
git add -A
git commit -m "test: live verification results"
git push origin main
```

---

## Task 7: Verification Before Completion

> **REQUIRED SKILL:** superpowers:verification-before-completion
>
> Do NOT claim deployment is complete without running every check below and recording the actual output. Evidence before assertions.

- [ ] **Step 1: Run ALL test suites**

```bash
echo "=== Unit tests ==="
bash /tmp/tg-singleton-tests/test-lock.sh

echo "=== Integration test ==="
bash /tmp/tg-singleton-tests/test-no-duplicate.sh

echo "=== Idempotency test ==="
bash /tmp/tg-singleton-tests/test-idempotent.sh

echo "=== Hook test ==="
bash /tmp/tg-singleton-tests/test-hook.sh

echo "=== Watchdog test ==="
bash /tmp/tg-singleton-tests/test-watchdog.sh
```

All 5 must pass. If ANY fail, fix the issue and re-run. Do not proceed with failures.

- [ ] **Step 2: Verify live system state**

```bash
echo "Socket: $(ls ~/.claude/channels/telegram/telegram.sock 2>/dev/null && echo EXISTS || echo MISSING)"
echo "Processes: $(pgrep -f 'bun.*telegram' 2>/dev/null | wc -l | tr -d ' ')"
echo "Hook in settings: $(grep -c 'telegram-singleton' ~/.claude/settings.json)"
echo "Cron active: $(crontab -l 2>/dev/null | grep -c 'watchdog')"
echo "Patch in marketplace: $(grep -c 'SINGLETON LOCK' ~/.claude/plugins/marketplaces/claude-plugins-official/external_plugins/telegram/server.ts)"
echo "Patch in cache: $(grep -c 'SINGLETON LOCK' ~/.claude/plugins/cache/claude-plugins-official/telegram/*/server.ts)"
```

Expected: Socket EXISTS, Processes 1, Hook 1, Cron 1, Patch 2 (both copies).

- [ ] **Step 3: Clean up test artifacts**

```bash
rm -rf /tmp/tg-test-sandbox /tmp/tg-direct-test /tmp/tg-lock-stress-* /tmp/tg-test-f /tmp/tg-prototype 2>/dev/null
```

- [ ] **Step 4: Update active_state.md**

Update `~/.claude/projects/-Users-dispatch/memory/active_state.md`:
- Telegram singleton lock: deployed
- Watchdog cron: active (every 60s)
- SessionStart hook: installed (telegram-singleton.sh)
- Known limitation: #37933 (notification delivery) has no local fix

- [ ] **Step 5: Send deployment confirmation to Telegram group**

Only after ALL checks pass:
```
✅ Telegram singleton lock deployed and verified.
- Socket lock active
- SessionStart hook re-applies on every start
- Watchdog cron running every 60s
- Duplicate processes exit immediately
- All 5 test suites passing
- Known limitation: #37933 (MCP notification delivery) cannot be fixed locally
```

- [ ] **Step 6: Final commit**

```bash
cd /tmp/telegram-stability
git add -A
git commit -m "feat: deployment complete — all tests passing, verified live"
git push origin main
```
