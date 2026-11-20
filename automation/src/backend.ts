import type { AdbRunner } from "./adb.ts";
import { AdbError } from "./adb.ts";
import { InputError, assertInt, assertPackage, keyCode, shellQuote, toInputText } from "./shell.ts";
import { parseUiTree } from "./uiTree.ts";
import type { UiNode } from "./uiTree.ts";

export interface Size {
  width: number;
  height: number;
}

export interface DeviceInfo {
  serial: string;
  state: string;
  model?: string;
  transport: "usb" | "wifi";
}

export type ScrollDirection = "up" | "down" | "left" | "right";

/**
 * What the tools need from a phone. AdbBackend is the first implementation; a scrcpy-protocol or
 * accessibility-service backend can be added later without changing the tools or the CLI.
 */
export interface PhoneBackend {
  listDevices(): Promise<DeviceInfo[]>;
  size(serial: string): Promise<Size>;
  tap(serial: string, x: number, y: number): Promise<void>;
  doubleTap(serial: string, x: number, y: number): Promise<void>;
  longPress(serial: string, x: number, y: number, durationMs: number): Promise<void>;
  swipe(serial: string, x1: number, y1: number, x2: number, y2: number, durationMs: number): Promise<void>;
  /** "down" reveals content below (the finger moves up); "right" reveals content to the right. */
  scroll(serial: string, direction: ScrollDirection, fraction: number): Promise<void>;
  text(serial: string, text: string): Promise<void>;
  key(serial: string, name: string): Promise<void>;
  screenshot(serial: string): Promise<Buffer>;
  uiTree(serial: string): Promise<UiNode[]>;
  launch(serial: string, pkg: string): Promise<void>;
  stop(serial: string, pkg: string): Promise<void>;
}

const PNG_SIGNATURE = Buffer.from([0x89, 0x50, 0x4e, 0x47]);

export class AdbBackend implements PhoneBackend {
  private readonly run: AdbRunner;

  constructor(run: AdbRunner) {
    this.run = run;
  }

  /** `adb -s <serial> shell <command>`: the single string is run by the phone's shell. */
  private async sh(serial: string, command: string, timeoutMs?: number): Promise<Buffer> {
    return this.run(["-s", serial, "shell", command], { timeoutMs });
  }

  async listDevices(): Promise<DeviceInfo[]> {
    const out = (await this.run(["devices", "-l"])).toString("utf8");
    const devices: DeviceInfo[] = [];
    for (const line of out.split(/\r?\n/)) {
      const trimmed = line.trim();
      if (!trimmed || trimmed.startsWith("List of") || trimmed.startsWith("*")) continue;
      const parts = trimmed.split(/\s+/);
      if (parts.length < 2) continue;
      const serial = parts[0]!;
      const model = parts.slice(2).find((p) => p.startsWith("model:"))?.slice("model:".length);
      devices.push({
        serial,
        state: parts[1]!,
        model,
        transport: serial.includes(":") || serial.includes("_adb-tls-connect") ? "wifi" : "usb",
      });
    }
    return devices;
  }

  async size(serial: string): Promise<Size> {
    const out = (await this.sh(serial, "wm size")).toString("utf8");
    // "Override size" (set by the user) wins over "Physical size".
    const line = out.split(/\r?\n/).find((l) => l.startsWith("Override size")) ?? out.split(/\r?\n/).find((l) => l.startsWith("Physical size"));
    const m = /(\d+)x(\d+)/.exec(line ?? "");
    if (!m) throw new AdbError("Could not read the screen size from `wm size`");
    return { width: Number(m[1]), height: Number(m[2]) };
  }

  async tap(serial: string, x: number, y: number): Promise<void> {
    await this.sh(serial, `input tap ${assertInt("x", x)} ${assertInt("y", y)}`);
  }

  async doubleTap(serial: string, x: number, y: number): Promise<void> {
    const xi = assertInt("x", x), yi = assertInt("y", y);
    await this.sh(serial, `input tap ${xi} ${yi} && input tap ${xi} ${yi}`);
  }

