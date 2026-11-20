#!/usr/bin/env node
import { spawn } from "node:child_process";
import { writeFile } from "node:fs/promises";
import { createAdbRunner } from "./adb.ts";
import { AdbBackend } from "./backend.ts";
import type { ScrollDirection } from "./backend.ts";
import { Controller, stderrLogger } from "./controller.ts";
import { ScrcpyDarkScreen } from "./darkScreen.ts";
import { MacApiClient } from "./macApi.ts";
import { Policy } from "./policy.ts";
import type { Selector } from "./uiTree.ts";

const USAGE = `droidmirror-auto: drive an Android phone from the shell (uses adb)

  droidmirror-auto devices
  droidmirror-auto --device <serial> <command> ...

Naming the device with --device (or DROIDMIRROR_DEVICES) is the opt-in: nothing else is ever touched.

Commands:
  size                                   screen width x height in pixels
  tap <x> <y>                            double-tap <x> <y>   long-press <x> <y> [ms]
  swipe <x1> <y1> <x2> <y2> [ms]
  scroll up|down|left|right [fraction]
  text "<text>"                          type printable ASCII into the focused field
  key <HOME|BACK|ENTER|...>              press a key
  launch <package>                       stop <package>
  screenshot [--out file.png]
  tree [--max N]                         what is on screen
  find <selector>                        print matching elements as JSON
  tap-element <selector> [--index N]     tap the centre of a matching element
  wait-for <selector> [--timeout ms]     wait until an element appears

Screen-dark mode (the phone must be unlocked; it stays unlocked and awake while dark; needs scrcpy):
  dark [-- command ...]                  hold the screen dark while the command runs, or until Ctrl-C
                                         example: droidmirror-auto --device <serial> dark -- npm test

Notifications (need the DroidMirror menu-bar app running, and its menu switches on; no --device needed):
  notifications [--limit N]              list recent phone notifications
  wait-notification [--app A] [--title T] [--text-contains T] [--timeout ms]
  dismiss-notification <key>
  reply-notification <key> <text>        the Mac asks you to confirm every reply

Selector flags: --text T  --text-contains T  --id ID  --desc D  --desc-contains D  --class C  --clickable true|false`;

const VALUE_FLAGS = new Set(["device", "out", "max", "index", "timeout", "text", "text-contains", "id", "desc", "desc-contains", "class", "clickable", "limit", "app", "title"]);

function parse(argv: string[]) {
  const positional: string[] = [];
  const flags = new Map<string, string>();
  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i]!;
    if (arg.startsWith("--")) {
      const [name, inline] = arg.slice(2).split(/=(.*)/s, 2) as [string, string | undefined];
      if (!VALUE_FLAGS.has(name) && name !== "help") throw new Error(`Unknown option --${name}`);
      flags.set(name, inline ?? (name === "help" ? "1" : argv[++i] ?? ""));
    } else positional.push(arg);
  }
  return { positional, flags };
}

function selectorFrom(flags: Map<string, string>): Selector {
  const sel: Selector = {};
  if (flags.has("text")) sel.text = flags.get("text")!;
  if (flags.has("text-contains")) sel.textContains = flags.get("text-contains")!;
  if (flags.has("id")) sel.resourceId = flags.get("id")!;
  if (flags.has("desc")) sel.contentDesc = flags.get("desc")!;
  if (flags.has("desc-contains")) sel.contentDescContains = flags.get("desc-contains")!;
  if (flags.has("class")) sel.className = flags.get("class")!;
  if (flags.has("clickable")) sel.clickable = flags.get("clickable") === "true";
  return sel;
}

const num = (s: string | undefined, label: string): number => {
  const n = Number(s);
  if (s === undefined || s === "" || !Number.isFinite(n)) throw new Error(`${label} must be a number`);
  return n;
};
const optNum = (s: string | undefined, label: string) => (s === undefined ? undefined : num(s, label));

