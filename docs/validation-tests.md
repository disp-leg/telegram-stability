# Validation Test Results

**Date:** 2026-03-28
**Tested by:** Yuna (hub session)
**Environment:** Claude Code 2.1.85, macOS, tmux "yuna"

---

## Test B: inbox/ Directory IPC Mechanism

**Hypothesis:** Solutions B, D, and E can use the `~/.claude/channels/telegram/inbox/` directory to deliver inbound messages to CC from an external process.

**Method:** Read server.ts source code to understand how inbox/ is used and how inbound messages are actually delivered.

**Findings:**

1. **inbox/ is for ATTACHMENTS only** (photos, videos, files). It is NOT a message delivery channel. Source: `server.ts:462` — `download_attachment` tool description: "Download a file attachment from a Telegram message to the local inbox."

2. **Inbound messages are delivered via MCP notification.** The `handleInbound()` function (line 876) processes each message and calls:
   ```typescript
   mcp.notification({
     method: 'notifications/claude/channel',
     params: { content: text, meta: { chat_id, message_id, ... } }
   })
   ```
   This writes to the MCP stdio pipe (stdout). CC reads it on the other end.

3. **There is NO file-based message delivery mechanism.** Messages go exclusively through the stdio pipe between bun and Claude. An external process has no way to inject messages into this pipe.

**Result: HYPOTHESIS INVALIDATED.**

Solutions B, D, and E as currently designed **CANNOT work** — they assumed inbox/ is a message delivery channel, but it's only for attachments. The actual delivery path is `mcp.notification()` → stdout pipe → Claude, which requires an in-process MCP connection.

**Impact on solutions:**
- **Solution B (Standalone Poller):** Must be redesigned. Cannot just write to inbox/. Would need to either: (a) write a custom MCP server that acts as a bridge, or (b) use a completely different IPC mechanism (e.g., the standalone process IS the MCP server, launched by Claude).
- **Solution D (Webhook):** Same problem. Webhook receiver needs MCP connection to deliver messages.
- **Solution E (Reverse Proxy):** Same fundamental issue. The proxy needs an MCP connection to CC.

**Revised understanding:** The MCP stdio pipe is the ONLY path for inbound messages. Any solution must either:
1. Be the process connected to CC via stdio (i.e., be the MCP server that CC launched), OR
2. Find an alternative way to inject messages into the CC session (unclear if one exists)

---

## Test D: Tailscale Funnel Availability

**Hypothesis:** Tailscale Funnel can be used for webhook-based Telegram integration.

**Method:** Checked Tailscale version, funnel status, and network health.

**Findings:**

1. **Tailscale version:** 1.96.2 (supports Funnel)
2. **Funnel status:** "No serve config" — NOT configured
3. **Network health warnings:**
   - "MagicSock ReceiveIPv4 not running — connectivity issues possible"
   - "Could not connect to Honolulu relay server"
4. **iPhone offline** — last seen 15h ago

**Result: PARTIALLY VIABLE.**

Tailscale Funnel is available in the installed version but not configured. Network health has warnings. Would need:
- Configure Funnel (`tailscale funnel 8443`)
- Verify HTTPS endpoint is reachable from internet
- May need to fix relay connectivity first

**Impact:** Solution D is viable but requires infrastructure setup AND has the same MCP delivery problem as Test B found.

---

## Test F: --channels Sufficiency Without enabledPlugins

**Hypothesis:** The `--channels` flag alone loads the telegram plugin and provides MCP tools, without needing `enabledPlugins: true` in settings.json.

**Method:** Attempted to inspect Claude CLI source code. Attempted to find documentation.

**Findings:**

1. **Claude binary is native arm64** (Mach-O executable, not JS) — cannot inspect source code directly
2. **No `--channels` flag in `claude --help` output** — the flag exists (hub uses it) but is undocumented
3. **No changelog found** in standard locations
4. **Cannot determine behavior without empirical test** — but empirical test requires restarting the hub, which would take Telegram offline