  async longPress(serial: string, x: number, y: number, durationMs: number): Promise<void> {
    const xi = assertInt("x", x), yi = assertInt("y", y);
    await this.sh(serial, `input swipe ${xi} ${yi} ${xi} ${yi} ${assertInt("durationMs", durationMs, 50, 10_000)}`);
  }

  async swipe(serial: string, x1: number, y1: number, x2: number, y2: number, durationMs: number): Promise<void> {
    const args = [assertInt("x1", x1), assertInt("y1", y1), assertInt("x2", x2), assertInt("y2", y2), assertInt("durationMs", durationMs, 20, 10_000)];
    await this.sh(serial, `input swipe ${args.join(" ")}`);
  }

  async scroll(serial: string, direction: ScrollDirection, fraction: number): Promise<void> {
    const { width, height } = await this.size(serial);
    const f = Math.min(0.9, Math.max(0.1, fraction));
    const cx = Math.round(width / 2), cy = Math.round(height / 2);
    const dy = Math.round((height * f) / 2), dx = Math.round((width * f) / 2);
    // The finger moves opposite to the direction of new content.
    const [x1, y1, x2, y2] =
      direction === "down" ? [cx, cy + dy, cx, cy - dy] :
      direction === "up" ? [cx, cy - dy, cx, cy + dy] :
      direction === "right" ? [cx + dx, cy, cx - dx, cy] :
      [cx - dx, cy, cx + dx, cy];
    await this.swipe(serial, x1, y1, x2, y2, 300);
  }

  async text(serial: string, text: string): Promise<void> {
    await this.sh(serial, `input text ${shellQuote(toInputText(text))}`);
  }

  async key(serial: string, name: string): Promise<void> {
    await this.sh(serial, `input keyevent ${keyCode(name)}`);
  }

  async screenshot(serial: string): Promise<Buffer> {
    // exec-out keeps the PNG bytes intact (no line-ending translation).
    const png = await this.run(["-s", serial, "exec-out", "screencap", "-p"], { timeoutMs: 20_000 });
    if (png.length < 8 || !png.subarray(0, 4).equals(PNG_SIGNATURE)) {
      throw new AdbError("The phone did not return a PNG screenshot (the screen may be protected or off)");
    }
    return png;
  }

  async uiTree(serial: string): Promise<UiNode[]> {
    // On Android 16 (checked on a Samsung S23+) `uiautomator dump /dev/tty` and `/dev/stdout` print only
    // "UI hierchary dumped to: ..." and no XML. Dumping to a file and reading it back works, so do that.
    const path = `/data/local/tmp/droidmirror_ui_${process.pid}.xml`;
    try {
      const status = (await this.sh(serial, `uiautomator dump ${path}`, 25_000)).toString("utf8");
      const xml = (await this.run(["-s", serial, "exec-out", "cat", path], { timeoutMs: 15_000 })).toString("utf8");
      const start = xml.indexOf("<?xml");
      const end = xml.lastIndexOf("</hierarchy>");
      if (start < 0 || end < 0) throw new AdbError(`UI dump failed: ${status.trim().slice(0, 160) || "no output"}`);
      return parseUiTree(xml.slice(start, end + "</hierarchy>".length));
    } finally {
      await this.sh(serial, `rm -f ${path}`).catch(() => {});
    }
  }

  async launch(serial: string, pkg: string): Promise<void> {
    const out = (await this.sh(serial, `monkey -p ${assertPackage(pkg)} -c android.intent.category.LAUNCHER 1`)).toString("utf8");
    if (/No activities found|monkey aborted/i.test(out)) throw new InputError(`Could not launch ${pkg}: no launchable activity (is it installed?)`);
  }

  async stop(serial: string, pkg: string): Promise<void> {
    await this.sh(serial, `am force-stop ${assertPackage(pkg)}`);
  }
}