async function main() {
  // Everything after a bare "--" is a command to run while the screen is dark.
  const raw = process.argv.slice(2);
  const split = raw.indexOf("--");
  const { positional, flags } = parse(split < 0 ? raw : raw.slice(0, split));
  const rest = split < 0 ? [] : raw.slice(split + 1);
  const [command, ...args] = positional;
  if (!command || flags.has("help")) { console.error(USAGE); return command ? 0 : 2; }

  const serials = flags.has("device") ? [flags.get("device")!] : (process.env["DROIDMIRROR_DEVICES"] ?? "").split(",").map((s) => s.trim()).filter(Boolean);
  // Typing the command yourself is the consent, but only for devices you name.
  // Notification commands are gated by the Mac app's own menu switches, which only the user can turn on.
  const policy = new Policy({ allowedSerials: serials, allowControl: true, allowNotificationText: true, allowNotificationActions: true });
  const c = new Controller(policy, new AdbBackend(createAdbRunner()), {
    log: stderrLogger,
    notifications: new MacApiClient(),
    darkScreen: new ScrcpyDarkScreen(),
  });
  const dev = serials.length === 1 ? serials[0] : undefined;
  if (!["devices", "notifications", "wait-notification", "dismiss-notification", "reply-notification"].includes(command) && serials.length === 0) throw new Error("Name the phone with --device <serial> (see `droidmirror-auto devices`).");

  switch (command) {
    case "devices": console.log(JSON.stringify(await c.devices(), null, 2)); break;
    case "size": console.log(JSON.stringify(await c.size(dev))); break;
    case "tap": await c.tap(num(args[0], "x"), num(args[1], "y"), dev); break;
    case "double-tap": await c.doubleTap(num(args[0], "x"), num(args[1], "y"), dev); break;
    case "long-press": await c.longPress(num(args[0], "x"), num(args[1], "y"), optNum(args[2], "ms"), dev); break;
    case "swipe": await c.swipe(num(args[0], "x1"), num(args[1], "y1"), num(args[2], "x2"), num(args[3], "y2"), optNum(args[4], "ms"), dev); break;
    case "scroll": {
      if (!["up", "down", "left", "right"].includes(args[0] ?? "")) throw new Error("scroll needs up, down, left or right");
      await c.scroll(args[0] as ScrollDirection, optNum(args[1], "fraction"), dev);
      break;
    }
    case "text": await c.text(args.join(" "), dev); break;
    case "key": await c.key(args[0] ?? "", dev); break;
    case "launch": await c.launch(args[0] ?? "", dev); break;
    case "stop": await c.stop(args[0] ?? "", dev); break;
    case "screenshot": {
      const out = flags.get("out") ?? "screenshot.png";
      await writeFile(out, await c.screenshot(dev));
      console.log(`Saved ${out}`);
      break;
    }
    case "tree": {
      const tree = await c.uiTree(dev, optNum(flags.get("max"), "--max"));
      console.log(`${tree.shown} of ${tree.total} elements shown\n${tree.text}`);
      break;
    }
    case "find": console.log(JSON.stringify(await c.findElements(selectorFrom(flags), dev), null, 2)); break;
    case "tap-element": {
      const hit = await c.tapElement(selectorFrom(flags), optNum(flags.get("index"), "--index"), dev);
      console.log(`Tapped element at (${hit.center.x}, ${hit.center.y})`);
      break;
    }
    case "wait-for": console.log(JSON.stringify(await c.waitForElement(selectorFrom(flags), optNum(flags.get("timeout"), "--timeout"), dev), null, 2)); break;
    case "notifications": console.log(JSON.stringify(await c.listNotifications(optNum(flags.get("limit"), "--limit")), null, 2)); break;
    case "wait-notification": {
      const filter = { appContains: flags.get("app"), titleContains: flags.get("title"), textContains: flags.get("text-contains") };
      console.log(JSON.stringify(await c.waitForNotification(filter, optNum(flags.get("timeout"), "--timeout")), null, 2));
      break;
    }
    case "dismiss-notification": await c.dismissNotification(args[0] ?? ""); console.log("Dismissed"); break;
    case "reply-notification": await c.replyNotification(args[0] ?? "", args.slice(1).join(" ")); console.log("Reply sent"); break;
    case "dark": {
      // Keep the screen dark (phone stays awake and unlocked) while a command runs, or until Ctrl-C.
      await c.screenDark(true, dev);
      const restore = () => c.close();
      process.once("SIGINT", () => { void restore().finally(() => process.exit(130)); });
      process.once("SIGTERM", () => { void restore().finally(() => process.exit(143)); });
      if (rest.length === 0) {
        console.error("Screen is dark and the phone stays unlocked. Press Ctrl-C to restore it.");
        await new Promise(() => {});
      }
      console.error("Screen is dark; running your command…");
      const code = await new Promise<number>((resolve) => {
        const child = spawn(rest[0]!, rest.slice(1), { stdio: "inherit" });
        child.on("error", (error) => { console.error(error.message); resolve(127); });
        child.on("exit", (status) => resolve(status ?? 1));
      });
      await restore();
      return code;
    }
    default: throw new Error(`Unknown command ${command}. Try --help.`);
  }
  return 0;
}

main().then((code) => process.exit(code), (error) => {
  console.error(error instanceof Error ? error.message : String(error));
  process.exit(1);
});
