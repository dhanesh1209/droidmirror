import type { PolicyOptions } from "./policy.ts";

export const SERVER_USAGE = `droidmirror-mcp: MCP server that lets an agent drive an Android phone over adb.

Nothing is allowed by default. To enable device control you must opt in AND name the device:

  droidmirror-mcp --allow-control --device <serial>

Options:
  --allow-control            enable taps, swipes, text, keys, app launch/stop, screenshots and the UI tree
  --device <serial>          a device the server may control (repeatable); see \`adb devices\`
  --allow-notification-text  allow reading phone notifications (needs the DroidMirror Mac app, and its menu switch)
  --allow-notification-actions  allow replying to and dismissing notifications (replies also ask on the Mac every time)
  -h, --help                 show this help

Environment equivalents: DROIDMIRROR_ALLOW_CONTROL=1, DROIDMIRROR_DEVICES=serial1,serial2,
DROIDMIRROR_ALLOW_NOTIFICATION_TEXT=1, DROIDMIRROR_ALLOW_NOTIFICATION_ACTIONS=1, ADB=/path/to/adb
Actions are logged to stderr without typed text or screen contents.`;

const truthy = (v: string | undefined) => v === "1" || v === "true";

export function parseServerArgs(argv: string[], env: Record<string, string | undefined>): { options: PolicyOptions; help: boolean } {
  const options: PolicyOptions = {
    allowedSerials: (env["DROIDMIRROR_DEVICES"] ?? "").split(",").map((s) => s.trim()).filter(Boolean),
    allowControl: truthy(env["DROIDMIRROR_ALLOW_CONTROL"]),
    allowNotificationText: truthy(env["DROIDMIRROR_ALLOW_NOTIFICATION_TEXT"]),
    allowNotificationActions: truthy(env["DROIDMIRROR_ALLOW_NOTIFICATION_ACTIONS"]),
  };
  let help = false;
  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i]!;
    if (arg === "-h" || arg === "--help") help = true;
    else if (arg === "--allow-control") options.allowControl = true;
    else if (arg === "--allow-notification-text") options.allowNotificationText = true;
    else if (arg === "--allow-notification-actions") options.allowNotificationActions = true;
    else if (arg === "--device") {
      const value = argv[++i];
      if (!value || value.startsWith("--")) throw new Error("--device needs a serial");
      options.allowedSerials.push(value);
    } else if (arg.startsWith("--device=")) options.allowedSerials.push(arg.slice("--device=".length));
    else throw new Error(`Unknown option ${arg}. Try --help.`);
  }
  options.allowedSerials = [...new Set(options.allowedSerials)];
  return { options, help };
}
