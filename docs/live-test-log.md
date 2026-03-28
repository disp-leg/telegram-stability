## Live Verification — 2026-03-28 18:41

| # | Check | Result | Evidence |
|---|-------|--------|----------|
| 1 | Socket file exists | ✅ | `srwxr-xr-x ~/.claude/channels/telegram/telegram.sock` |
| 2 | Process count = 1 | ✅ | `pgrep` returned 1 |
| 3 | Hook in settings.json | ✅ | `telegram-singleton` found in SessionStart hooks |
| 4 | Cron active | ✅ | `crontab -l` shows watchdog entry |
| 5 | Patch in marketplace | ✅ | 2 SINGLETON LOCK markers |
| 6 | Patch in cache | ✅ | 2 SINGLETON LOCK markers |
| 7 | Outbound send | ✅ | Message delivered to group chat |
| 8 | Inbound receive | ✅ | Ria replied "Working", received via `<channel>` tag |
| 9 | Duplicate rejection | ✅ | Second instance: "another instance is running (socket lock held), exiting" |
| 10 | Watchdog silent when healthy | ✅ | No output on healthy system |

### Bugs Found During Deployment

1. **Unterminated string literal (line 87):** Python3 string replacement converted `\n` to literal newlines inside TypeScript string literals. Fixed by manually correcting the escaped sequences.

2. **Missing `existsSync`/`unlinkSync` import:** The singleton lock used `existsSync` and `unlinkSync` from `fs`, but these weren't in the original file's import list. Fixed by adding to the `fs` import.

### Lessons Learned

- Always test the patch by running `bun server.ts` directly BEFORE `/mcp` restart
- Python3 heredoc string escaping is fragile for TypeScript code — use template files instead
- The integration test cleanup must never kill the ONLY remaining process
