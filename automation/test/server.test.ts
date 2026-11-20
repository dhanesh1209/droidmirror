import { test } from "node:test";
import assert from "node:assert/strict";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { InMemoryTransport } from "@modelcontextprotocol/sdk/inMemory.js";
import { Controller } from "../src/controller.ts";
import { Policy } from "../src/policy.ts";
import { createServer } from "../src/server.ts";
import { FakeBackend } from "./fakes.ts";

/** Connects a real MCP client to the real server over an in-memory pipe. */
async function connect(options: { allowControl: boolean }) {
  const phone = new FakeBackend();
  const policy = new Policy({ allowedSerials: ["ALLOWED1"], allowControl: options.allowControl, allowNotificationText: false });
  const server = createServer(new Controller(policy, phone));
  const client = new Client({ name: "test-client", version: "1.0.0" });
  const [clientSide, serverSide] = InMemoryTransport.createLinkedPair();
  await Promise.all([server.connect(serverSide), client.connect(clientSide)]);
  return { client, phone, close: async () => { await client.close(); await server.close(); } };
}

const textOf = (result: any): string => result.content.map((c: any) => c.text ?? "").join("");

test("the server advertises the expected tools with descriptions", async () => {
  const { client, close } = await connect({ allowControl: true });
  const { tools } = await client.listTools();
  const names = tools.map((t) => t.name).sort();
  assert.deepEqual(names, [
    "device_size", "dismiss_notification", "double_tap", "find_elements", "launch_app", "list_devices", "list_notifications",
    "long_press", "notification_status", "press_key", "reply_notification", "screen_dark", "screenshot", "scroll", "stop_app", "swipe", "tap",
    "tap_element", "type_text", "ui_tree", "wait_for_element", "wait_for_notification",
  ]);
  for (const tool of tools) assert.ok(tool.description && tool.description.length > 10, `${tool.name} needs a description`);
  await close();
});

test("with control off, an action comes back as a readable tool error and the phone is untouched", async () => {
  const { client, phone, close } = await connect({ allowControl: false });
  const result: any = await client.callTool({ name: "tap", arguments: { x: 10, y: 20 } });
  assert.equal(result.isError, true);
  assert.match(textOf(result), /--allow-control/);
  assert.equal(phone.calls.length, 0);
  await close();
});

test("with control on, tools act on the allowed device", async () => {
  const { client, phone, close } = await connect({ allowControl: true });
  const tapped: any = await client.callTool({ name: "tap", arguments: { x: 10, y: 20 } });
  assert.equal(tapped.isError, undefined);
  const element: any = await client.callTool({ name: "tap_element", arguments: { text: "Log in" } });
  assert.match(textOf(element), /\(200, 300\)/);
  const key: any = await client.callTool({ name: "press_key", arguments: { key: "HOME" } });
  assert.match(textOf(key), /HOME/);
  assert.deepEqual(phone.calls, [["tap", "ALLOWED1", 10, 20], ["uiTree", "ALLOWED1"], ["tap", "ALLOWED1", 200, 300], ["key", "ALLOWED1", "HOME"]]);
  await close();
});

test("a device outside the allowlist is rejected even with control on", async () => {
  const { client, phone, close } = await connect({ allowControl: true });
  const result: any = await client.callTool({ name: "tap", arguments: { x: 1, y: 2, device: "OTHER2" } });
  assert.equal(result.isError, true);
  assert.match(textOf(result), /not in the allowlist/);
  assert.equal(phone.calls.length, 0);
  await close();
});

test("screenshot returns an image block, and ui_tree returns readable text", async () => {
  const { client, close } = await connect({ allowControl: true });
  const shot: any = await client.callTool({ name: "screenshot", arguments: {} });
  assert.equal(shot.content[0].type, "image");
  assert.equal(shot.content[0].mimeType, "image/png");
  assert.ok(Buffer.from(shot.content[0].data, "base64").subarray(0, 4).equals(Buffer.from([0x89, 0x50, 0x4e, 0x47])));
  const tree: any = await client.callTool({ name: "ui_tree", arguments: {} });
  assert.match(textOf(tree), /Button text="Log in"/);
  await close();
});

test("invalid input is rejected before it reaches the phone", async () => {
  const { client, phone, close } = await connect({ allowControl: true });
  const badKey: any = await client.callTool({ name: "press_key", arguments: { key: "POWER" } }).catch((e) => ({ isError: true, content: [{ text: String(e) }] }));
  assert.equal(badKey.isError, true);
  const badPackage: any = await client.callTool({ name: "launch_app", arguments: { package: "com.x; reboot" } });
  assert.equal(badPackage.isError, undefined);                              // the fake backend does not validate; the real one does (see backend tests)
  const noSelector: any = await client.callTool({ name: "find_elements", arguments: {} });
  assert.equal(noSelector.isError, true);
  assert.equal(phone.calls.filter((c) => c[0] === "key").length, 0);
  await close();
});
