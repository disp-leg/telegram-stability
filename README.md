# Telegram Stability — Engineering Report

**System:** Claude Code 2.1.85 + telegram@claude-plugins-official v0.0.4
**Platform:** macOS (Darwin 24.5.0), tmux, Homebrew bun
**Date:** 2026-03-28
**Authors:** Yuna (hub AI), John & Ria (operators)

---

## Executive Summary

The official Telegram plugin for Claude Code suffers from **three distinct upstream bugs** that cause repeated message loss, silent disconnections, and invisible failures. Over a 10-hour period, we documented **7+ Telegram drops** — each requiring manual terminal intervention to restore.

The root cause is architectural: Claude Code's plugin loading system starts a Telegram bot poller in **every** Claude process, not just the one designated as the channel handler. When agent teams, nodes, or `/mcp` reconnects spawn new Claude processes, multiple pollers compete for the same Telegram Bot API token, causing HTTP 409 Conflict errors that kill the hub's connection.

**We reproduced this bug live** during this investigation by creating a TeamCreate team and watching the hub's Telegram die in real time.

This report covers:
1. Live reproduction with exact PIDs, process trees, and timelines
2. First-principles investigation of the plugin lifecycle (read from source code)
3. Three upstream CC harness bugs with root cause analysis
4. Why every existing defense failed
5. A proposed 3-layer fix plan
6. Honest assessment of what we cannot fix locally

---

## 1. Live Reproduction Results

### Test: Subagent Spawn (Agent tool)

**Hypothesis:** Agent tool subagents share parent's MCP, don't spawn new processes.

**Method:** Spawned a background agent via `Agent` tool with `run_in_background: true`, monitored `pgrep -f "bun.*telegram"` before, during, and after.

**Result: SAFE** — No new telegram bun processes appeared. Count stayed at 1.

| Metric | Before | During | After |
|--------|--------|--------|-------|
| bun..telegram count | 1 (PID 8164) | 1 (PID 8164) | 1 (PID 8164) |

**Conclusion:** Subagents are in-process. They share the parent's MCP connections and do not cause 409 conflicts.

---

### Test: TeamCreate

**Hypothesis:** TeamCreate spawns separate Claude processes that inherit global settings and start their own telegram pollers.

**Method:** Created team `tg-stress-test` via TeamCreate, monitored processes.

**Result: CONFIRMED — TeamCreate killed the hub's Telegram.**

#### Timeline (exact PIDs):

| Time | Event | Hub Telegram | Teammate Telegram |
|------|-------|-------------|-------------------|
| T+0s | Baseline | PID 8164 (parent: hub 717) | — |
| T+0s | TeamCreate called | PID 8164 | — |
| T+3s | Teammate Claude spawned (PID 11398) | PID 8164 → **DEAD** | PID 11415 (parent: 11398) |
| T+5s | Damage assessed | **GONE** — 0 telegram children | PID 11415 alive |

#### Process Tree After Damage:

```
Hub Claude (PID 717) children:
  PID 6149: npm exec @playwright/mcp@latest   ← survived
  PID 6150: npm exec @upstash/context7-mcp    ← survived
  PID 6209: npm exec firecrawl-mcp            ← survived
  *** NO telegram bun child ***               ← KILLED

Teammate Claude (PID 11398) children:
  PID 11406: npm exec @playwright/mcp@latest   ← duplicated
  PID 11407: npm exec @upstash/context7-mcp    ← duplicated
  PID 11415: bun run .../telegram              ← STOLE the polling slot
  PID 11467: npm exec firecrawl-mcp            ← duplicated
```

#### What happened step by step:

1. TeamCreate spawned a teammate as a **separate Claude CLI process** (PID 11398) in a new tmux pane
2. Teammate read `~/.claude/settings.json` (global) → saw `"telegram@claude-plugins-official": true`
3. Teammate started its own `bun server.ts` (PID 11415) → called `bot.start()` → `getUpdates`
4. Telegram Bot API returned **409 Conflict** to hub's poller (PID 8164)
5. Hub's bun entered the infinite 409 retry loop → eventually died
6. Teammate's bun **won the polling slot** — but it's connected to the teammate, not the hub
7. Hub lost all Telegram MCP tools (reply, react, edit_message, download_attachment)
8. Hub went **completely silent on Telegram** with zero indication to users
9. Telegram MCP server disconnected from hub session

#### Key observation:

The teammate also inherited **playwright, context7, and firecrawl** MCP servers. This is not just a Telegram problem — **ALL MCP plugins get duplicated by TeamCreate**.

