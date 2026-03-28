# Risk Mitigations

**Date:** 2026-03-28
**Method:** Systematic debugging applied to each identified weakness

---

## Risk 1: Plugin Updates Overwrite the Patch

**Severity:** Medium — patch lost on update, but running process unaffected until restart.

**Analysis:** The telegram-reactions.sh patch already solves this exact problem. It runs as a SessionStart hook and re-applies idempotently. We follow the same proven pattern.

**Mitigation:**
1. Add `apply-patch.sh` to the SessionStart hooks in `~/.claude/settings.json`
2. The script is idempotent — checks if patch is already applied before modifying
3. Worst case: plugin updates mid-session don't affect the running process (the patched bun is already loaded in memory)
4. Next session start: hook fires, re-applies patch, new bun process starts with lock

**Residual risk:** If CC hot-reloads plugins mid-session (unverified behavior), the running process could be replaced with an unpatched one. Unknown probability. Manual `/mcp` reconnect after plugin updates is the safest practice.

**Status: MITIGATED** — same proven pattern as existing patches.

---

## Risk 2: #36800 Harness Respawn Gap

**Severity:** Low — self-healing, no message loss.

**Analysis:** From #36800 instrumented logs, the harness spawns a SECOND instance alongside the first — it does NOT kill-then-replace. With our lock:

**Scenario A (concurrent spawn, per #36800 logs):**
1. Instance A holds lock, polling normally
2. Harness spawns Instance B
3. Instance B tries to acquire lock → FAILS → exits immediately
4. Instance A continues uninterrupted
5. **No gap. No message loss.**

**Scenario B (kill-then-replace, theoretical):**
1. Harness closes Instance A's stdin → shutdown() fires
2. `releaseSingletonLock()` runs FIRST (Risk 4 fix) → socket released
3. Instance B starts → socket available → acquires lock → polls
4. Instance A continues `bot.stop()` → force exit within 2s
5. **Gap: near zero** because lock is released before process exits
6. **No message loss** — Telegram buffers updates for 24 hours

**Mitigation:** The lock + early release handles both scenarios. Telegram's 24-hour update buffer ensures no messages are lost even in the theoretical gap.

**Status: MITIGATED** — by design.

---

## Risk 3: #37933 MCP Notification Delivery Failure

**Severity:** High — no local fix. Silent message loss.

**Analysis:** This bug is in the CC harness's MCP notification consumption path. The plugin sends `mcp.notification()` successfully (confirmed in debug logs), but CC never surfaces the `<channel>` tag. This is completely independent of the duplicate poller problem.

**Attempted mitigations considered:**
1. ❌ Heartbeat ping — can't add watcher code to CC side
2. ❌ getUpdates verification — would steal from grammy
3. ❌ Response-time monitoring — can't track receive timestamps from outside CC
4. ❌ Automated restart — no trigger signal available

**What we CAN do:**
1. **Operator awareness protocol:**
   - If the bot replies to your messages (outbound works) but ignores new messages (inbound fails) → likely #37933
   - Fix: run `/mcp` at the terminal to force MCP reconnect
   - If no terminal access: no fix possible remotely
2. **Watchdog alert for total silence:**
   - If NO Telegram activity (neither send nor receive) for >5 minutes, watchdog sends Bot API alert
   - This catches #37933 only if it causes complete silence (not always the case — outbound may still work)
3. **Document the bug** for operators with clear symptoms and fix steps

**Residual risk:** Silent, undetectable message loss. No automated fix exists outside the CC harness. This is a fundamental limitation of our architecture.

**Status: PARTIALLY MITIGATED** — operator awareness + watchdog for total silence. No automated fix possible.

---

## Risk 4: 500ms Connect Timeout During Stale Detection

**Severity:** Low (was Medium before fix).

**Analysis:** If Instance A is shutting down (in the 2s force-exit window) and Instance B starts, B's connect-test succeeds because A's lock server is still listening. B exits thinking A is alive. A then exits. Zero instances running.

**Root cause:** The lock server stays open during the entire shutdown sequence.

**Mitigation: Early lock release.**

Added `releaseSingletonLock()` as the FIRST action in `shutdown()`:

```typescript
function shutdown(): void {
  if (shuttingDown) return
  shuttingDown = true
  releaseSingletonLock()  // ← Release lock BEFORE bot.stop()
  process.stderr.write('telegram channel: shutting down\n')
  setTimeout(() => process.exit(0), 2000)
  void Promise.resolve(bot.stop()).finally(() => process.exit(0))
}
```

**After fix:**
1. Instance A starts shutdown → lock released immediately
2. Instance B starts → socket gone → stale detected → acquires lock → polls
3. Instance A continues shutdown → bot.stop() → force exit
4. **Zero-second gap** — B can start as soon as A begins shutting down

**Status: FIXED** — early lock release eliminates the timing window entirely.

---

## Summary

| Risk | Severity | Mitigation | Residual Risk |
|------|----------|------------|---------------|
| 1. Patch overwritten by updates | Medium | SessionStart hook re-applies (proven pattern) | Mid-session hot-reload (unverified) |
| 2. Harness respawn gap | Low | Lock + early release + Telegram 24h buffer | None meaningful |
| 3. #37933 notification failure | High | Operator awareness + watchdog for silence | Silent undetectable message loss |
| 4. Stale detection timing | Low → Fixed | Early lock release in shutdown() | None — timing window eliminated |
