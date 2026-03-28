# After-Action Report: Telegram Singleton Lock

**Date:** 2026-03-28
**Duration:** ~4 hours (investigation + implementation)
**Outcome:** Singleton lock deployed and verified. 10/10 checks passed.

---

## What Went Well

1. **First-principles recon was thorough.** Reading server.ts line by line revealed the infinite 409 retry loop, the shutdown sequence, and the fact that polling and MCP are independent — all critical to designing the fix.

2. **Live reproduction proved the bug definitively.** Spawning a TeamCreate team and watching the hub's telegram die in real time (exact PIDs, process trees) was the strongest evidence in the report.

3. **Validation testing eliminated 5/9 solutions before any code was written.** The inbox/ IPC discovery (attachments only, not messages) saved hours of building something that would never work.

4. **Unix socket lock is a clean, atomic solution.** No race conditions, stale recovery works, and the early lock release (Risk 4 fix) eliminates the handoff gap.

5. **Operators stayed informed throughout.** Alerts via Bot API when TG went down, advance warning before /mcp restarts.

## What Went Wrong

1. **First plan was band-aids.** The initial "3-layer" plan (kill scripts, watchdogs, crons) was reactive, not preventive. Ria correctly called it out as not being first-principles.

2. **Proposed 9 solutions without testing any.** The self-audit revealed this — rankings were theoretical, not evidence-based. 5 were invalidated by simple 2-minute tests.

3. **Python3 string escaping broke the patch.** Using heredocs with template literals (`\n`, backticks, `${}`) through python3 is a minefield. Literal newlines appeared inside TypeScript string literals. Should have used a template file from the start.

4. **Missing `existsSync`/`unlinkSync` import.** Didn't check what the original file imported before using these functions. Basic oversight — Phase 3.2 of CLAUDE.md says "Read Before You Edit."

5. **Integration test cleanup killed the hub.** The `pgrep -P $HUB_PID` pattern didn't find the hub's bun child correctly, so it killed everything. Never run cleanup that can kill the ONLY remaining process.

6. **3 `/mcp` restarts needed during Task 6.** Each restart briefly killed TG. Should have been 1 restart if the patch was correct the first time.

7. **TeamCreate in-process state blocked all Agent spawns.** The earlier stress test's TeamCreate left stale state that prevented all subagent dispatches for the rest of the session. Had to switch from subagent-driven to inline execution.

## Best Practices to Add to Memory

1. **Always test patches by running `bun server.ts` directly in a subprocess BEFORE doing `/mcp`.** This catches syntax errors without killing live TG.

2. **Use template files for code injection, not heredocs.** Store the TypeScript block as a `.ts` file and read it in the patch script. Avoids all escaping issues.

3. **Check imports before using functions.** When patching a file, verify the functions you use are actually imported. `grep` the import line first.

4. **Never run cleanup that can result in zero processes.** Always check count AFTER cleanup. If it would be 0, abort.

5. **Validate solutions before ranking.** A 2-minute empirical test is worth more than 30 minutes of theoretical analysis.

6. **TeamCreate leaves in-process state that blocks future Agent calls.** Avoid TeamCreate in the hub session for testing. Use isolated scripts instead.

7. **The MCP stdio pipe is the ONLY inbound message path.** No file-based IPC exists for Telegram messages. Any solution must work within or replace the MCP plugin, not around it.

8. **Bot API (`curl`) works as a fallback when MCP is down.** Always use it for alerts and diagnostics. It's the only communication path that survives all failures.

## Metrics

| Metric | Value |
|--------|-------|
| Solutions proposed | 9 |
| Solutions invalidated by testing | 5 |
| Solutions validated | 1 |
| Stress test scenarios | 6/6 passed |
| Live verification checks | 10/10 passed |
| TG drops during implementation | 3 (all recovered) |
| Bugs in first patch attempt | 2 (escaping + missing import) |
| /mcp restarts required | 4 total |
| GitHub commits | 10 |

## Remaining Work

1. **Patch script updated** — now uses template file approach (singleton-lock-block.ts)
2. **#37933 monitoring** — no fix, operator awareness only
3. **Watchdog could be enhanced** — add response-time tracking if feasible
4. **Consider contributing the fix upstream** — the socket lock could be proposed as a PR to claude-plugins-official
