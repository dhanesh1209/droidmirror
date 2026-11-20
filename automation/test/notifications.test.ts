import { test } from "node:test";
import assert from "node:assert/strict";
import net from "node:net";
import { rmSync } from "node:fs";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { InMemoryTransport } from "@modelcontextprotocol/sdk/inMemory.js";
import { parseServerArgs } from "../src/config.ts";
import { Controller, NotificationTimeout } from "../src/controller.ts";
import { MacApiClient } from "../src/macApi.ts";
import type { MacNotification, MacStatus, NotificationBackend } from "../src/macApi.ts";
import { Policy, PolicyError } from "../src/policy.ts";
import { createServer } from "../src/server.ts";
import { FakeBackend } from "./fakes.ts";

const note = (key: string, text = "hello", over: Partial<MacNotification> = {}): MacNotification =>
  ({ key, app: "WhatsApp", pkg: "com.whatsapp", title: "Alice", text, postedAt: 1_700_000_000, canReply: true, ...over });

/** A Mac app stand-in that records calls; `queue` is what each successive list() call returns. */
class FakeMac implements NotificationBackend {
  calls: unknown[][] = [];
  queue: MacNotification[][] = [[]];
  async status(): Promise<MacStatus> { return { connected: true, phone: "Test Phone", canRead: true, canAct: true, count: this.queue[0]!.length }; }
  async list(limit: number) {
    this.calls.push(["list", limit]);
    return this.queue.length > 1 ? this.queue.shift()! : this.queue[0]!;
  }
  async reply(key: string, text: string) { this.calls.push(["reply", key, text]); }
  async dismiss(key: string) { this.calls.push(["dismiss", key]); }
}

const policy = (over: Partial<ConstructorParameters<typeof Policy>[0]> = {}) =>
  new Policy({ allowedSerials: [], allowControl: false, allowNotificationText: true, allowNotificationActions: true, ...over });

test("reading and acting are separate switches, and both are off by default", async () => {
  const mac = new FakeMac();
  const off = new Controller(policy({ allowNotificationText: false, allowNotificationActions: false }), new FakeBackend(), { notifications: mac });
  await assert.rejects(off.listNotifications(), (e) => e instanceof PolicyError && /--allow-notification-text/.test(e.message));
  await assert.rejects(off.waitForNotification({}, 10), PolicyError);
  await assert.rejects(off.dismissNotification("k"), (e) => e instanceof PolicyError && /--allow-notification-actions/.test(e.message));
  await assert.rejects(off.replyNotification("k", "hi"), PolicyError);
  assert.equal(mac.calls.length, 0);                                       // the Mac app was never even asked

  const readOnly = new Controller(policy({ allowNotificationActions: false }), new FakeBackend(), { notifications: mac });
  mac.queue = [[note("k1")]];
  assert.equal((await readOnly.listNotifications()).length, 1);
  await assert.rejects(readOnly.replyNotification("k1", "hi"), PolicyError);
});

test("status needs no opt-in because it holds no notification text", async () => {
  const c = new Controller(policy({ allowNotificationText: false, allowNotificationActions: false }), new FakeBackend(), { notifications: new FakeMac() });
  assert.equal((await c.notificationStatus()).phone, "Test Phone");
});

test("without a Mac app connection the tools explain themselves", async () => {
  const c = new Controller(policy(), new FakeBackend());
  await assert.rejects(c.listNotifications(), /no connection to the DroidMirror Mac app/);
});

test("reply trims and validates before it reaches the Mac app", async () => {
  const mac = new FakeMac();
  const c = new Controller(policy(), new FakeBackend(), { notifications: mac });
  await c.replyNotification("k1", "  on my way  ");
  assert.deepEqual(mac.calls, [["reply", "k1", "on my way"]]);
  await assert.rejects(c.replyNotification("k1", "   "), /empty/);
  await assert.rejects(c.replyNotification("k1", "x".repeat(2001)), /longer/);
  assert.equal(mac.calls.length, 1);
});

test("waitForNotification ignores existing notifications and returns the first new match", async () => {
  const mac = new FakeMac();
  mac.queue = [
    [note("old", "already here")],                                          // baseline
    [note("old", "already here")],                                          // nothing new yet
    [note("other", "wrong app", { app: "Gmail" }), note("old", "already here")],   // new, but filtered out
    [note("new", "Code 123456"), note("old", "already here")],              // the one we want
  ];
  const c = new Controller(policy(), new FakeBackend(), { notifications: mac, sleep: async () => {} });
  const hit = await c.waitForNotification({ appContains: "whats", textContains: "CODE" }, 60_000);
  assert.equal(hit.key, "new");
});

test("waitForNotification times out with a clear error", async () => {
  const mac = new FakeMac();
  mac.queue = [[note("old")]];
  const c = new Controller(policy(), new FakeBackend(), { notifications: mac, sleep: async () => {} });
  await assert.rejects(c.waitForNotification({ textContains: "never" }, 0), NotificationTimeout);
});