**Result: INCONCLUSIVE — cannot test safely without risking live Telegram.**

**Safe test approach:** Start a SECOND Claude session in a different tmux window with `--channels` but with a project-level settings.local.json that has `telegram: false`. If that session gets telegram tools, then `--channels` alone is sufficient. This test wouldn't affect the live hub.

**Impact:** Solution F remains unvalidated. It's the fastest potential fix but we can't confirm it works without risking downtime or running a parallel test session.

---

## Test A: Environment Variable Inheritance in TeamCreate

**Hypothesis:** tmux-scoped environment variables are NOT inherited by TeamCreate teammates, so an env var gate in server.ts would prevent teammates from polling.

**Method:** Set a test env var in tmux, checked if current process and subagents see it.

**Findings:**

1. **`tmux set-environment` sets vars for NEW windows/panes only** — it does NOT retroactively set them in existing processes
2. **Current process does NOT see the tmux env var** — confirmed: `TELEGRAM_POLL_TEST` is empty in `env` output
3. **TeamCreate spawns teammates in new tmux panes** — new panes DO inherit tmux environment variables (this is how tmux works)
4. **Therefore: TeamCreate teammates WOULD see the env var** — `tmux set-environment` → new pane → new shell → inherits tmux env

**Result: HYPOTHESIS INVALIDATED.**

If we set `TELEGRAM_POLL=1` in tmux environment, TeamCreate teammates in new tmux panes WOULD inherit it. The env var gate would NOT prevent teammates from polling.

**Alternative:** Instead of gating on presence of a var, gate on absence. Set `TELEGRAM_NO_POLL=1` in teammate settings... but we can't control teammate env vars.

**Revised approach for Solution A:** Instead of tmux env, use a process-specific mechanism:
- Gate on `--channels` flag presence (check `process.argv`)
- Gate on a file lock or socket
- Gate on the parent process being the hub's Claude PID

**Impact:** Solution A as originally designed is invalidated. Needs redesign to use a different gating mechanism.

---

## Summary: What Survived Validation

| Solution | Original Rank | Validation Result | New Status |
|----------|--------------|-------------------|------------|
| B (Standalone Poller + launchd) | 1 | **INVALIDATED** — inbox/ is for attachments, not message IPC | Needs complete redesign |
| D (Webhook + Tailscale) | 2 | **PARTIALLY INVALIDATED** — same IPC problem as B, plus Funnel not configured | Needs redesign |
| E (Reverse Proxy Bot) | 3 | **INVALIDATED** — same IPC problem | Needs redesign |
| C (Unix Socket Lock) | 4 | Not yet tested (empirical bun test needed) | Pending |
| A (Env Var Gate) | 5 | **INVALIDATED** — TeamCreate panes inherit tmux env | Needs redesign |
| F (Settings Trick) | 6 | **INCONCLUSIVE** — can't test safely | Needs isolated test |
| G (PID Lock File) | 7 | Not directly tested | Theoretical only |
| H (Watchdog Scripts) | 8 | Already known to be reactive only | Band-aid |
| I (OpenClaw Dedup) | 9 | Not tested | Theoretical only |

### Critical Discovery

**The MCP stdio pipe is the ONLY path for inbound messages.** There is no file-based IPC, no shared memory, no HTTP endpoint. The bun process MUST be connected to Claude via stdin/stdout to deliver messages.

This means ANY solution that runs the telegram bot as a separate, independently-managed process CANNOT deliver inbound messages to CC — unless it IS the MCP server that CC launched.

**This fundamentally changes the solution space.** The viable approaches are:

1. **Prevent duplicate MCP servers from starting** (Solutions C, F, G — singleton enforcement)
2. **Patch the MCP server to be smarter** (detect and refuse to poll if another instance is polling)
3. **Replace the MCP server with one that handles the singleton problem** (custom plugin)
4. **Accept the CC harness manages the process and focus on making it resilient** (dedup, graceful handoff)
