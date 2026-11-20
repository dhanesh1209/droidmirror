import { test } from "node:test";
import assert from "node:assert/strict";
import { chmodSync, mkdtempSync, readFileSync, writeFileSync, existsSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { InMemoryTransport } from "@modelcontextprotocol/sdk/inMemory.js";
import { Controller } from "../src/controller.ts";
import { DarkScreenError, ScrcpyDarkScreen } from "../src/darkScreen.ts";
import type { DarkScreenProvider, DarkSession } from "../src/darkScreen.ts";
import { Policy, PolicyError } from "../src/policy.ts";
import { createServer } from "../src/server.ts";
import { FakeBackend } from "./fakes.ts";

/** Writes an executable shell script and returns its path. */
function script(dir: string, name: string, body: string): string {
  const file = path.join(dir, name);
  writeFileSync(file, `#!/bin/sh\n${body}\n`);
  chmodSync(file, 0o755);
  return file;
}
const newDir = () => mkdtempSync(path.join(tmpdir(), "dm-dark-"));
const lines = (file: string) => (existsSync(file) ? readFileSync(file, "utf8").trim().split("\n") : []);

test("start waits for scrcpy to report a dark display, with the expected flags", async () => {
  const dir = newDir();
  const scrcpy = script(dir, "scrcpy", `echo "$@" > '${dir}/args.txt'\necho "[server] INFO: Device display turned off"\nexec sleep 30`);
  const adb = script(dir, "adb", `echo "$@" >> '${dir}/adb.txt'`);
  const session = await new ScrcpyDarkScreen({ scrcpyPath: scrcpy, adbPath: adb }).start("S1");
  assert.equal(session.alive, true);
  assert.equal(session.serial, "S1");
  assert.equal(lines(path.join(dir, "args.txt"))[0], "--serial S1 --no-window --no-audio --turn-screen-off --stay-awake");

  await session.stop();
  assert.equal(session.alive, false);                                          // scrcpy was ended
  assert.deepEqual(lines(path.join(dir, "adb.txt")), ["-s S1 shell cmd display power-reset 0"]);   // and the display reset as a backstop
});

test("start fails clearly when scrcpy exits early, never becomes ready, or is missing", async () => {
  const dir = newDir();
  const adb = script(dir, "adb", "true");

  const crash = script(dir, "crash", `echo "ERROR: Could not find any ADB device"\nexit 3`);
  await assert.rejects(new ScrcpyDarkScreen({ scrcpyPath: crash, adbPath: adb }).start("S1"),
    (e) => e instanceof DarkScreenError && /exit 3/.test(e.message) && /Could not find any ADB device/.test(e.message));

  const silent = script(dir, "silent", "exec sleep 30");
  await assert.rejects(new ScrcpyDarkScreen({ scrcpyPath: silent, adbPath: adb, readyTimeoutMs: 300 }).start("S1"),
    /did not report the display going dark/);

  await assert.rejects(new ScrcpyDarkScreen({ scrcpyPath: path.join(dir, "no-such-scrcpy"), adbPath: adb }).start("S1"),
    /scrcpy is not installed.*brew install scrcpy/);
});

test("killNow ends the helper without waiting, for process-exit handlers", async () => {
  const dir = newDir();
  const scrcpy = script(dir, "scrcpy", `echo "[server] INFO: Device display turned off"\nexec sleep 30`);
  const session = await new ScrcpyDarkScreen({ scrcpyPath: scrcpy, adbPath: script(dir, "adb", "true") }).start("S1");
  session.killNow();
  for (let i = 0; i < 50 && session.alive; i++) await new Promise((r) => setTimeout(r, 20));
  assert.equal(session.alive, false);
});

// ---- the controller and the MCP tool, with a fake provider ----

class FakeSession implements DarkSession {
  serial: string;
  alive = true;
  stopped = 0;
  killed = 0;
  constructor(serial: string) { this.serial = serial; }
  async stop() { this.stopped++; this.alive = false; }
  killNow() { this.killed++; this.alive = false; }
}
class FakeProvider implements DarkScreenProvider {
  started: FakeSession[] = [];
  async start(serial: string) { const s = new FakeSession(serial); this.started.push(s); return s; }
}

const policy = (over: Partial<ConstructorParameters<typeof Policy>[0]> = {}) =>
  new Policy({ allowedSerials: ["ALLOWED1"], allowControl: true, allowNotificationText: false, ...over });

test("screenDark needs control and an allowlisted device, and does nothing otherwise", async () => {
  const provider = new FakeProvider();
  const off = new Controller(policy({ allowControl: false }), new FakeBackend(), { darkScreen: provider });
  await assert.rejects(off.screenDark(true), (e) => e instanceof PolicyError && /--allow-control/.test(e.message));
  const on = new Controller(policy(), new FakeBackend(), { darkScreen: provider });
  await assert.rejects(on.screenDark(true, "OTHER2"), /not in the allowlist/);
  const none = new Controller(policy(), new FakeBackend());
  await assert.rejects(none.screenDark(true), /not available/);
  assert.equal(provider.started.length, 0);
});

test("screenDark is idempotent, restarts after stop or a dead helper, and cleans up on close", async () => {
  const provider = new FakeProvider();
  const c = new Controller(policy(), new FakeBackend(), { darkScreen: provider });

  assert.deepEqual(await c.screenDark(true), { serial: "ALLOWED1", dark: true });
  await c.screenDark(true);                                                    // already dark: no second helper
  assert.equal(provider.started.length, 1);
  assert.equal(c.isDark("ALLOWED1"), true);

  assert.deepEqual(await c.screenDark(false), { serial: "ALLOWED1", dark: false });
  assert.equal(provider.started[0]!.stopped, 1);
  await c.screenDark(false);                                                   // already restored: harmless
  assert.equal(provider.started[0]!.stopped, 1);

  await c.screenDark(true);                                                    // turn it on again
  assert.equal(provider.started.length, 2);
  provider.started[1]!.alive = false;                                          // the helper dies (phone unplugged)
  assert.equal(c.isDark("ALLOWED1"), false);
  await c.screenDark(true);                                                    // a fresh helper replaces the dead one
  assert.equal(provider.started.length, 3);

  await c.close();                                                             // shutdown restores everything
  assert.equal(provider.started[2]!.stopped, 1);
  assert.equal(c.isDark("ALLOWED1"), false);

  await c.screenDark(true);
  c.closeNow();                                                                // process exit: synchronous kill
  assert.equal(provider.started[3]!.killed, 1);
});

test("MCP: screen_dark is refused without control and works with it", async () => {
  async function connect(allowControl: boolean) {
    const provider = new FakeProvider();
    const server = createServer(new Controller(policy({ allowControl }), new FakeBackend(), { darkScreen: provider }));
    const client = new Client({ name: "t", version: "1" });
    const [a, b] = InMemoryTransport.createLinkedPair();
    await Promise.all([server.connect(b), client.connect(a)]);
    return { client, provider, close: async () => { await client.close(); await server.close(); } };
  }
  const textOf = (r: any) => r.content.map((c: any) => c.text ?? "").join("");

  const off = await connect(false);
  const refused: any = await off.client.callTool({ name: "screen_dark", arguments: { enabled: true } });
  assert.equal(refused.isError, true);
  assert.match(textOf(refused), /--allow-control/);
  assert.equal(off.provider.started.length, 0);
  await off.close();

  const on = await connect(true);
  const dark: any = await on.client.callTool({ name: "screen_dark", arguments: { enabled: true } });
  assert.match(textOf(dark), /Screen is dark on ALLOWED1/);
  const back: any = await on.client.callTool({ name: "screen_dark", arguments: { enabled: false } });
  assert.match(textOf(back), /Screen restored/);
  assert.equal(on.provider.started[0]!.stopped, 1);
  await on.close();
});