---

### Test: Process Pattern Matching

**Finding:** `pgrep -la "bun.*telegram"` shows only short command names (`bun`), while `pgrep -f "bun.*telegram"` matches full command line args. Current defense scripts use `-f` so they work, but `-la` is a trap.

**Additional finding:** `pgrep -af "bun"` matches many unrelated macOS system processes (powerd, containermanagerd, SafariBookmarks) because "bun" appears in their bundle paths. Patterns need to be more specific (e.g., `bun.*telegram` or `bun server.ts`).

---

## 2. First-Principles Investigation

### 2.1 Plugin Lifecycle (from source: server.ts, 1047 lines)

**Startup sequence:**
1. Claude CLI reads `.mcp.json` → spawns `bun run --cwd <plugin_root> --silent start`
2. `package.json` start script: `bun install --no-summary && bun server.ts`
3. Two processes: wrapper (PID A) → actual server (PID B)
4. server.ts loads `.env` for `TELEGRAM_BOT_TOKEN` (line 33-40)
5. MCP server connects via stdio: `await mcp.connect(new StdioServerTransport())` (line 616)
6. Bot polling starts as fire-and-forget IIFE (line 1009-1046):
   ```typescript
   void (async () => {
     for (let attempt = 1; ; attempt++) {
       try {
         await bot.start({ allowed_updates: ['message', 'callback_query', 'message_reaction'] })
       } catch (err) { ... }
     }
   })()
   ```

**The 409 retry loop (lines 1006-1046):**
- Backoff: linear, `1000ms * attempt`, capped at **15 seconds**
- Max retries: **NONE** — `for (let attempt = 1; ; attempt++)` — **infinite loop**
- A process stuck in 409 retry will **never die on its own**
- It retries every 15 seconds forever, writing to stderr each time
- MCP tools still work (reply/react) but inbound messages never arrive

**Shutdown sequence (lines 621-634):**
- Triggers: stdin EOF, stdin close, SIGTERM, SIGINT
- NOT triggered by: SIGHUP (what tmux kill-session sends)
- `bot.stop()` signals grammy to end `getUpdates` loop
- Force-exit after **2 seconds** via `setTimeout(() => process.exit(0), 2000)`
- `shuttingDown` boolean prevents double-shutdown

**Error resilience (designed to never die):**
- `unhandledRejection` handler (line 57) — logs, does NOT exit
- `uncaughtException` handler (line 60) — logs, does NOT exit
- `bot.catch()` (line 1002) — swallows handler errors, polling continues

### 2.2 Spawn Triggers

| Trigger | Creates New OS Process? | Inherits Global Settings? | Starts Telegram Poller? |
|---------|------------------------|--------------------------|------------------------|
| `Agent` tool (subagent) | **No** — in-process | Shares parent MCP | **No** — VERIFIED SAFE |
| `TeamCreate` (teammates) | **Yes** — tmux pane | **Yes** | **Yes** — VERIFIED DANGEROUS |
| `/mcp reconnect` | **Yes** — new bun | N/A (direct spawn) | **Yes** — documented in error log |
| `start-spoke.sh` node | **Yes** — tmux session | **Yes**, overridden by local settings | **No** — protected by settings |
| Direct `claude` CLI | **Yes** | **Yes** | **Yes** — per upstream #38098 |
| Harness spontaneous respawn | **Yes** | N/A | **Yes** — per upstream #36800 |

### 2.3 Settings Inheritance Chain

```
~/.claude/settings.json (GLOBAL)
    └── enabledPlugins: { "telegram@claude-plugins-official": true }
        ├── Read by hub Claude (717) ← intentional
        ├── Read by TeamCreate teammates ← UNINTENTIONAL — causes 409
        ├── Read by any `claude` CLI invocation ← UNINTENTIONAL
        └── NOT read by subagents (they share parent's MCP)

Project-level .claude/settings.local.json
    └── Can override with: { "telegram@claude-plugins-official": false }
        ├── Used by start-spoke.sh nodes ← protects nodes
        └── NOT used by TeamCreate teammates ← gap
```

**Key insight from upstream #38098 (community source inspection):**

In Claude Code's `cli.js`, the plugin loading path (`Ol_()`) reads `enabledPlugins` from `~/.claude/settings.json` at startup and **unconditionally starts the MCP server** for every matching plugin — **regardless of whether `--channels` was passed**.

- `enabledPlugins: true` → starts the bot process (polling begins)
- `--channels` flag → marks that instance as the channel message handler

Both are required for the channel to work, but the decoupling means every instance starts polling.

