
// ── SINGLETON LOCK ─────────────────────────────────────────────────────
// Only one telegram bot should poll per token. Bind a Unix domain socket
// as an atomic lock — if another instance is alive, exit immediately.
// This prevents 409 Conflict errors from competing getUpdates consumers.
// See: https://github.com/anthropics/claude-code/issues/38098
import { createServer as createNetServer, createConnection } from 'net'

const LOCK_SOCKET = join(STATE_DIR, 'telegram.sock')

async function acquireSingletonLock(): Promise<boolean> {
  if (existsSync(LOCK_SOCKET)) {
    const alive = await new Promise<boolean>(resolve => {
      const client = createConnection(LOCK_SOCKET)
      client.on('connect', () => { client.destroy(); resolve(true) })
      client.on('error', () => resolve(false))
      setTimeout(() => { client.destroy(); resolve(false) }, 500)
    })
    if (alive) {
      process.stderr.write(
        `telegram channel: another instance is running (socket lock held), exiting\n`,
      )
      return false
    }
    // Stale socket from crashed process — clean up
    try { unlinkSync(LOCK_SOCKET) } catch {}
  }

  return new Promise(resolve => {
    _lockServer = createNetServer()
    _lockServer.on('error', (err: NodeJS.ErrnoException) => {
      if (err.code === 'EADDRINUSE') {
        process.stderr.write('telegram channel: lock socket in use, exiting\n')
        resolve(false)
        return
      }
      // Non-lock error — proceed without lock (don't block startup)
      process.stderr.write(`telegram channel: lock warning: ${err.message}\n`)
      resolve(true)
    })
    _lockServer.listen(LOCK_SOCKET, () => {
      process.stderr.write(`telegram channel: singleton lock acquired (PID ${process.pid})\n`)
      resolve(true)
    })
    // Clean up socket on exit
    const cleanup = () => { try { unlinkSync(LOCK_SOCKET) } catch {} }
    process.on('exit', cleanup)
  })
}

// Expose lock server so shutdown() can close it first — eliminates the
// timing window where a dying instance still holds the lock (Risk 4).
let _lockServer: ReturnType<typeof createNetServer> | null = null
function releaseSingletonLock(): void {
  if (_lockServer) {
    _lockServer.close()
    _lockServer = null
  }
  try { unlinkSync(LOCK_SOCKET) } catch {}
}

if (!(await acquireSingletonLock())) {
  process.exit(0)
}
// ── END SINGLETON LOCK ─────────────────────────────────────────────────
