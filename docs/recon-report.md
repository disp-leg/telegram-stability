# Telegram Bot Process Recon Report

**Date:** 2026-03-28
**Investigator:** Claude (systems engineer, recon only)
**Scope:** First-principles analysis of telegram bot process lifecycle, spawn triggers, and failure modes in the yuna Claude Code hub.

---

## 1. PLUGIN LIFECYCLE -- How a telegram bot process gets born and dies

### Source Files
- `/Users/dispatch/.claude/plugins/cache/claude-plugins-official/telegram/0.0.4/server.ts` (~1047 lines)
- `/Users/dispatch/.claude/plugins/cache/claude-plugins-official/telegram/0.0.4/.mcp.json`
- `/Users/dispatch/.claude/plugins/cache/claude-plugins-official/telegram/0.0.4/package.json`

Note: The actually-running process at time of investigation uses the path `/Users/dispatch/.claude/plugins/marketplaces/claude-plugins-official/external_plugins/telegram/` (PID 8164's command line), not the cache path. These may be symlinked or copied variants.

### Startup Sequence

1. **Claude CLI spawns bun.** The `.mcp.json` file defines:
   ```json
   {
     "mcpServers": {
       "telegram": {
         "command": "bun",
         "args": ["run", "--cwd", "${CLAUDE_PLUGIN_ROOT}", "--shell=bun", "--silent", "start"]
       }
     }
   }
   ```
   The `start` script in `package.json` is: `bun install --no-summary && bun server.ts`

2. **Two processes spawn.** First, `bun run --cwd ... --shell=bun --silent start` (PID 8164 in current tree) which then executes `bun server.ts` (PID 8166). The wrapper PID 8164 is a thin shim.

3. **server.ts initialization** (lines 1-70):
   - Loads `.env` from `~/.claude/channels/telegram/.env` for `TELEGRAM_BOT_TOKEN`
   - Registers `unhandledRejection` and `uncaughtException` handlers (lines 57-62) -- these keep the process alive on errors
   - Creates `Bot` instance with the token (line 70)

4. **MCP server connects via stdio** (line 616):
   ```typescript
   await mcp.connect(new StdioServerTransport())
   ```
   This establishes the stdin/stdout pipe between bun and the parent Claude process.

5. **Bot polling starts** (lines 1009-1046):
   ```typescript
   void (async () => {
     for (let attempt = 1; ; attempt++) {
       try {
         await bot.start({
           allowed_updates: ['message', 'callback_query', 'message_reaction'],
           onStart: info => { ... }
         })
         return // bot.stop() was called -- clean exit
       } catch (err) { ... }
     }
   })()
   ```
   `bot.start()` is grammy's long-polling loop. It calls `getUpdates` repeatedly with a long-poll timeout. The IIFE is fire-and-forget (`void`), meaning the MCP server and the polling loop run concurrently.

### Polling Setup

- grammy's `bot.start()` calls Telegram's `getUpdates` in a loop with `allowed_updates: ['message', 'callback_query', 'message_reaction']`
- The default grammy long-poll timeout is 30 seconds per `getUpdates` request
- Only ONE `getUpdates` consumer can be active per bot token at any time -- Telegram enforces this with HTTP 409

### Shutdown Sequence (lines 621-634)

```typescript
let shuttingDown = false
function shutdown(): void {
  if (shuttingDown) return
  shuttingDown = true
  process.stderr.write('telegram channel: shutting down\n')
  setTimeout(() => process.exit(0), 2000)   // Force-exit after 2s
  void Promise.resolve(bot.stop()).finally(() => process.exit(0))
}
process.stdin.on('end', shutdown)
process.stdin.on('close', shutdown)
process.on('SIGTERM', shutdown)
process.on('SIGINT', shutdown)
```

**Four triggers for shutdown:**
1. `stdin 'end'` event -- pipe closed by parent (Claude process exits or MCP disconnects)
2. `stdin 'close'` event -- same, different event timing
3. `SIGTERM` -- explicit termination signal
4. `SIGINT` -- interrupt signal (Ctrl+C)

**Shutdown behavior:**
- Sets `shuttingDown = true` (debounce guard)
- Calls `bot.stop()` which signals grammy to stop the `getUpdates` loop
- The current in-flight `getUpdates` request may take up to its long-poll timeout (~30s) to return
- **Force-exit at 2 seconds** via `setTimeout(() => process.exit(0), 2000)` -- does NOT wait for the full 30s grammy timeout
- `bot.stop()` resolving also triggers `process.exit(0)` via `.finally()`

### The 409 Retry Loop (lines 1006-1046)

```typescript
if (err instanceof GrammyError && err.error_code === 409) {
  const delay = Math.min(1000 * attempt, 15000)
  process.stderr.write(`telegram channel: 409 Conflict..., retrying in ${delay/1000}s\n`)
  await new Promise(r => setTimeout(r, delay))
  continue
}
```

- **Backoff:** linear, `1000ms * attempt`, capped at 15 seconds
- **Max retries:** NONE -- the loop is `for (let attempt = 1; ; attempt++)` -- it retries FOREVER
- **What happens:** Process keeps retrying every 15s indefinitely, writing to stderr each time
- **Exit conditions:** Only `bot.stop()` (clean shutdown), `"Aborted delay"` error (grammy internal when `bot.stop()` is called during sleep), or non-409 error (which causes `return` and the process stays alive but stops retrying)

**Critical finding:** A process stuck in the 409 retry loop will NEVER die on its own. It will retry every 15 seconds forever. The process remains alive, consuming resources and holding the event loop open. If the MCP pipe is still connected, the MCP server is still functional for tool calls (reply/react/edit), but inbound messages will never arrive because polling never succeeds.

### What Happens If Shutdown Fails

- The 2-second `setTimeout(() => process.exit(0), 2000)` is the safety net
- If `process.exit()` itself somehow fails (extremely unlikely), the process becomes a zombie
- The `unhandledRejection` and `uncaughtException` handlers (lines 57-62) catch errors but do NOT exit -- they log to stderr and keep the process alive. This is by design for handler errors but means the process is resilient against dying from internal errors
- `bot.catch()` (line 1002) also swallows handler errors without stopping polling
- **Net effect:** The process is designed to be extremely hard to kill accidentally. It survives unhandled promises, uncaught exceptions, and handler errors. Only explicit shutdown signals kill it.

---

## 2. SPAWN TRIGGERS -- What creates new telegram processes

### Direct `claude` CLI invocation

The yuna hub is launched via `start-yuna.sh` (line 5):
```bash
CLAUDE_CMD="claude --channels plugin:telegram@claude-plugins-official"
```

The `--channels` flag explicitly tells Claude to start the telegram plugin as a channel MCP server. This is the primary (intentional) spawn path.

### How `--channels` works

From changelog analysis:
- `--channels` was added as a research preview feature (changelog line 194)
- It allows MCP servers to PUSH messages into the session (not just respond to tool calls)
- The `plugin:telegram@claude-plugins-official` syntax tells Claude to look up the telegram plugin and start its MCP server
- This is SEPARATE from the `enabledPlugins` in settings.json

### Plugin inheritance: `enabledPlugins` in global settings.json

`/Users/dispatch/.claude/settings.json` (line 129):
```json
"telegram@claude-plugins-official": true
```

This is in the GLOBAL settings file. **Every Claude process that reads this file will attempt to enable the telegram plugin.** The critical question is: does enabling the plugin also start the MCP server?

Based on `.mcp.json`, the plugin defines an MCP server. When a plugin is "enabled," Claude starts its MCP server(s). So:
- **Global `enabledPlugins` with telegram: true = every Claude process starts a telegram bun process**
- This is independent of `--channels`. The `--channels` flag enables the channel/push-message functionality. The `enabledPlugins` enables the plugin's tools.

### `Agent` tool (subagents)

From changelog evidence:
- Changelog line 489: "Fixed `--print` hanging forever when team agents are configured -- the exit loop no longer waits on long-lived `in_process_teammate` tasks"
- Changelog line 588: "Fixed memory retention in in-process teammates where the parent's full conversation history was pinned"
- The term "in_process_teammate" appears multiple times

**Analysis:** Subagents spawned by the `Agent` tool appear to run IN-PROCESS (within the same Node.js/claude process). They share the parent's MCP connections. However, there's a key distinction:

- `Agent` tool with `run_in_background: true` -- based on changelog entries about "background subagents," these still appear to be in-process (same Claude process). They share the parent's MCP servers, meaning they do NOT spawn a new telegram bun process.

**However**, the error log (telegram-error-log.md line 44) states:
> "TeamCreate agent spawns start telegram bot -- each new Claude process launched by TeamCreate/Agent inherits the telegram plugin from global settings and starts its own bot process"

This suggests that AT LEAST TeamCreate agents (and possibly some Agent tool invocations) DO spawn new OS processes.

### `TeamCreate` / Agent Teams

From changelog analysis:
- Line 876: "Fixed Agent Teams teammates failing on Bedrock, Vertex, and Foundry by **propagating API provider environment variables to tmux-spawned processes**"
- Line 965: "Fixed agent teammate sessions in **tmux** to send and receive messages"
- Line 289: "Fixed teammate panes not closing when the leader exits"
- Line 290: "Fixed iTerm2 auto mode not detecting iTerm2 for **native split-pane teammates**"

**Critical finding:** Agent Teams teammates are spawned as SEPARATE tmux panes/processes. They are NOT in-process. Each teammate is a new Claude CLI process that:
1. Gets its own tmux pane
2. Reads global settings.json (including `enabledPlugins`)
3. Starts its own MCP servers (including telegram if enabled globally)
4. Runs its own `bun server.ts` for telegram

This is confirmed by the env var `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1` in settings.json and the observed behavior documented in the error log.

### `/mcp reconnect`

No explicit documentation on the internal mechanism was found, but from the error log (line 41):
> "/mcp reconnect created a NEW bot process (46651) while old stale one (26308 from 3AM) still running"

**Analysis:** `/mcp reconnect` appears to:
1. Start a NEW MCP server process (new bun process)
2. Does NOT kill the old one first
3. The old process may or may not receive a stdin EOF depending on whether the old pipe is properly closed

This is the second most common spawn trigger after TeamCreate.

### SSH connecting to tmux session

From the fix plan (line 26): "SSH attach/detach -- Reattaching to tmux via SSH can sometimes trigger MCP reconnection, spawning duplicates."

**Analysis:** tmux detach/reattach does NOT kill the Claude process or its children. The bun telegram process continues running through attach/detach cycles. However, if something in Claude's lifecycle triggers an MCP reconnect on reattach, a new process could spawn alongside the old one.

### `--channels` flag vs `enabledPlugins`

**Both paths can spawn a telegram process:**
1. `--channels plugin:telegram@...` -- explicitly requested on command line, starts the channel
2. `enabledPlugins: { "telegram@...": true }` -- in settings.json, starts the plugin's MCP server

The hub uses BOTH: `--channels` on the command line AND `enabledPlugins` in global settings. Subagents/teammates only get the `enabledPlugins` path (they don't inherit `--channels`).

**Where inheritance comes from:**
- Global `~/.claude/settings.json` -- read by ALL Claude processes
- Project-level `.claude/settings.local.json` -- can override (set telegram to false)
- `--channels` flag -- only on the specific CLI invocation, NOT inherited by subagents

---

## 3. PROCESS TREE -- Current state at investigation time

### Live Processes

```
PID    USER       %CPU  %MEM  COMMAND
717    dispatch   0.9   4.6   /opt/homebrew/bin/claude --channels plugin:telegram@claude-plugins-official
8164   dispatch   0.0   0.0   bun run --cwd /Users/dispatch/.claude/plugins/marketplaces/claude-plugins-official/external_plugins/telegram --shell=bun --silent start
8166   dispatch   0.0   0.4   /opt/homebrew/bin/bun server.ts
```

### Parent-Child Relationships (inferred from terminal session)

All three processes share `s001` (same terminal/tty), all marked `S+` (foreground process group):
```
PID 717 (claude) --> PID 8164 (bun run wrapper) --> PID 8166 (bun server.ts)
```

### tmux Sessions
```
yuna: 1 windows (created Sat Mar 28 11:53:43 2026) (attached)
```

Only one tmux session, one window. Clean state at time of investigation.

### Key Observations
- Single telegram process chain (healthy state)
- bun is running from the `marketplaces/` path, not the `cache/` path
- Claude was started at 11:53 AM, bun at 12:15 PM (22 minutes later -- likely from an /mcp reconnect or delayed plugin start)
- No orphaned processes (ppid=1) visible
- No duplicate claude or bun processes

---

## 4. SETTINGS INHERITANCE -- How subagents/teams get their config

### Agent Tool (Subagents)

Based on all available evidence:
- The `Agent` tool spawns in-process subagents that share the parent's MCP connections
- They do NOT start new OS processes
- They do NOT spawn new bun/telegram processes
- They inherit the parent's tools (including MCP tools from telegram)
- `run_in_background: true` still keeps them in-process, just non-blocking

**Subagents are NOT the problem** for duplicate telegram processes.

### TeamCreate (Agent Teams)

Based on changelog evidence (tmux-spawned processes, teammate panes):
- TeamCreate spawns SEPARATE Claude CLI processes in new tmux panes
- Each new process:
  1. Reads `~/.claude/settings.json` (global)
  2. Sees `"telegram@claude-plugins-official": true` in `enabledPlugins`
  3. Starts a new bun telegram MCP server
  4. That server tries to `getUpdates` --> 409 Conflict with the hub's telegram
- **This is the primary source of duplicate telegram processes**

### How to exclude plugins from teammates

- Project-level `.claude/settings.local.json` with `"telegram@claude-plugins-official": false` -- this works for spoke nodes launched by `start-spoke.sh`
- For teammates spawned by TeamCreate from the hub: they inherit GLOBAL settings. The hub's working directory is `/`, so project-level settings for the hub's project apply. But teammates may get their own project context.
- **There is no `--disabledPlugins` flag or per-agent plugin exclusion mechanism visible in the help output.**
- The `--bare` flag would skip plugins but also skips everything else (hooks, LSP, attribution, etc.)

### SessionStart Hooks and TeamCreate

`settings.json` defines a SessionStart hook:
```json
"SessionStart": [{
  "hooks": [{
    "type": "command",
    "command": "bash ~/.claude/kill-competing-telegram.sh",
    "async": true
  }]
}]
```

When a TeamCreate teammate starts, it triggers its own SessionStart hooks. The kill script now checks `tmux display-message -p '#S'` and exits if not in the `yuna` session. But:
1. The teammate IS in a tmux session (possibly yuna or a sub-session)
2. Even if the kill script runs, it kills OTHER telegram processes -- the teammate's own telegram process has already started
3. The kill script does NOT prevent the spawn -- it only kills after the fact

---

## 5. EXISTING DEFENSES -- What's been tried and why each failed

### Defense 1: `kill-competing-telegram.sh`

**File:** `/Users/dispatch/.claude/kill-competing-telegram.sh`

**What it does:**
1. Checks if running in yuna tmux session; exits if not
2. Walks up process tree to find parent Claude PID
3. Finds telegram bun process owned by that Claude
4. Loops 12 times (60s total), killing any telegram bun process that isn't the hub's

**What it catches:**
- Telegram processes from OTHER sessions that were running before this hook fired
- Stale zombie telegram processes from previous sessions

**What it MISSES:**
- **Race condition:** The teammate's OWN telegram process starts AFTER the hook fires. By the time the hook's kill loop runs, the teammate's telegram may not have started yet, or it may start between kill iterations.
- **Does not prevent spawning:** The hook runs after SessionStart, but the MCP server startup is part of session initialization. The telegram bun process may already be starting by the time the hook runs.
- **Self-identification is fragile:** Walking up the process tree with `ps -o ppid=` in a loop assumes the parent chain is stable and findable within 10 iterations.
- **Only runs in yuna:** Teammates in other tmux sessions/panes won't run this at all (by design -- the guard exits immediately if not yuna).

### Defense 2: `comms-check.sh`

**File:** `/Users/dispatch/.claude/comms-check.sh`

**What it does:**
1. Counts telegram bun processes (`pgrep -f "bun.*telegram"`)
2. Checks if bun's parent is PID 1 (orphan detection)
3. Checks webhook status
4. Tests send capability (DM + group)
5. `--fix` mode: keeps newest PID, kills duplicates

**What it catches:**
- Multiple running telegram processes
- Orphaned processes (ppid=1)
- Webhooks that would block long-polling
- Send failures

**What it MISSES:**
- **Cannot verify receive path:** Script explicitly notes it can't call `getUpdates` (would steal from grammy). Two-way receive verification requires in-session confirmation.
- **`--fix` heuristic is wrong:** Keeps the NEWEST PID (`tail -1`), but the NEWEST process may be a teammate's newly-spawned bot, not the hub's MCP-connected one. The correct one to keep is the one whose parent is the hub's Claude PID.
- **Not automated:** Must be manually invoked. No cron, no periodic hook.
- **MCP pipe health not verified:** Checks if parent is alive but doesn't verify the stdio pipe is actually functional. A process with a live parent but broken pipe would pass this check.

### Defense 3: Spoke settings with telegram disabled

**File:** `/Users/dispatch/.claude/scripts/start-spoke.sh` (lines 85-90)

```json
"enabledPlugins": {
  "superpowers@...": true,
  "feature-dev@...": true,
  // telegram NOT listed
}
```

And `/Users/dispatch/.claude/start-spoke.sh` (lines 36-47) explicitly injects:
```python
data.setdefault('enabledPlugins', {})['telegram@claude-plugins-official'] = False
```

**What it catches:** Spoke nodes launched via `start-spoke.sh` will not start telegram.

**What it MISSES:**
- **TeamCreate teammates from the hub.** These are NOT launched via `start-spoke.sh`. They are spawned by Claude's internal teammate mechanism into tmux panes, inheriting global settings.
- **Any direct `claude` invocation** without project-level overrides.

---

## 6. THE MCP TRANSPORT -- How the stdio pipe works

### StdioServerTransport (server.ts line 616)

The MCP connection uses stdin/stdout pipes:
- **Claude (parent) writes JSON-RPC to bun's stdin** -- tool calls (reply, react, edit_message, download_attachment)
- **Bun writes JSON-RPC to stdout** -- tool results, notifications (channel messages from Telegram)
- **stderr** is used for logging (not part of MCP protocol)

### What happens when tmux detaches

- tmux detach does NOT close the pipe. The Claude process keeps running, the bun process keeps running, stdin/stdout pipes remain open.
- tmux merely disconnects the terminal PTY from the user's display. The process group continues.
- **Telegram works fine through detach/reattach cycles** as long as nothing else triggers an MCP reconnect.

### What happens on `/mcp reconnect`

Based on observed behavior (error log line 41):
- `/mcp reconnect` starts a NEW bun process with a NEW stdio pipe
- The old bun process's stdin pipe MAY receive an EOF (triggering shutdown) or MAY be left dangling
- If the old process does NOT receive EOF, it continues running and polling -- creating a duplicate
- The behavior depends on whether Claude properly closes the old pipe before starting the new one

**Key uncertainty:** It is unclear from the code alone whether Claude closes the old MCP connection's pipe before opening a new one. The evidence from the error log (old process 26308 from 3 AM still running at 11 AM) strongly suggests it does NOT reliably close the old pipe.

### Can the pipe break without the process dying?

**Yes.** Several scenarios:

1. **Parent Claude dies suddenly (kill -9):** The stdin pipe gets EOF when the parent's file descriptors are closed by the kernel. The `process.stdin.on('end', shutdown)` handler fires. This SHOULD work for clean death.

2. **Pipe buffer fills (stdout):** If Claude stops reading from bun's stdout, the pipe buffer fills (usually 64KB on macOS). Bun's writes block. The process doesn't die, but MCP notifications stall. Telegram messages arrive but can't be delivered to Claude. The bot keeps polling.

3. **Claude process exists but isn't reading:** If Claude is stuck (e.g., permission dialog, context compaction), it stops reading the MCP stdout pipe. Same as above -- buffer fills, notifications stall.

### If the pipe breaks, does the bot keep polling?

The bot polling loop and the MCP server are completely independent:
- The polling loop runs via `void (async () => { ... })()` -- fire and forget
- The MCP server runs on stdio
- If stdin gets EOF, `shutdown()` is called which calls `bot.stop()`
- If stdout is merely blocked (not closed), the polling continues but notifications can't be delivered

**Zombie scenario:** If the stdin pipe is never explicitly closed (e.g., parent process leaked the fd), the bun process will never receive the 'end' event and will poll forever. The 2-second force-exit timer only fires AFTER shutdown() is called.

---

## 7. EDGE CASES -- Chaos engineering analysis

### Hub Claude crashes (kill -9)

- **What happens to bun:** The kernel closes all of PID 717's file descriptors, including the stdin pipe to bun. Bun's `process.stdin` emits 'end' or 'close'. The `shutdown()` function fires. `bot.stop()` is called. The 2-second force-exit timer starts. The process should die within 2 seconds.
- **Risk:** If bun is currently blocked in a write to stdout (Claude's side of the pipe is closed), the write may throw an EPIPE error. The `uncaughtException` handler catches this but does NOT call shutdown. However, the stdin 'end' event should fire independently.
- **Verdict:** LIKELY SAFE -- bun should die within 2 seconds of Claude crashing.

### tmux kill-session

- **Signal propagation:** `tmux kill-session` sends SIGHUP to all processes in the session's process groups. Claude (PID 717) receives SIGHUP. Claude's signal handling determines whether it forwards signals to children.
- **bun's behavior:** SIGHUP is NOT handled by the shutdown function (only SIGTERM, SIGINT, stdin end/close). If Claude doesn't forward SIGHUP to bun, and Claude dies from SIGHUP, then bun gets stdin EOF and shuts down via that path.
- **Risk:** If tmux sends SIGHUP to the entire process group (all PIDs in s001), bun receives SIGHUP directly. Bun's default SIGHUP behavior is to terminate. This would kill bun but NOT via the graceful shutdown path -- `bot.stop()` is never called, so the current `getUpdates` request stays open on Telegram's side for up to 30 seconds, blocking the next session.
- **Verdict:** MOSTLY SAFE but may leave a ~30s window where the next session gets 409s.

### macOS sleep/wake

- **Network behavior:** During sleep, TCP connections drop. The grammy `getUpdates` request times out or gets a network error when the OS wakes up.
- **grammy's behavior:** grammy has built-in retry logic for network errors. It will reconnect and resume polling after wake.
- **MCP pipe:** Pipes are in-kernel and survive sleep/wake. The stdio connection between Claude and bun is unaffected.
- **Verdict:** SAFE -- bot reconnects automatically after wake.

### Network drops for 5 minutes then returns

- **getUpdates behavior:** The current long-poll request will time out after ~30s. grammy retries. If the network is still down, the retry fails. grammy keeps retrying (with its own internal backoff).
- **Missed messages:** Telegram servers buffer undelivered updates for 24 hours. When the bot reconnects, it receives all missed updates via the next `getUpdates` call.
- **MCP pipe:** Unaffected (local).
- **Verdict:** SAFE -- all messages are delivered on reconnection, possibly with a burst.

### Two SSH clients attach to the same tmux session simultaneously

- **tmux behavior:** tmux allows multiple clients to attach to the same session. Both see the same pane content. Input from either client goes to the same process.
- **Impact on processes:** None. The Claude process, bun process, and pipes are unaffected. No new processes spawn.
- **Risk:** If one SSH client detaches and triggers some MCP reconnect logic, a duplicate could spawn. But mere attachment/detachment should not trigger MCP events.
- **Verdict:** SAFE -- no process impact from multiple clients.

### /mcp reconnect while a message is being processed

- **Scenario:** Telegram message arrives, bun writes notification to stdout, Claude is processing it, user runs /mcp reconnect.
- **What happens:**
  1. Claude starts a new bun process (new MCP connection)
  2. Old bun's stdin MAY get EOF (depends on Claude's implementation)
  3. If old bun gets EOF: it starts shutdown, bot.stop() is called, 2-second timer starts
  4. Any in-flight tool calls from Claude to the old bun will fail (pipe broken)
  5. New bun starts fresh, no state from old session
  6. If old bun does NOT get EOF: two pollers compete, 409 conflicts begin
- **Message loss:** The message that was being processed is already in Claude's context. The reply tool call may fail if it was targeting the old MCP server. Claude would need to retry via the new MCP connection.
- **Verdict:** HIGH RISK -- message being processed may have its reply fail. If old process doesn't die, duplicate pollers cause 409s.

---

## Summary of Key Findings

### The Core Problem

There are TWO independent paths that spawn telegram bot processes:

1. **`--channels` flag** on the hub's CLI invocation -- intentional, correct
2. **`enabledPlugins` in global settings.json** -- enables telegram for EVERY Claude process that reads global settings

TeamCreate teammates read global settings and start their own telegram MCP servers. This is the primary source of 409 conflicts.

### Why Existing Defenses Fail

| Defense | Prevents Spawn? | Kills Duplicate? | Reliable? |
|---------|-----------------|-------------------|-----------|
| kill-competing-telegram.sh | No | Yes (with delay) | Race conditions |
| comms-check.sh --fix | No | Yes (wrong heuristic) | Manual only |
| spoke settings.local.json | Yes (for spokes) | N/A | Only for start-spoke.sh |
| None of these | -- | -- | Covers TeamCreate |

### The 409 Retry Loop is a Time Bomb

When a duplicate spawns, the original process enters a 409 retry loop that retries FOREVER (no max attempts). The duplicate also retries forever. Neither dies. They compete indefinitely, each blocking the other from successful polling. Messages are randomly delivered to whichever process happens to win a given polling cycle -- and if that process's MCP pipe is broken, the message is lost.

### Stdin EOF is the Only Reliable Kill Signal

The shutdown function only fires on stdin EOF, SIGTERM, or SIGINT. If the parent Claude process dies cleanly, stdin EOF fires. But:
- `/mcp reconnect` may not close the old pipe
- TeamCreate teammates' Claude processes don't close the hub's telegram pipe
- The old bun process from a crashed Claude session becomes an orphan (ppid=1) that never receives EOF if the kernel didn't close the pipe (unlikely but possible if fd was leaked)

### No Singleton Enforcement

The telegram server.ts has NO mechanism to ensure only one instance runs:
- No PID file
- No lock file
- No check for existing processes before starting polling
- The 409 retry loop is designed as a WORKAROUND for duplicates, not prevention

---

## 8. UPSTREAM BUGS -- Three Distinct CC Harness-Level Issues

The problems documented in sections 1-7 are NOT purely configuration errors. They trace to at least three confirmed bugs in the Claude Code harness itself. These fundamentally change the analysis: local defenses (kill scripts, settings overrides) can only mitigate symptoms. The root causes require CC-side fixes.

---

### 8a. anthropics/claude-code#38098 -- Plugin auto-loads in all sessions

**Title:** "[BUG] Telegram plugin auto-loads in all Claude Code sessions, not just --channels sessions"
**Status:** OPEN, confirmed, labeled bug + has-repro

**Root Cause (from community source inspection):**

In Claude Code's `cli.js`, the plugin loading path reads `enabledPlugins` from `~/.claude/settings.json` at startup and **UNCONDITIONALLY starts the MCP server for every matching plugin** -- regardless of whether `--channels` was passed on the command line.

The two settings serve different purposes:
- **`enabledPlugins: { "telegram@...": true }`** -- causes the MCP server (bun server.ts) to start, which begins `getUpdates` polling
- **`--channels plugin:telegram@...`** -- marks that instance as the one that should handle inbound push messages

Both are required for the channel to work in the hub, but the decoupling means every Claude instance starts polling, even though only one should.

**What This Means:**

Every Claude Code process that reads global settings starts a telegram bot poller:
- TeamCreate teammates (confirmed -- these are separate tmux-spawned processes)
- Subagents spawned via `Agent` tool (if they run in separate processes)
- `/mcp reconnect` (starts a new process without killing the old one)
- VSCode sidebar instances of Claude Code
- Any `claude` CLI invocation from any terminal

**Community Workaround:**

Set `"telegram@claude-plugins-official": false` in project-level `.claude/settings.local.json` for all non-channel instances. This is already implemented in `start-spoke.sh` for spoke nodes but NOT enforced for TeamCreate teammates.

---

### 8b. anthropics/claude-code#36800 -- CC harness spawns duplicate channel plugin instances mid-session

**Title:** "Claude Code spawns duplicate channel plugin instances mid-session, causing 409 Conflict and tool loss"
**Status:** OPEN, labeled bug + has-repro + area:mcp

**This is the most critical finding.** Issue #38098 explains duplicates from TeamCreate/subagent/new-session spawns. Issue #36800 documents something worse: **the CC harness itself spawns a SECOND telegram bot process approximately 3 minutes into a HEALTHY session with no external trigger.**

**Key evidence from the issue:**

Instrumented logs show:
1. PID=62665 starts, connects, begins polling successfully
2. PID=62665 handles 10 tool calls, 8 notifications, zero errors -- fully healthy
3. ~3 minutes later, PID=69445 appears with no user action, no /mcp, no TeamCreate
4. Both processes now compete for the same token
5. 409 Conflict errors begin
6. Eventually one process's MCP pipe breaks and it loses tool connectivity

**This means:** Even with perfect configuration, even with no TeamCreate, even with no /mcp reconnect, even in a single-session single-window setup, the CC harness can spontaneously spawn a duplicate MCP server process. The trigger is internal to Claude Code's MCP management logic.

**Additional community reports from this issue:**
- `/mcp reconnect` triggers `stdin-close` on the EXISTING MCP server -- confirmed as a behavior. But the old process does not always die (consistent with our section 6 analysis of pipe EOF unreliability).
- The Discord plugin (`discord@claude-plugins-official`) exhibits the same duplicate-spawn behavior, confirming this is a harness bug, not telegram-plugin-specific.
- Plugin PRs #812, #813, #814 in the `claude-plugins-official` repo mitigate plugin-side damage (e.g., better shutdown handling, PID file attempts) but **do not fix the harness trigger**. The harness is what decides to spawn a new process; the plugin can only react.

**Implications for our setup:**
- The `kill-competing-telegram.sh` SessionStart hook cannot prevent this. The duplicate spawns mid-session, long after SessionStart.
- The `comms-check.sh` diagnostic cannot prevent this. It only runs on manual invocation.
- A cron-based watchdog (proposed in `telegram-fix-plan.md`) would detect this within its polling interval but introduces its own race conditions with the MCP-connected process.
- **There is no local defense against this bug.** It requires a CC harness fix.

---

### 8c. anthropics/claude-code#37933 -- MCP notification delivery failure (silent inbound loss)

**Title:** "Telegram plugin inbound messages not delivered to Claude Code session"
**Status:** OPEN, labeled bug + duplicate

**This is a SEPARATE issue from 409 conflicts.** Even with a single bot process and no duplicates, inbound messages can be silently lost.

**Key evidence:**

The telegram plugin calls `mcp.notification("notifications/claude/channel", ...)` successfully -- the MCP SDK reports no error, the JSON-RPC message is written to stdout. But the notification **NEVER appears in the Claude Code UI**. Claude never sees the `<channel>` tag. The message is consumed from Telegram's update queue (so it won't be re-delivered) but never surfaces.

**This means:**
1. The plugin's polling works correctly
2. The plugin's gate/access logic works correctly
3. The plugin's MCP notification call succeeds from its perspective
4. The Claude Code harness receives the JSON-RPC on its end of the stdio pipe
5. Somewhere between receiving the JSON-RPC and surfacing the `<channel>` tag, the message is dropped

**Community reports:**
- 4-person team using the plugin: outbound (reply/react/edit) works perfectly, inbound silently lost
- Some users switched from bun to node runtime, which fixed TCP/polling issues but notification delivery still fails
- Marked as duplicate (likely of #36800 or a related MCP notification routing issue)

**Implications for our setup:**
- This explains drops that occur WITHOUT 409 conflicts and WITHOUT duplicate processes
- From the error log (`telegram-error-log.md` line 12): "MCP transport drop -- Telegram plugin disconnects during SSH attach/detach. Messages arrive but never reach Claude." -- this may not be a transport drop at all; it may be this notification delivery bug
- Our comms-check.sh explicitly acknowledges it cannot verify the receive path. This bug is why: the receive path failure is INSIDE the CC harness, invisible to external diagnostics
- The only way to verify inbound delivery is to send a test message on Telegram and confirm Claude sees the `<channel>` tag -- there is no programmatic health check possible from outside

---

### 8d. Three bugs, three failure modes -- Complete map

| Bug | Failure Mode | Trigger | Frequency | Local Mitigation Possible? |
|-----|-------------|---------|-----------|---------------------------|
| #38098 | Extra pollers from other sessions | TeamCreate, new CLI, /mcp | Every team spawn | Partial (settings override per project) |
| #36800 | Extra poller from CC harness itself | Internal CC logic, ~3 min in | Every session (potentially) | None |
| #37933 | Inbound lost despite healthy plugin | Unknown CC-internal | Intermittent | None |

**Combined effect:** Even if #38098 is fully mitigated via settings.local.json everywhere, #36800 can still spawn duplicates mid-session, and #37933 can still drop inbound messages with no duplicate present. These three bugs compound: a session may experience all three simultaneously.

---

## 9. ALTERNATIVE ARCHITECTURE -- RichardAtCT/claude-code-telegram

A completely separate Telegram integration exists that uses the **Claude Agent SDK (Python)** instead of the MCP plugin model. This is relevant because it demonstrates an architecture that is immune to all three CC harness bugs.

### Architecture comparison

| Aspect | Official MCP Plugin | claude-code-telegram (SDK) |
|--------|--------------------|-----------------------------|
| Runtime | Bun (TypeScript), spawned by CC harness | Python, standalone process |
| Connection to Claude | MCP stdio pipe (child process of CC) | Claude Agent SDK (`ClaudeSDKClient`) |
| Bot framework | grammy (long-polling) | python-telegram-bot or similar |
| Process lifecycle | Controlled by CC harness (spawn, kill, reconnect) | Self-managed (systemd, supervisor, etc.) |
| Duplicate risk | High (CC harness spawns at will) | Zero (single standalone process) |
| Inbound delivery | MCP notification --> CC harness --> `<channel>` tag | SDK direct API call --> Claude response |
| Multi-turn state | CC session state (implicit) | SDK's `ClaudeSDKClient` (explicit stateful sessions) |

### SDK capabilities (from their docs/SDK_DUPLICATION_REVIEW.md)

The Claude Agent SDK provides:
- `ClaudeSDKClient` for stateful multi-turn conversations
- `can_use_tool` callbacks for permission control
- `max_budget_usd` for cost limits
- `allowed_tools` / `disallowed_tools` for tool filtering
- Direct API access without MCP intermediary

### Their internal audit findings

Their codebase had ~61% duplication with SDK native features, meaning many custom implementations (message routing, permission handling, session management) could be replaced by SDK primitives. This suggests the SDK is mature enough for production Telegram integration.

### Why this matters

The MCP plugin architecture ties the telegram bot's lifecycle to the CC harness, which is the source of all three bugs:
- CC harness spawns duplicate MCP servers (#36800)
- CC harness loads plugins unconditionally (#38098)
- CC harness drops MCP notifications (#37933)

The SDK architecture decouples the Telegram bot from the CC process lifecycle entirely. The bot is a standalone process that talks to Claude via API, not via a child-process stdio pipe. This eliminates the spawn/duplicate/notification-delivery failure modes at an architectural level.

**Trade-offs:**
- SDK approach requires API key management and direct API costs
- SDK approach loses the `--channels` push-notification integration (messages arrive via API polling, not injected into the CC session)
- SDK approach requires building session management that CC provides for free
- SDK approach means Claude responses go through the SDK, not through the CC terminal (different UX model)

---

## 10. REVISED SUMMARY -- The full picture

### Three layers of failure

**Layer 1: Configuration (our side, partially mitigable)**
- Global `settings.json` has `telegram@claude-plugins-official: true`
- TeamCreate teammates inherit this and spawn competing pollers
- `/mcp reconnect` doesn't kill old processes
- Mitigated by: project-level settings overrides, kill scripts, comms-check

**Layer 2: CC harness bugs (Anthropic's side, NOT mitigable locally)**
- #36800: Spontaneous mid-session duplicate spawn with no trigger
- #38098: Unconditional plugin loading regardless of --channels
- Both cause 409 conflicts; neither can be prevented by any local defense

**Layer 3: MCP notification delivery (Anthropic's side, NOT mitigable locally)**
- #37933: Inbound messages silently dropped between plugin and CC UI
- Occurs even with single healthy bot process
- Cannot be detected by any external diagnostic
- Cannot be prevented by any local defense

### What local defenses can and cannot do

| Defense | Layer 1 | Layer 2 | Layer 3 |
|---------|---------|---------|---------|
| settings.local.json per project | Prevents teammate spawns | No effect | No effect |
| kill-competing-telegram.sh | Kills extras (with races) | Kills extras (with races) | No effect |
| comms-check.sh | Detects multiples | Detects multiples | Cannot detect |
| PID lock file (proposed) | Prevents concurrent start | Prevents concurrent start | No effect |
| Watchdog cron (proposed) | Kills extras periodically | Kills extras periodically | No effect |
| SDK-based architecture (alternative) | Eliminates entirely | Eliminates entirely | Eliminates entirely |

### Process tree lifecycle -- complete model

```
claude --channels plugin:telegram@...  (PID 717, hub)
  |
  +-- bun run ... start  (PID 8164, MCP wrapper)
  |     +-- bun server.ts  (PID 8166, actual bot)
  |           +-- grammy getUpdates loop (infinite)
  |           +-- MCP stdio server (connected to PID 717)
  |
  +-- [TeamCreate teammate]  (new claude process in tmux pane)
  |     +-- bun run ... start  (DUPLICATE -- reads global settings)
  |           +-- bun server.ts  (DUPLICATE bot, 409 conflicts begin)
  |
  +-- [CC harness internal respawn]  (~3 min, #36800)
        +-- bun run ... start  (DUPLICATE -- spawned by CC itself)
              +-- bun server.ts  (DUPLICATE bot, 409 conflicts)
```

### The infinite 409 death spiral

Once two pollers exist:
1. Both call `getUpdates` on the same token
2. Telegram returns 409 to one of them
3. The rejected one retries after backoff (1s, 2s, ... 15s cap)
4. The other succeeds and grabs the update
5. If the successful one's MCP pipe is broken, the update is consumed but never delivered
6. Both keep retrying forever (no max attempts in the retry loop)
7. Neither dies unless explicitly killed or its stdin pipe receives EOF
8. Messages are randomly distributed between the two, with some going to the broken-pipe process and being lost

**This death spiral is the mechanism behind every documented drop in `telegram-error-log.md`.**
