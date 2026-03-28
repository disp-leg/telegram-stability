# Telegram Error Log

Track every non-response, delayed response, or failed delivery. Goal: identify patterns and fix permanently.

## Format
| Timestamp | Type | Description | Root Cause | Resolution |
|-----------|------|-------------|------------|------------|
| 2026-03-28 02:06 | Pattern | Multiple non-responses reported by user across sessions | No systematic logging; causes unknown retroactively | Creating this log to track going forward |
| 2026-03-28 01:59 | Delayed | Group chat status message — attempted with garbage chat_id before correct send | Guessed chat_id instead of looking it up | Added feedback memory: always read reference_telegram.md for IDs |

## Known Failure Modes
1. **MCP transport drop** — Telegram plugin disconnects during SSH attach/detach. Messages arrive but never reach Claude.
2. **Context focus** — Deep in terminal work, incoming `<channel>` tags processed late or missed in long output.
3. **No retry** — Failed `reply` calls have no automatic retry. Silent failure.
4. **Duplicate bot process** — If two sessions start the same bot, polling conflicts cause message loss.
5. **Permission prompts** — Bash permission dialogs can block the response loop, delaying Telegram replies.

## Action Items
- [ ] Build alerting for missed messages (e.g., if no reply within 30s of receiving a `<channel>` tag)
- [ ] Investigate persistent MCP reconnect on SSH reattach
- [ ] Consider a watchdog script that monitors bot process health
- [ ] Review comms-check.sh for receive-path automation
## 2026-03-28 Session — 5 Telegram Drops in One Night

### Root Cause (IDENTIFIED)
TeamCreate agent spawns trigger SessionStart hooks, which start NEW telegram bot processes. Multiple bots poll the same API simultaneously → 409 Conflict errors → MCP disconnects. By end of night, 3 duplicate bot processes were running.

### Timeline of Drops
| # | Time | Cause | Fix Applied |
|---|------|-------|-------------|
| 1 | ~03:15 | kill-competing-telegram.sh from team agents killed hub's bot | Rewrote script with env var check (didn't work) |
| 2 | ~03:33 | Same — env vars not set on team agents | Rewrote script with tmux session check (worked for kill script) |
| 3 | ~03:37 | Duplicate bot processes from earlier agent spawns still running | Killed scripts manually |
| 4 | ~06:09 | TeamCreate agents spawned new bot processes again | Identified 3 duplicate processes |
| 5 | ~06:33 | Same duplicates still running | Found and killed 2 duplicates, kept 1 MCP-connected process |

### Drops continued — 2026-03-28 afternoon session
| # | Time | Cause | Fix Applied |
|---|------|-------|-------------|
| 6 | ~10:33 | 3 new team agents (ui-designer, animator, deployer) each spawned their own telegram bot process despite kill script fix | Killed 3 duplicates. Kill script only prevented the KILL, not the SPAWN. |
| 7 | ~11:07 | /mcp reconnect created a NEW bot process (46651) while old stale one (26308 from 3AM) still running | Killed old 26308, kept new 46651 |

### Root Causes (COMPLETE LIST)
1. **TeamCreate agent spawns start telegram bot** — each new Claude process launched by TeamCreate/Agent inherits the telegram plugin from global settings and starts its own bot process
2. **kill-competing-telegram.sh only prevents killing, not spawning** — the fix stopped agents from killing the hub's bot, but didn't stop them from STARTING their own bots
3. **/mcp reconnect creates new process without killing old** — running /mcp adds a new bot process alongside any existing ones
4. **Stale processes accumulate** — bot processes from hours ago stay running, causing 409 conflicts with newer ones

### Fixes Applied
1. kill-competing-telegram.sh rewritten — exits if not in yuna tmux session
2. **Telegram plugin DISABLED in node settings.local.json** — node agents will never start a bot process
3. Manual duplicate process kills after each incident
4. Added "verify single telegram process" to post-launch and post-/mcp checklists

### Outstanding Issues
- Global settings still have telegram enabled — any NEW node created from the start-spoke.sh template will inherit it unless the template is updated
- No automatic duplicate detection — relies on manual ps check or comms-check.sh
- /mcp always spawns a new process — need to kill old one BEFORE reconnecting

### Action Items
- [x] Fix kill-competing-telegram.sh to protect hub's PID
- [x] Identify root cause of repeated drops
- [x] Disable telegram in node settings.local.json
- [ ] Update start-spoke.sh template to exclude telegram plugin from node settings
- [ ] Add automatic duplicate bot kill to comms-check.sh --fix
- [ ] Add pre-/mcp hook that kills existing bot process before reconnect
- [ ] Add post-TeamCreate hook that verifies only 1 telegram process exists
- [ ] Build alerting for missed messages
- [ ] Consider a watchdog cron that kills duplicate bots every 60s