test("the log never contains notification or reply text", async () => {
  const events: Record<string, unknown>[] = [];
  const mac = new FakeMac();
  mac.queue = [[note("k1", "my bank code is 998877")]];
  const c = new Controller(policy(), new FakeBackend(), { notifications: mac, log: (e) => events.push(e) });
  await c.listNotifications();
  await c.replyNotification("k1", "secret reply text");
  const logged = JSON.stringify(events);
  assert.doesNotMatch(logged, /998877|secret reply|Alice/);
  assert.deepEqual(events.map((e) => e["action"]), ["list_notifications", "reply_notification"]);
});

test("config reads --allow-notification-actions and its environment variable", () => {
  assert.equal(parseServerArgs([], {}).options.allowNotificationActions, false);
  assert.equal(parseServerArgs(["--allow-notification-actions"], {}).options.allowNotificationActions, true);
  assert.equal(parseServerArgs([], { DROIDMIRROR_ALLOW_NOTIFICATION_ACTIONS: "1" }).options.allowNotificationActions, true);
});

test("MCP: notification tools refuse politely when switched off and work when on", async () => {
  async function connect(over: Parameters<typeof policy>[0]) {
    const mac = new FakeMac();
    mac.queue = [[note("k1", "hello there")]];
    const server = createServer(new Controller(policy(over), new FakeBackend(), { notifications: mac }));
    const client = new Client({ name: "t", version: "1" });
    const [a, b] = InMemoryTransport.createLinkedPair();
    await Promise.all([server.connect(b), client.connect(a)]);
    return { client, mac, close: async () => { await client.close(); await server.close(); } };
  }
  const textOf = (r: any) => r.content.map((c: any) => c.text ?? "").join("");

  const off = await connect({ allowNotificationText: false, allowNotificationActions: false });
  const refused: any = await off.client.callTool({ name: "list_notifications", arguments: {} });
  assert.equal(refused.isError, true);
  assert.match(textOf(refused), /--allow-notification-text/);
  const noReply: any = await off.client.callTool({ name: "reply_notification", arguments: { key: "k1", text: "hi" } });
  assert.equal(noReply.isError, true);
  assert.equal(off.mac.calls.length, 0);
  await off.close();

  const on = await connect({});
  const listed: any = await on.client.callTool({ name: "list_notifications", arguments: { limit: 5 } });
  assert.equal(JSON.parse(textOf(listed))[0].key, "k1");
  const replied: any = await on.client.callTool({ name: "reply_notification", arguments: { key: "k1", text: "got it" } });
  assert.equal(replied.isError, undefined);
  assert.deepEqual(on.mac.calls.at(-1), ["reply", "k1", "got it"]);
  await on.close();
});

// ---- the real socket client, against a stand-in for the Mac app ----

function fakeMacApp(socketPath: string, handler: (req: { method: string; params: any }) => { ok: boolean; result?: unknown; error?: string }) {
  const server = net.createServer((socket) => {
    let buffer = "";
    socket.on("data", (d) => {
      buffer += d.toString();
      const nl = buffer.indexOf("\n");
      if (nl < 0) return;
      const req = JSON.parse(buffer.slice(0, nl));
      socket.end(JSON.stringify({ id: req.id, ...handler(req) }) + "\n");
    });
  });
  return new Promise<net.Server>((resolve) => server.listen(socketPath, () => resolve(server)));
}

test("MacApiClient speaks the line protocol and turns errors into readable messages", async () => {
  const socketPath = `/tmp/dm-node-${process.pid}-${Date.now()}.sock`;
  const requests: unknown[] = [];
  const server = await fakeMacApp(socketPath, (req) => {
    requests.push(req);
    if (req.method === "list_notifications") return { ok: true, result: [note("k1")] };
    if (req.method === "dismiss") return { ok: false, error: "Replying and dismissing is switched off." };
    if (req.method === "status") return { ok: true, result: { connected: true, canRead: false, canAct: false, count: 0 } };
    return { ok: true, result: { sent: true } };
  });
  try {
    const mac = new MacApiClient(socketPath);
    assert.equal((await mac.list(7))[0]!.key, "k1");
    assert.deepEqual(requests[0], { id: 1, method: "list_notifications", params: { limit: 7 } });
    await assert.rejects(mac.dismiss("k1"), /switched off/);
    assert.equal((await mac.status()).canRead, false);
    await mac.reply("k1", "hi");
    assert.deepEqual(requests.at(-1), { id: 1, method: "reply", params: { key: "k1", text: "hi" } });
  } finally {
    server.close();
    rmSync(socketPath, { force: true });
  }
});

test("MacApiClient explains when the menu-bar app is not running", async () => {
  const mac = new MacApiClient(`/tmp/dm-node-missing-${process.pid}.sock`);
  await assert.rejects(mac.status(), /menu-bar app is not running/);
});