### 2.4 MCP Transport

- **Protocol:** JSON-RPC over stdin/stdout pipes (StdioServerTransport)
- **Polling and MCP are fully independent** — the `bot.start()` IIFE runs concurrently with the MCP server
- **Broken pipe ≠ stopped polling** — if stdout blocks (Claude stops reading), polling continues but notifications stall. If stdin gets EOF, `shutdown()` fires.
- **Pipes survive tmux detach/reattach** — no process impact
- **/mcp reconnect may not close the old pipe** — evidence: error log shows old process from 3 AM still running at 11 AM

### 2.5 Edge Cases (reasoned from source code)

| Scenario | Telegram Impact | Verdict |
|----------|----------------|---------|
| Hub crash (kill -9) | stdin EOF → bun dies within 2s | SAFE |
| tmux kill-session | SIGHUP sent → NOT handled by shutdown → bun gets stdin EOF when Claude dies | MOSTLY SAFE (30s 409 window) |
| macOS sleep/wake | grammy reconnects automatically, pipes survive | SAFE |
| Network drop 5 min | grammy retries, Telegram buffers updates 24h | SAFE |
| Dual SSH attach | No process impact | SAFE |
| /mcp during message processing | Old pipe may not close → duplicate poller → 409 | HIGH RISK |

---

## 3. Upstream Bug Analysis

### Bug 1: anthropics/claude-code#38098

**Title:** "Telegram plugin auto-loads in all Claude Code sessions, not just --channels sessions"
**Status:** OPEN | **Labels:** bug, has-repro, platform:macos, area:plugins

**Root cause:** `cli.js` `Ol_()` unconditionally starts MCP servers for all enabled plugins regardless of `--channels` flag. Every Claude process that reads global settings starts a telegram poller.

**Community confirmation:** Multiple users, VSCode sidebar also affected. v2.1.83 fixed the zombie problem (processes now die on session exit) but did NOT fix the competing-pollers problem.

**Workaround:** Set `"telegram@claude-plugins-official": false` in project-level settings for non-channel instances.

### Bug 2: anthropics/claude-code#36800

**Title:** "Claude Code spawns duplicate channel plugin instances mid-session, causing 409 Conflict and tool loss"
**Status:** OPEN | **Labels:** bug, has-repro, platform:macos, area:mcp

**Root cause:** CC harness spontaneously spawns a second plugin process ~3 minutes into a healthy session with **no external trigger**. Instrumented logs show 10 successful tool calls and 8 successful notifications before the duplicate appears.

**Key quote from instrumented log:**
```
[19:54:09.444] PID=62665 tool call: reply       ← healthy
[19:54:21.395] PID=69445 starting up            ← WHERE DID THIS COME FROM?
[19:54:21.397] PID=69445 MCP connected
```

**Community notes:** Discord plugin has the same behavior. Plugin-side PRs #812-#814 mitigate damage but can't fix the harness trigger.

### Bug 3: anthropics/claude-code#37933

**Title:** "Telegram plugin inbound messages not delivered to Claude Code session"
**Status:** OPEN | **Labels:** bug, duplicate, platform:macos, area:mcp, area:plugins

**Root cause:** Even with a single bot process, `mcp.notification("notifications/claude/channel")` fires successfully in the plugin (confirmed via debug.log) but **never appears in the Claude Code UI**. The MCP notification is sent but not surfaced.

**This is a SEPARATE bug from 409 conflicts.** It means inbound messages can be silently lost even when everything else is working correctly.

**Community notes:** 4-person team using plugin reports outbound works perfectly, inbound randomly fails. Switching from bun to node fixed some TCP issues but notification delivery still fails.

---

## 4. Historical Error Timeline

| # | Time | Cause | Impact |
|---|------|-------|--------|
| 1 | 2026-03-28 ~03:15 | kill-competing-telegram.sh killed hub's bot | Hub went silent |
| 2 | ~03:33 | Env vars not set on team agents | Same |
| 3 | ~03:37 | Duplicate bots from earlier spawns still running | 409 conflicts |
| 4 | ~06:09 | TeamCreate spawned new bots again | 3 duplicates found |
| 5 | ~06:33 | Same duplicates still running | Manual kill required |
| 6 | ~10:33 | 3 team agents each spawned their own bots | Kill script only prevented kill, not spawn |
| 7 | ~11:07 | /mcp reconnect stacked on old process | 2 pollers running |
| 8 | ~16:55 | **Live reproduction** — TeamCreate killed hub's telegram | Hub telegram DEAD, documented with PIDs |

