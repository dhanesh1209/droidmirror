import { execFile } from "node:child_process";

export class AdbError extends Error {}

/** Runs adb with an argument array (never through a local shell) and returns stdout as bytes. */
export type AdbRunner = (args: string[], options?: { timeoutMs?: number }) => Promise<Buffer>;

export function createAdbRunner(adbPath: string = process.env.ADB ?? "adb"): AdbRunner {
  return (args, options = {}) =>
    new Promise<Buffer>((resolve, reject) => {
      execFile(
        adbPath,
        args,
        { encoding: "buffer", maxBuffer: 64 * 1024 * 1024, timeout: options.timeoutMs ?? 30_000 },
        (error, stdout, stderr) => {
          if (error) {
            // Only the leading words are echoed: later arguments may hold typed text.
            const head = args.filter((a) => a !== "-s").slice(0, 3).join(" ");
            reject(new AdbError(`adb ${head} failed: ${stderr.toString().trim() || error.message}`));
            return;
          }
          resolve(stdout);
        },
      );
    });
}
