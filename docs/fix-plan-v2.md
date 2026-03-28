# Telegram Stability Plan v2 — Built from First Principles

**Date:** 2026-03-28
**Author:** Yuna (Hub)
**Status:** DRAFT — awaiting operator approval
**Based on:** tg-recon-report.md + 4 upstream references

---

## The Problem (Precisely)

Three distinct bugs cause Telegram message loss:

| Bug | Source | Severity |
|-----|--------|----------|
| **Every Claude process starts a poller** | CC harness: `enabledPlugins` unconditionally starts MCP servers regardless of `--channels` flag (anthropics/claude-code#38098) | Critical — causes 409 conflicts |
| **Harness spawns duplicates mid-session** | CC harness: spontaneous second plugin spawn with no trigger (anthropics/claude-code#36800) | Critical — unpredictable |
| **MCP notifications not surfaced** | CC harness: `notifications/claude/channel` sent but never appears in session UI (anthropics/claude-code#37933) | High — inbound messages silently lost |

All three are **upstream CC bugs** with open issues. We cannot fix the harness. We can only build defensive layers around it.

---

## Root Cause Chain

```
enabledPlugins: telegram = true (global settings.json)
    ↓
Every Claude process reads global settings
    ↓
Every Claude process starts bun server.ts
    ↓
Every bun process calls bot.start() → getUpdates polling
    ↓
Telegram Bot API allows only ONE getUpdates consumer per token
    ↓
409 Conflict → retry loop (INFINITE, no max retries)
    ↓
Multiple processes stuck in retry loops forever
    ↓
Random message routing → messages hit wrong process → MCP pipe may be broken → silent loss
```

### Who spawns new Claude processes?

| Trigger | New OS Process? | Inherits Global Settings? | Starts Telegram? |
|---------|----------------|--------------------------|-----------------|
| `Agent` (subagent) | **No** — in-process | Shares parent MCP | **No** — safe |
| `TeamCreate` (teammates) | **Yes** — tmux pane | **Yes** | **Yes** — DANGEROUS |
| `/mcp reconnect` | **Yes** — new bun | N/A (direct spawn) | **Yes** — DANGEROUS |
| `start-spoke.sh` node | **Yes** — tmux session | **Yes**, but overridden by local settings | **No** — protected |
| Direct `claude` CLI | **Yes** | **Yes** | **Yes** — DANGEROUS |
| Harness spontaneous respawn | **Yes** | N/A | **Yes** — DANGEROUS, UNPREDICTABLE |

---

## Defense Strategy: Three Layers

We can't fix the CC harness. We need:
1. **Prevent** — stop telegram from loading where it shouldn't
2. **Detect & Kill** — find and eliminate duplicates fast
3. **Alert** — know when we've gone silent, even from Telegram

### Layer 1: PREVENTION

**1a. Remove telegram from global `enabledPlugins`**

This is the single highest-impact fix. Currently:
```json
// ~/.claude/settings.json (GLOBAL — read by ALL Claude processes)
"telegram@claude-plugins-official": true   // ← REMOVE THIS
```

The hub is started with `--channels plugin:telegram@claude-plugins-official`. The `--channels` flag loads the plugin AND starts the MCP server. We do NOT also need it in `enabledPlugins`.

**Test needed:** Verify that `--channels` alone is sufficient to:
- Start the bun process
- Enable MCP tools (reply, react, edit_message, download_attachment)
- Deliver inbound notifications via `notifications/claude/channel`

If `--channels` alone is NOT sufficient (the plugin also needs `enabledPlugins` to register tools), then we need a different approach — see 1a-fallback.

**1a-fallback: If `enabledPlugins` is required alongside `--channels`**

Move it to a hub-only settings file:
- Create `/.claude/settings.local.json` (root directory — hub's working directory) with telegram enabled
- Remove from global `~/.claude/settings.json`
- All other processes (teammates, nodes, CLI) read global settings → no telegram

**1b. Harden SessionStart hook for TeamCreate**

Even after 1a, the harness bug (#36800 — spontaneous respawn) means duplicates can still appear. Replace `kill-competing-telegram.sh` with `telegram-guardian.sh`:

```bash
#!/bin/bash
# telegram-guardian.sh — Kill any telegram bun process not belonging to the hub

# Find the hub's Claude PID (the one with --channels)
HUB_PID=$(pgrep -f "claude.*--channels.*telegram" | head -1)

if [ -z "$HUB_PID" ]; then
  # No hub process found — kill ALL telegram bun processes
  pkill -f "bun.*telegram" 2>/dev/null
  exit 0
fi

# Find the hub's telegram bun (child of hub's Claude)
HUB_TG_PID=$(pgrep -P "$HUB_PID" -f "bun" 2>/dev/null | head -1)

# If hub's bun isn't direct child, search the full tree
if [ -z "$HUB_TG_PID" ]; then
  # The bun chain: claude → bun run → bun server.ts
  for child in $(pgrep -P "$HUB_PID" 2>/dev/null); do
    grandchild=$(pgrep -P "$child" -f "bun.*telegram" 2>/dev/null | head -1)
    [ -n "$grandchild" ] && HUB_TG_PID="$grandchild" && break
    # Also check if the child itself is the telegram bun
    if ps -o command= -p "$child" 2>/dev/null | grep -q "bun.*telegram"; then
      HUB_TG_PID="$child"
      break
    fi
  done
fi

# Kill every telegram bun that ISN'T the hub's
pgrep -f "bun.*telegram" 2>/dev/null | while read pid; do
  [ "$pid" != "$HUB_TG_PID" ] && kill "$pid" 2>/dev/null
done
```

Key difference from old script:
- Identifies hub by `--channels` flag, not tmux session name
- Kills by parent relationship, not by process age
- No sleep loop — runs once, fast
- Works regardless of which tmux session it runs in

Make this the SessionStart hook AND run it on a 30-second cron.

**1c. PID lock file in server.ts (plugin-level patch)**

Patch the telegram plugin to create a lock file before polling:

```typescript
// Add after line 70 (const bot = new Bot(TOKEN))
import { existsSync, writeFileSync, unlinkSync, readFileSync } from 'fs'

const LOCK_FILE = join(STATE_DIR, 'telegram.lock')
const myPid = process.pid

// Check for existing lock
if (existsSync(LOCK_FILE)) {
  try {
    const lockPid = parseInt(readFileSync(LOCK_FILE, 'utf8').trim())
    // Check if that PID is still alive
    process.kill(lockPid, 0) // Throws if dead
    // PID is alive — we're a duplicate, exit immediately
    process.stderr.write(`telegram channel: another instance running (PID ${lockPid}), exiting\n`)
    process.exit(0)
  } catch {
    // PID is dead — stale lock, overwrite
  }
}

// Write our PID
writeFileSync(LOCK_FILE, String(myPid))

// Clean up lock on exit
function removeLock() { try { unlinkSync(LOCK_FILE) } catch {} }
process.on('exit', removeLock)
```

This is the strongest defense — the plugin itself refuses to start if another instance is alive.

### Layer 2: DETECT & KILL

**2a. Watchdog cron (every 30 seconds)**

```bash
#!/bin/bash
# telegram-watchdog.sh — runs via cron every 30s

TOKEN=$(grep 'BOT_TOKEN' ~/.claude/channels/telegram/.env 2>/dev/null | cut -d'=' -f2)
GRP_CHAT="-5127377005"
LOCK_FILE="$HOME/.claude/channels/telegram/telegram.lock"

# Count telegram processes
TG_COUNT=$(pgrep -f "bun.*telegram" 2>/dev/null | wc -l | tr -d ' ')

# 1. Multiple processes → run guardian to kill extras
if [ "$TG_COUNT" -gt 1 ]; then
  bash ~/.claude/telegram-guardian.sh
  # Alert
  curl -s "https://api.telegram.org/bot${TOKEN}/sendMessage" \
    -d "chat_id=${GRP_CHAT}" \
    -d "text=⚠️ Watchdog: killed $(($TG_COUNT - 1)) duplicate telegram process(es)" >/dev/null 2>&1
fi

# 2. Zero processes → telegram is fully down
if [ "$TG_COUNT" -eq 0 ]; then
  curl -s "https://api.telegram.org/bot${TOKEN}/sendMessage" \
    -d "chat_id=${GRP_CHAT}" \
    -d "text=🔴 Watchdog: Telegram is DOWN. No bot process running. Run /mcp at terminal to restart." >/dev/null 2>&1
  # Clean stale lock
  rm -f "$LOCK_FILE" 2>/dev/null
fi

# 3. Zombie check — is the surviving process's parent alive?
if [ "$TG_COUNT" -eq 1 ]; then
  TG_PID=$(pgrep -f "bun.*telegram" | head -1)
  PPID=$(ps -o ppid= -p "$TG_PID" 2>/dev/null | tr -d ' ')
  if [ "$PPID" = "1" ]; then
    # Orphaned zombie — kill it
    kill "$TG_PID" 2>/dev/null
    rm -f "$LOCK_FILE" 2>/dev/null
    curl -s "https://api.telegram.org/bot${TOKEN}/sendMessage" \
      -d "chat_id=${GRP_CHAT}" \
      -d "text=⚠️ Watchdog: killed orphaned telegram zombie (ppid=1). Run /mcp to restart." >/dev/null 2>&1
  fi
fi
```

**2b. Fix comms-check.sh**

- Fix process counting (the current `echo "$TG_PIDS" | grep -c .` bug)
- `--fix` identifies the correct process by parent chain (hub's Claude PID via `--channels`), not by newest
- Add lock file check
- Add MCP pipe health check (is bun's parent a live Claude process, not ppid=1?)

### Layer 3: ALERT

**3a. Watchdog alerts via Bot API (not MCP)**

The watchdog script sends alerts directly via `curl` to the Telegram Bot API. This works even when:
- MCP is disconnected
- The plugin is crashed
- The hub Claude process is frozen
- All telegram bun processes are dead

The only thing that breaks this: no internet, or the bot token is invalid.

**3b. Heartbeat message (optional, for paranoia)**

Add to the watchdog: every 10 minutes, send a silent `getMe` API call. If it fails → alert. This catches token revocation or API blocks.

---

## Implementation Plan

| Step | What | Time | Risk |
|------|------|------|------|
| 1 | **Test `--channels` without `enabledPlugins`** — verify tools + notifications work | 10 min | Low — reversible |
| 2 | **Remove telegram from global settings** (or move to root project settings) | 2 min | Medium — breaks telegram if test fails |
| 3 | **Write telegram-guardian.sh** | 10 min | Low |
| 4 | **Patch server.ts with PID lock** | 10 min | Low — additive |
| 5 | **Write telegram-watchdog.sh** | 10 min | Low |
| 6 | **Set up cron** (watchdog every 30s + guardian every 30s) | 5 min | Low |
| 7 | **Fix comms-check.sh** | 15 min | Low |
| 8 | **Replace SessionStart hook** (guardian instead of kill-competing) | 2 min | Low |

### Stress Test Matrix (after implementation)

| # | Scenario | Pass Criteria |
|---|----------|---------------|
| 1 | Hub starts clean | 1 telegram process, send + receive work |
| 2 | `Agent` subagent spawned | Still 1 telegram process |
| 3 | `TeamCreate` with 3 teammates | Still 1 telegram process (guardian kills extras within 30s) |
| 4 | `/mcp reconnect` | Old process dies, new one starts, still 1 total |
| 5 | `start-spoke.sh` node launch | Node has 0 telegram processes |
| 6 | Hub Claude crash (kill -9) + restart | Lock cleared, new process starts clean |
| 7 | Harness spontaneous respawn (#36800) | Watchdog catches within 30s, kills duplicate, alerts |
| 8 | 3 teammates + /mcp + node launch simultaneously | Max 1 telegram process at all times |
| 9 | Telegram goes silent for 60s+ | Alert appears in group chat |
| 10 | Zombie process (ppid=1) | Watchdog kills within 30s, alerts |
| 11 | Network drop 5 min | Bot reconnects, buffered messages delivered |
| 12 | Sleep/wake cycle | Bot reconnects automatically |

---

## What We Can't Fix (Upstream)

| Issue | Workaround | Real Fix |
|-------|------------|----------|
| #38098 — all instances start pollers | Remove from global settings | CC needs to respect `--channels` flag for plugin loading |
| #36800 — spontaneous mid-session respawn | PID lock + watchdog detection | CC harness needs to not respawn healthy plugins |
| #37933 — notifications not surfaced | None (this is why inbound sometimes fails even with 1 process) | CC needs to fix MCP notification delivery |

For #37933, we should monitor and document occurrences. If it becomes frequent, consider the RichardAtCT/claude-code-telegram approach (Agent SDK-based bot, bypasses MCP entirely) as a long-term replacement.

---

## What I Need From You

1. **Approval to proceed** with this plan
2. **Confirm removing telegram from global settings** — only hub gets it via `--channels`
3. **Confirm patching server.ts** — this modifies the plugin source (will need re-patching on plugin updates)
4. Any scenarios I'm missing?
