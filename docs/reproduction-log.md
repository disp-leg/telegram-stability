# Telegram Bug — Live Reproduction Log

**Date:** 2026-03-28 ~16:55 UTC
**Reproduced by:** Yuna (hub session)
**Environment:** Claude Code 2.1.85, macOS, tmux "yuna", telegram plugin 0.0.4

---

## Test 1: Subagent Spawn (Agent tool)

**Hypothesis:** Agent tool subagents share parent's MCP, don't spawn new processes.

**Method:** Spawned a background agent, checked pgrep counts during execution.

**Result:** ✅ CONFIRMED — No new telegram bun processes. Subagents are in-process.

| Metric | Before | During | After |
|--------|--------|--------|-------|
| bun.*telegram count | 1 | 1 | 1 |
| server.ts count | 1 | 1 | 1 |

**Conclusion:** Agent tool subagents are SAFE. They do not cause 409 conflicts.

---

## Test 2: TeamCreate

**Hypothesis:** TeamCreate spawns separate Claude processes that inherit global settings and start their own telegram pollers.

**Method:** Created team "tg-stress-test", monitored processes before/during/after.

**Result:** 🔴 CONFIRMED — Teammate killed hub's telegram.

### Timeline (exact PIDs):

| Time | Event | Hub Telegram | Teammate Telegram |
|------|-------|-------------|-------------------|
| Before | Hub healthy | PID 8164 (parent: 717) | — |
| TeamCreate | Team created | PID 8164 | — |
| +3s | Teammate spawned | PID 8164 → DEAD | PID 11415 (parent: 11398) |
| +5s | Damage assessed | GONE — 0 telegram children | PID 11415 alive |

### Process Tree After Damage:

```
Hub Claude (717) children:
  PID 6149: npm exec @playwright/mcp@latest   ← other MCP servers survived
  PID 6150: npm exec @upstash/context7-mcp
  PID 6209: npm exec firecrawl-mcp
  *** NO telegram bun child ***

Teammate Claude (11398) children:
  PID 11406: npm exec @playwright/mcp@latest   ← teammate got ALL the same plugins
  PID 11407: npm exec @upstash/context7-mcp
  PID 11415: bun run --cwd .../telegram        ← STOLE the telegram connection
  PID 11467: npm exec firecrawl-mcp
```

### What happened inside:
1. Teammate Claude (11398) started and read `~/.claude/settings.json`
2. Saw `"telegram@claude-plugins-official": true` in `enabledPlugins`
3. Started its own `bun server.ts` (PID 11415)
4. bun called `bot.start()` → `getUpdates` → 409 Conflict with hub's poller
5. Hub's telegram bun (8164) entered 409 retry loop
6. Hub's telegram bun eventually died (process exited — either crash or retry gave up)
7. Teammate's bun won the polling slot
8. Hub lost MCP connection to telegram → all tools unavailable
9. Hub went SILENT on Telegram with no indication to users

### Key observation:
The teammate also inherited playwright, context7, and firecrawl MCP servers. This isn't just a telegram problem — ALL MCP plugins get duplicated by TeamCreate.

---

## Test 3: Pattern Matching Bug

**Finding:** `pgrep -la "bun.*telegram"` shows short command names only (just "bun"), but `pgrep -f "bun.*telegram"` matches full command line args. The `-la` vs `-f` distinction is critical.

**Impact:** Any script using `-la` pattern will fail to find telegram processes. Current scripts use `-f` so they should work, but this is a trap for future scripts.

**Additional finding:** `pgrep -af "bun"` matches many unrelated system processes (powerd, containermanagerd, SafariBookmarks, etc.) because "bun" appears in their bundle paths. Pattern needs to be more specific.

---

## Conclusions

1. **Subagents (Agent tool) are safe** — in-process, share parent MCP, no new processes
2. **TeamCreate is the primary killer** — spawns separate OS processes that inherit ALL global plugins including telegram
3. **The 409 conflict doesn't just create duplicates — it KILLS the hub's telegram** — the hub's process dies, leaving only the teammate's (which is connected to the wrong session)
4. **The kill-competing-telegram.sh hook runs too late** — by the time it fires, the damage is done. The teammate's telegram is already polling and the hub's is already in 409 retry
5. **REMOVING telegram from global enabledPlugins is the single most important fix** — it stops TeamCreate teammates from ever starting a poller