---

## 5. Existing Defenses & Why They Failed

### kill-competing-telegram.sh (SessionStart hook)

**What it does:** Runs in yuna tmux session, walks process tree to find hub's Claude PID, kills any telegram bun that isn't the hub's. Loops 12 times over 60 seconds.

**Why it fails:**
- **Cannot prevent spawning** — runs AFTER the teammate's telegram has already started
- **Race condition** — teammate's telegram may start between kill iterations
- **Only runs in yuna** — teammates in other sessions/panes don't run this
- **Self-identification is fragile** — walking process tree with `ps -o ppid=` assumes stable parent chain

### comms-check.sh --fix

**What it does:** Counts telegram processes, keeps newest PID, kills duplicates.

**Why it fails:**
- **Wrong heuristic** — keeps NEWEST process, but newest may be the teammate's bot, not the hub's MCP-connected one
- **Not automated** — must be manually invoked
- **Cannot verify receive path** — can't call `getUpdates` (would steal from grammy)
- **Process counting bug** — `echo "$TG_PIDS" | grep -c .` parsing issue

### start-spoke.sh settings override

**What it does:** Sets `"telegram@claude-plugins-official": false` in node's `.claude/settings.local.json`.

**Why it fails for TeamCreate:** TeamCreate teammates are NOT launched via start-spoke.sh. They are spawned by Claude's internal mechanism into tmux panes, inheriting global settings directly.

### Summary

| Defense | Prevents Spawn? | Kills Duplicate? | Covers TeamCreate? | Automated? |
|---------|----------------|-----------------|-------------------|-----------|
| kill-competing-telegram.sh | No | Yes (with race conditions) | No | Yes (hook) |
| comms-check.sh --fix | No | Yes (wrong heuristic) | No | No (manual) |
| spoke settings.local.json | Yes (for spokes) | N/A | **No** | Yes |

**None of these defenses cover the primary failure mode (TeamCreate).**

---

## 6. Proposed Fix Plan (3 Layers)

### Layer 1: PREVENTION

**1a. Remove telegram from global `enabledPlugins`**

The single highest-impact fix. Hub is started with `--channels plugin:telegram@claude-plugins-official` which loads the plugin. We may not also need it in `enabledPlugins`.

**Test required:** Verify `--channels` alone provides:
- Bot process starts ✓
- MCP tools available (reply, react, edit_message, download_attachment) ✓
- Inbound notifications via `notifications/claude/channel` ✓

