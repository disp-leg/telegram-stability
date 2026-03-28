import { createServer, createConnection } from "net";
import { existsSync, unlinkSync } from "fs";
const SOCK = process.env.S!;
async function acq(): Promise<boolean> {
  if (existsSync(SOCK)) {
    const alive = await new Promise<boolean>(r => {
      const c = createConnection(SOCK);
      c.on("connect", () => { c.destroy(); r(true); });
      c.on("error", () => r(false));
      setTimeout(() => { c.destroy(); r(false); }, 500);
    });
    if (alive) { process.stdout.write("REJECTED\n"); return false; }
    try { unlinkSync(SOCK); } catch {}
  }
  return new Promise(r => {
    const s = createServer();
    s.on("error", (e: any) => {
      if (e.code==="EADDRINUSE") { process.stdout.write("REJECTED\n"); r(false); return; }
      r(true);
    });
    s.listen(SOCK, () => { process.stdout.write("ACQUIRED\n"); r(true); });
    process.on("exit", () => { try { unlinkSync(SOCK); } catch {} });
  });
}
if (!(await acq())) process.exit(1);
const h = parseInt(process.env.H || "5");
await new Promise(r => setTimeout(r, h * 1000));
process.exit(0);
