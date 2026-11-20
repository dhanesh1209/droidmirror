import { test } from "node:test";
import assert from "node:assert/strict";
import { parseServerArgs } from "../src/config.ts";
import { Controller, ElementNotFound } from "../src/controller.ts";
import { Policy, PolicyError } from "../src/policy.ts";
import { FakeBackend } from "./fakes.ts";

const policy = (over: Partial<ConstructorParameters<typeof Policy>[0]> = {}) =>
  new Policy({ allowedSerials: ["ALLOWED1"], allowControl: true, allowNotificationText: false, ...over });

test("control is refused unless enabled, and never reaches the phone", async () => {
  const phone = new FakeBackend();
  const c = new Controller(policy({ allowControl: false }), phone);
  await assert.rejects(c.tap(1, 2), (e) => e instanceof PolicyError && /--allow-control/.test(e.message));
  await assert.rejects(c.screenshot(), PolicyError);
  await assert.rejects(c.uiTree(), PolicyError);
  assert.equal(phone.calls.length, 0);
});

test("only allowlisted devices are touched, and a device must be chosen when several are allowed", async () => {
  const phone = new FakeBackend();
  const c = new Controller(policy(), phone);
  await assert.rejects(c.tap(1, 2, "OTHER2"), /not in the allowlist/);
  const none = new Controller(policy({ allowedSerials: [] }), phone);
  await assert.rejects(none.tap(1, 2), /No devices are allowed/);
  const two = new Controller(policy({ allowedSerials: ["A", "B"] }), phone);
  await assert.rejects(two.tap(1, 2), /pass `device`/);
  await two.tap(1, 2, "B");
  assert.deepEqual(phone.calls, [["tap", "B", 1, 2]]);
});

test("list_devices works without opt-in and marks which phones are allowed", async () => {
  const c = new Controller(policy({ allowControl: false }), new FakeBackend());
  const list = await c.devices();
  assert.deepEqual(list.map((d) => [d.serial, d.allowed]), [["ALLOWED1", true], ["OTHER2", false]]);
});

test("tapElement taps the centre of the matching element", async () => {
  const phone = new FakeBackend();
  const c = new Controller(policy(), phone);
  const hit = await c.tapElement({ text: "Log in" });
  assert.deepEqual(hit.center, { x: 200, y: 300 });
  assert.deepEqual(phone.calls.at(-1), ["tap", "ALLOWED1", 200, 300]);
});

test("tapElement and findElements report misses and bad selectors clearly", async () => {
  const c = new Controller(policy(), new FakeBackend());
  await assert.rejects(c.tapElement({ text: "Nope" }), ElementNotFound);
  await assert.rejects(c.tapElement({ text: "Log in" }, 3), /out of range/);
  await assert.rejects(c.findElements({}), /at least one selector/);
});

test("waitForElement polls until the element appears, and times out otherwise", async () => {
  const phone = new FakeBackend();
  phone.emptyScreens = 2;
  const c = new Controller(policy(), phone, { sleep: async () => {} });
  const found = await c.waitForElement({ text: "Log in" }, 5_000);
  assert.equal(found.length, 1);
  assert.equal(phone.calls.filter((x) => x[0] === "uiTree").length, 3);   // two empty, one real

  const never = new FakeBackend();
  never.emptyScreens = 1_000_000;
  const quick = new Controller(policy(), never, { sleep: async () => {} });
  await assert.rejects(quick.waitForElement({ text: "Log in" }, 0), ElementNotFound);
});

test("the action log never contains typed text", async () => {
  const events: Record<string, unknown>[] = [];
  const c = new Controller(policy(), new FakeBackend(), { log: (e) => events.push(e) });
  await c.text("my-secret-password-123");
  await c.tapElement({ text: "Log in" });
  const logged = JSON.stringify(events);
  assert.doesNotMatch(logged, /secret-password/);
  assert.doesNotMatch(logged, /Log in/);                                   // selector values are not logged either
  assert.equal(events[0]!["length"], 22);
});

test("config: nothing is allowed by default, and flags and environment both work", () => {
  const none = parseServerArgs([], {});
  assert.equal(none.options.allowControl, false);
  assert.deepEqual(none.options.allowedSerials, []);
  const flags = parseServerArgs(["--allow-control", "--device", "A", "--device=B", "--device", "A"], {});
  assert.equal(flags.options.allowControl, true);
  assert.deepEqual(flags.options.allowedSerials, ["A", "B"]);
  const env = parseServerArgs([], { DROIDMIRROR_ALLOW_CONTROL: "1", DROIDMIRROR_DEVICES: "X, Y", DROIDMIRROR_ALLOW_NOTIFICATION_TEXT: "true" });
  assert.deepEqual([env.options.allowControl, env.options.allowedSerials, env.options.allowNotificationText], [true, ["X", "Y"], true]);
  assert.throws(() => parseServerArgs(["--allow-everything"], {}), /Unknown option/);
  assert.throws(() => parseServerArgs(["--device"], {}), /needs a serial/);
});
