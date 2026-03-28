# Telegram Startup Checklist

Use at session start, after /mcp, or whenever Telegram seems broken.

---

## Yuna (Automated — run `bash ~/.claude/comms-check.sh`)

| # | Check | What it verifies | Pass criteria |
|---|-------|-----------------|---------------|
| 1 | Singleton lock socket | Lock is active | `~/.claude/channels/telegram/telegram.sock` exists |
| 2 | Process count | No duplicates | Exactly 1 `bun.*telegram` process |
| 3 | Parent chain | MCP pipe intact | bun's parent is Claude (not ppid=1 zombie) |
| 4 | Patches applied | Singleton + reactions | `SINGLETON LOCK` found in server.ts |
| 5 | Outbound send | Bot can send | DM + group message both deliver |
| 6 | Two-way receive | Inbound works | Operator replies, `<channel>` tag appears in session |

## Operator (Manual — at the terminal or via Telegram)

| # | Step | When | What to do |
|---|------|------|-----------|
| 1 | Start session | After reboot or new tmux | Verify comms-check runs in SessionStart hook output |
| 2 | Reply to comms check | When bot sends "Comms check" DM | Reply with any word — confirms inbound path |
| 3 | If bot goes silent | No response for 2+ min | Run `/mcp` at the terminal to restart plugin |
| 4 | If bot replies but ignores you | Outbound works, inbound doesn't | Run `/mcp` — likely #37933 (notification delivery bug) |
| 5 | If watchdog alerts | "Telegram is DOWN" in group | Run `/mcp` at the terminal |
| 6 | After plugin update | After `claude plugins update` | Run `bash ~/.claude/patches/telegram-singleton.sh` to re-apply patch, then `/mcp` |

## Two-Way Verification Protocol

1. Yuna sends "Comms check" message to John's DM (msg_id noted)
2. Yuna sends status to group chat
3. **Operator replies to the DM** (any word)
4. Yuna watches for `<channel>` tag to appear in session
5. If received within 30s → "Two-way confirmed"
6. If NOT received → "Two-way FAILED — run /mcp"

## Quick Troubleshooting

| Symptom | Likely Cause | Fix |
|---------|-------------|-----|
| Bot completely silent | Process dead or MCP disconnected | `/mcp` |
| Bot sends but ignores messages | #37933 notification bug | `/mcp` |
| "409 Conflict" in logs | Duplicate process (shouldn't happen with lock) | Check `pgrep -f 'bun.*telegram'`, kill extras |
| Socket file missing | Patch not loaded | `bash ~/.claude/patches/telegram-singleton.sh` then `/mcp` |
| Watchdog spamming alerts | False positive or real issue | Check process count, verify manually |