**Fallback:** If `enabledPlugins` is required alongside `--channels`, move it to a hub-only location (`/.claude/settings.local.json` — root directory, hub's working dir).

**1b. PID lock file in server.ts**

Patch the plugin to refuse startup if another instance is alive:
```typescript
const LOCK_FILE = join(STATE_DIR, 'telegram.lock')
if (existsSync(LOCK_FILE)) {
  const lockPid = parseInt(readFileSync(LOCK_FILE, 'utf8'))
  try { process.kill(lockPid, 0); process.exit(0) } catch {} // stale lock
}
writeFileSync(LOCK_FILE, String(process.pid))
process.on('exit', () => unlinkSync(LOCK_FILE))
```

**1c. telegram-guardian.sh (replaces kill-competing-telegram.sh)**

Identifies hub by `--channels` flag (not tmux session name), kills everything else. Runs as SessionStart hook AND cron.

### Layer 2: DETECT & KILL

**2a. Watchdog cron (every 30 seconds)**

- Counts telegram processes → kills extras via guardian
- Detects zombies (ppid=1) → kills them
- Detects zero processes → alerts
- Sends alerts via Bot API (works even when MCP is broken)

**2b. Fixed comms-check.sh**

- Fix process counting bug
- Identify correct process by parent chain, not by newest PID
- Add lock file verification
- Add MCP pipe health check

### Layer 3: ALERT

**3a. Bot API alerts to group chat**

Watchdog sends alerts directly via `curl` to Telegram Bot API — works even when MCP is disconnected, plugin is crashed, or hub is frozen.

Alert types:
- `🔴 Telegram is DOWN` — zero processes
- `⚠️ Killed N duplicate(s)` — watchdog cleaned up
- `⚠️ Killed orphaned zombie` — ppid=1 detected

---

## 7. Stress Test Matrix

| # | Scenario | Pass Criteria | Status |
|---|----------|---------------|--------|
| 1 | Hub starts clean | 1 telegram process, send + receive | Baseline verified |
| 2 | Agent subagent spawned | Still 1 process | **PASSED** |
| 3 | TeamCreate with teammates | Still 1 process (guardian kills extras) | **FAILED** (pre-fix) |
| 4 | /mcp reconnect | Old dies, new starts, 1 total | Not yet tested |
| 5 | start-spoke.sh node launch | Node has 0 telegram processes | Not yet tested |
| 6 | Hub crash (kill -9) + restart | Lock cleared, new process starts | Not yet tested |
| 7 | Harness spontaneous respawn (#36800) | Watchdog catches within 30s | Not yet tested |
| 8 | 3 teammates + /mcp + node simultaneously | Max 1 process | Not yet tested |
| 9 | Telegram silent for 60s+ | Alert in group chat | Not yet tested |
| 10 | Zombie process (ppid=1) | Watchdog kills within 30s | Not yet tested |
| 11 | Network drop 5 min | Bot reconnects, messages delivered | Not yet tested |
| 12 | Sleep/wake cycle | Bot reconnects | Not yet tested |

---

## 8. Design Limitations & Known Weaknesses

### What we CANNOT fix locally

| Issue | Why | Impact |
|-------|-----|--------|
| **#36800 — Spontaneous respawn** | CC harness bug, no local control | Duplicates can appear at any time with no trigger |
| **#37933 — Notification delivery** | MCP notification path bug in CC | Inbound messages silently lost even with 1 healthy process |
| **Plugin update overwrites patches** | server.ts PID lock gets erased on plugin update | Must re-patch after every update |

### Known gaps in our fix plan

- **30-second detection window** — Cron granularity means up to 30s of 409 conflicts before watchdog intervenes
- **PID lock race window** — Two processes could check the lock simultaneously and both proceed (unlikely but possible)
- **Notification bug (#37933) has NO local mitigation** — If the MCP notification path fails, we cannot detect or fix it from outside the CC harness
- **`--channels` sufficiency is unverified** — We have not yet tested whether removing `enabledPlugins` breaks the channel functionality
- **No inbound message verification** — Watchdog can verify process health but cannot verify that messages are actually being delivered to the session

### Architectural weakness

The fundamental problem is that the Telegram plugin's lifecycle is **coupled to Claude Code's process model**. Every new Claude process gets its own copy of every plugin. There is no singleton enforcement, no coordination between instances, and no way for the plugin to know if it's the "real" one or a duplicate.

---

## 9. Alternative Approaches Considered

### RichardAtCT/claude-code-telegram (Agent SDK approach)

A completely separate Telegram integration using the **Claude Agent SDK (Python)** instead of the official MCP plugin. Architecture: standalone Python bot → Claude Agent SDK → Claude API.

**Pros:** Architecturally immune to all three CC harness bugs. Bot lifecycle is decoupled from CC processes. Single bot process manages its own polling. Session persistence via SDK.

**Cons:** Requires Anthropic API key (costs money). Different auth model. No MCP integration (tools like Playwright, Firecrawl not available through Telegram). Significant migration effort.

**Verdict:** Strong long-term option if MCP bugs aren't fixed upstream.

### OpenClaw dedup pattern

Rather than preventing multiple pollers, **tolerate them** with deduplication:
- Update offset persistence (stores `lastUpdateId + botId` to disk)
- In-flight deduplication (tracks which update IDs are being processed)
- In-memory dedup as secondary guard

**Pros:** Eliminates message loss even with multiple pollers. No need to prevent spawning.

**Cons:** Requires patching the Grammy polling layer. Complex. May not solve the MCP pipe problem (messages still route to wrong session).

**Verdict:** Elegant but high complexity. Better suited as an upstream fix.

### Discord migration

**Finding:** The Discord plugin has the **same bugs** (#36800 comments confirm duplicate spawning affects Discord too). Migration to Discord would not solve the underlying problem.

---

## 10. References

- [anthropics/claude-code#38098](https://github.com/anthropics/claude-code/issues/38098) — Plugin auto-loads in all sessions
- [anthropics/claude-code#36800](https://github.com/anthropics/claude-code/issues/36800) — Harness spawns duplicates mid-session
- [anthropics/claude-code#37933](https://github.com/anthropics/claude-code/issues/37933) — MCP notifications not delivered
- [RichardAtCT/claude-code-telegram](https://github.com/RichardAtCT/claude-code-telegram) — Alternative SDK-based approach
- [claude-plugins-official PRs #812-#814](https://github.com/anthropics/claude-plugins-official) — Plugin-side mitigations
- Plugin source: `~/.claude/plugins/cache/claude-plugins-official/telegram/0.0.4/server.ts`
