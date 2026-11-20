import { test } from "node:test";
import assert from "node:assert/strict";
import type { AdbRunner } from "../src/adb.ts";
import { AdbBackend } from "../src/backend.ts";
import { SAMPLE_XML, PNG_BYTES } from "./fakes.ts";

/** An adb that records its arguments and answers from a lookup by the shell command. */
function recorder(answer: (args: string[]) => string | Buffer = () => "") {
  const calls: string[][] = [];
  const run: AdbRunner = async (args) => {
    calls.push(args);
    const a = answer(args);
    return Buffer.isBuffer(a) ? a : Buffer.from(a);
  };
  return { calls, backend: new AdbBackend(run) };
}

const shellOf = (calls: string[][], i = 0) => calls[i]!.slice(0, 3).join(" ") + " | " + calls[i]![3];

test("gestures become exact `input` commands for the chosen device", async () => {
  const { calls, backend } = recorder();
  await backend.tap("S1", 10, 20);
  await backend.doubleTap("S1", 10, 20);
  await backend.longPress("S1", 5, 6, 900);
  await backend.swipe("S1", 1, 2, 3, 4, 250);
  await backend.key("S1", "back");
  assert.deepEqual(calls.map((c) => c.join(" ")), [
    "-s S1 shell input tap 10 20",
    "-s S1 shell input tap 10 20 && input tap 10 20",
    "-s S1 shell input swipe 5 6 5 6 900",
    "-s S1 shell input swipe 1 2 3 4 250",
    "-s S1 shell input keyevent 4",
  ]);
});

test("scroll down moves the finger up from the screen centre", async () => {
  const { calls, backend } = recorder((args) => (args[3] === "wm size" ? "Physical size: 1080x2340\n" : ""));
  await backend.scroll("S1", "down", 0.5);
  // centre (540, 1170); half of 50% of the height is 585
  assert.equal(shellOf(calls, 1), "-s S1 shell | input swipe 540 1755 540 585 300");
  await backend.scroll("S1", "right", 0.5);
  assert.equal(shellOf(calls, 3), "-s S1 shell | input swipe 810 1170 270 1170 300");
});

test("screen size prefers an override over the physical size", async () => {
  const { backend } = recorder(() => "Physical size: 1080x2340\nOverride size: 720x1560\n");
  assert.deepEqual(await backend.size("S1"), { width: 720, height: 1560 });
});

test("text is quoted so a hostile string cannot add a second command", async () => {
  const { calls, backend } = recorder();
  await backend.text("S1", "it's a test");
  await backend.text("S1", "a; reboot");
  assert.equal(calls[0]![3], `input text 'it'\\''s%sa%stest'`);
  assert.equal(calls[1]![3], `input text 'a;%sreboot'`);
});

test("hostile coordinates and package names never reach adb", async () => {
  const { calls, backend } = recorder();
  await assert.rejects(backend.tap("S1", "1; reboot" as unknown as number, 2), /number/);
  await assert.rejects(backend.launch("S1", "com.x; reboot"), /valid package/);
  await assert.rejects(backend.stop("S1", "-a"), /valid package/);
  assert.equal(calls.length, 0);
});

test("launch and stop use monkey and force-stop, and launch reports a missing app", async () => {
  const ok = recorder();
  await ok.backend.launch("S1", "com.android.settings");
  await ok.backend.stop("S1", "com.android.settings");
  assert.equal(ok.calls[0]![3], "monkey -p com.android.settings -c android.intent.category.LAUNCHER 1");
  assert.equal(ok.calls[1]![3], "am force-stop com.android.settings");
  const missing = recorder(() => "** No activities found to run, monkey aborted.");
  await assert.rejects(missing.backend.launch("S1", "com.not.installed"), /no launchable activity/);
});

test("screenshot returns PNG bytes and rejects anything else", async () => {
  const good = recorder(() => PNG_BYTES);
  assert.deepEqual(await good.backend.screenshot("S1"), PNG_BYTES);
  assert.deepEqual(good.calls[0], ["-s", "S1", "exec-out", "screencap", "-p"]);
  const bad = recorder(() => Buffer.from("not a png at all"));
  await assert.rejects(bad.backend.screenshot("S1"), /PNG/);
});

test("uiTree dumps to a temp file, reads it back with exec-out, and always cleans up", async () => {
  // Matches real behaviour on Android 16: the dump command prints only a status line; the XML is in the file.
  const { calls, backend } = recorder((args) => (args.includes("exec-out") ? SAMPLE_XML : "UI hierchary dumped to: /data/local/tmp/x.xml\n"));
  const nodes = await backend.uiTree("S1");
  assert.equal(nodes.length, 4);
  assert.match(calls[0]![3]!, /^uiautomator dump \/data\/local\/tmp\/droidmirror_ui_\d+\.xml$/);
  assert.deepEqual(calls[1]!.slice(0, 4), ["-s", "S1", "exec-out", "cat"]);
  assert.match(calls[2]![3]!, /^rm -f \/data\/local\/tmp\/droidmirror_ui_\d+\.xml$/);

  // A failed dump reports the phone's message and still removes the temp file.
  const broken = recorder((args) => (args.includes("exec-out") ? "" : "ERROR: could not get idle state."));
  await assert.rejects(broken.backend.uiTree("S1"), /UI dump failed: ERROR: could not get idle state/);
  assert.match(broken.calls.at(-1)![3]!, /^rm -f /);
});

test("listDevices parses adb output and tells USB from Wi-Fi", async () => {
  const { backend } = recorder(
    () => "List of devices attached\nR58M12345AB device usb:1-1 product:x model:SM_S916B device:y transport_id:1\n192.168.1.9:5555 device product:p model:Pixel_8 transport_id:2\n\n",
  );
  assert.deepEqual(await backend.listDevices(), [
    { serial: "R58M12345AB", state: "device", model: "SM_S916B", transport: "usb" },
    { serial: "192.168.1.9:5555", state: "device", model: "Pixel_8", transport: "wifi" },
  ]);
});
