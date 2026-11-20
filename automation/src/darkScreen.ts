import { execFile, spawn } from "node:child_process";
import type { ChildProcess } from "node:child_process";

export class DarkScreenError extends Error {}

/** One running "screen dark" session for one phone. */
export interface DarkSession {
  readonly serial: string;
  /** False once the helper has exited (for example the phone was unplugged). */
  readonly alive: boolean;
  /** Stops the helper and restores the display. */
  stop(): Promise<void>;
  /** Synchronous kill for process-exit handlers, where nothing can be awaited. */
  killNow(): void;
}

export interface DarkScreenProvider {
  start(serial: string): Promise<DarkSession>;
}

export interface ScrcpyOptions {
  scrcpyPath?: string;
  adbPath?: string;
  /** How long to wait for scrcpy to report that the display is off. */
  readyTimeoutMs?: number;
}

/**
 * Keeps a phone's display dark while it stays awake and unlocked, which lets adb taps, the UI tree and screenshots
 * keep working. It runs scrcpy with no window and no audio; scrcpy powers the display off at its own layer and
 * restores it when it exits. (Measured on a Samsung SM-S916B, Android 16: `adb shell cmd display power-off` does
 * not work for this, because taps are ignored and screenshots are black.)
 *
 * The phone must already be unlocked: a locked phone shows only its lock screen to any tool.
 */
export class ScrcpyDarkScreen implements DarkScreenProvider {
  private readonly scrcpyPath: string;
  private readonly adbPath: string;
  private readonly readyTimeoutMs: number;

  constructor(options: ScrcpyOptions = {}) {
    this.scrcpyPath = options.scrcpyPath ?? process.env["SCRCPY"] ?? "scrcpy";
    this.adbPath = options.adbPath ?? process.env["ADB"] ?? "adb";
    this.readyTimeoutMs = options.readyTimeoutMs ?? 15_000;
  }

  start(serial: string): Promise<DarkSession> {
    return new Promise<DarkSession>((resolve, reject) => {
      const child = spawn(
        this.scrcpyPath,
        ["--serial", serial, "--no-window", "--no-audio", "--turn-screen-off", "--stay-awake"],
        { stdio: ["ignore", "pipe", "pipe"] },
      );

      let log = "";
      let settled = false;
      let exited = false;
      const tail = () => log.trim().split("\n").slice(-3).join(" | ").slice(0, 300);
      const adbPath = this.adbPath;

      const session: DarkSession = {
        serial,
        get alive() { return !exited; },
        stop: () => stopChild(child, () => exited, adbPath, serial),
        killNow: () => { if (!exited) child.kill("SIGKILL"); },
      };

      const fail = (message: string) => {
        if (settled) return;
        settled = true;
        clearTimeout(timer);
        if (!exited) child.kill("SIGKILL");
        reject(new DarkScreenError(message));
      };

      const timer = setTimeout(
        () => fail(`scrcpy did not report the display going dark within ${this.readyTimeoutMs} ms. Last output: ${tail() || "none"}`),
        this.readyTimeoutMs,
      );

      const onData = (chunk: Buffer) => {
        log += chunk.toString("utf8");
        if (!settled && /display turned off/i.test(log)) {
          settled = true;
          clearTimeout(timer);
          resolve(session);
        }
      };
      child.stdout!.on("data", onData);
      child.stderr!.on("data", onData);
      child.on("error", (error: NodeJS.ErrnoException) =>
        fail(error.code === "ENOENT" ? "scrcpy is not installed. Install it with: brew install scrcpy" : `Could not start scrcpy: ${error.message}`),
      );
      child.on("exit", (code) => {
        exited = true;
        fail(`scrcpy stopped (exit ${code}) before the display went dark. Last output: ${tail() || "none"}`);
      });
    });
  }
}

/** Ends scrcpy (which restores the display) and then asks Android to reset the display power as a backstop. */
async function stopChild(child: ChildProcess, hasExited: () => boolean, adbPath: string, serial: string): Promise<void> {
  if (!hasExited()) {
    await new Promise<void>((resolve) => {
      const force = setTimeout(() => child.kill("SIGKILL"), 5_000);
      child.once("exit", () => { clearTimeout(force); resolve(); });
      child.kill("SIGTERM");
    });
  }
  await new Promise<void>((resolve) => {
    execFile(adbPath, ["-s", serial, "shell", "cmd", "display", "power-reset", "0"], { timeout: 10_000 }, () => resolve());   // best effort
  });
}
