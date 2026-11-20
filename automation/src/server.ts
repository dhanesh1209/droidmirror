import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { z } from "zod";
import type { Controller } from "./controller.ts";
import { KEYS } from "./shell.ts";
import type { Selector } from "./uiTree.ts";

const device = z.string().optional().describe("Device serial. Optional when exactly one device is allowed.");
const coord = (label: string) => z.number().int().min(0).describe(`${label}, in screen pixels (see device_size)`);

const selectorShape = {
  text: z.string().optional().describe("Exact visible text of the element"),
  textContains: z.string().optional().describe("Part of the visible text, ignoring case"),
  resourceId: z.string().optional().describe("Resource id, full (com.app:id/login) or just the part after the slash (login)"),
  contentDesc: z.string().optional().describe("Exact content description (accessibility label)"),
  contentDescContains: z.string().optional().describe("Part of the content description, ignoring case"),
  className: z.string().optional().describe("Class name, full or the last part (Button)"),
  clickable: z.boolean().optional().describe("Only match clickable (true) or non-clickable (false) elements"),
};

type ToolResult = { content: Array<{ type: "text"; text: string } | { type: "image"; data: string; mimeType: string }>; isError?: boolean };

const text = (t: string): ToolResult => ({ content: [{ type: "text", text: t }] });

/** Turns a thrown error into an MCP tool error the model can read and act on. */
async function run(fn: () => Promise<ToolResult>): Promise<ToolResult> {
  try {
    return await fn();
  } catch (error) {
    return { isError: true, content: [{ type: "text", text: error instanceof Error ? error.message : String(error) }] };
  }
}

export function createServer(c: Controller): McpServer {
  const server = new McpServer({ name: "droidmirror-automation", version: "0.1.0" });
  const read = { readOnlyHint: true, openWorldHint: false };
  const act = { readOnlyHint: false, destructiveHint: false, openWorldHint: false };

  server.registerTool(
    "list_devices",
    { title: "List devices", description: "List Android devices adb can see and whether this server may control each (the `allowed` field).", inputSchema: {}, annotations: read },
    () => run(async () => text(JSON.stringify(await c.devices(), null, 2))),
  );

  server.registerTool(
    "device_size",
    { title: "Screen size", description: "Screen width and height in pixels. All coordinates are pixels from the top-left corner.", inputSchema: { device }, annotations: read },
    ({ device }) => run(async () => text(JSON.stringify(await c.size(device)))),
  );

  server.registerTool(
    "tap",
    { title: "Tap", description: "Tap a point on the screen.", inputSchema: { x: coord("x"), y: coord("y"), device }, annotations: act },
    ({ x, y, device }) => run(async () => { await c.tap(x, y, device); return text(`Tapped (${x}, ${y})`); }),
  );

  server.registerTool(
    "double_tap",
    { title: "Double tap", description: "Tap the same point twice quickly.", inputSchema: { x: coord("x"), y: coord("y"), device }, annotations: act },
    ({ x, y, device }) => run(async () => { await c.doubleTap(x, y, device); return text(`Double-tapped (${x}, ${y})`); }),
  );

  server.registerTool(
    "long_press",
    {
      title: "Long press",
      description: "Press and hold a point.",
      inputSchema: { x: coord("x"), y: coord("y"), durationMs: z.number().int().min(50).max(10000).optional().describe("Hold time, default 800"), device },
      annotations: act,
    },
    ({ x, y, durationMs, device }) => run(async () => { await c.longPress(x, y, durationMs, device); return text(`Long-pressed (${x}, ${y})`); }),
  );

  server.registerTool(
    "swipe",
    {
      title: "Swipe",
      description: "Drag a finger in a straight line from one point to another.",
      inputSchema: {
        x1: coord("Start x"), y1: coord("Start y"), x2: coord("End x"), y2: coord("End y"),
        durationMs: z.number().int().min(20).max(10000).optional().describe("Swipe time, default 300. Longer is slower, shorter is a fling."),
        device,
      },
      annotations: act,
    },
    ({ x1, y1, x2, y2, durationMs, device }) => run(async () => { await c.swipe(x1, y1, x2, y2, durationMs, device); return text("Swiped"); }),
  );

  server.registerTool(
    "scroll",
    {
      title: "Scroll",
      description: "Scroll the screen from its centre. \"down\" reveals content further down (the finger moves up); \"right\" reveals content to the right.",
      inputSchema: {
        direction: z.enum(["up", "down", "left", "right"]),
        fraction: z.number().min(0.1).max(0.9).optional().describe("How much of the screen to travel, default 0.5"),
        device,
      },
      annotations: act,
    },
    ({ direction, fraction, device }) => run(async () => { await c.scroll(direction, fraction, device); return text(`Scrolled ${direction}`); }),
  );

  server.registerTool(
    "type_text",
    {
      title: "Type text",
      description: "Type text into the focused field. Printable ASCII only; the sequence %s cannot be typed. Tap the field first.",
      inputSchema: { text: z.string().min(1).max(500), device },
      annotations: act,
    },
    ({ text: t, device }) => run(async () => { await c.text(t, device); return text(`Typed ${t.length} characters`); }),
  );

  server.registerTool(
    "press_key",
    {
      title: "Press key",
      description: `Press a hardware or navigation key. Allowed: ${Object.keys(KEYS).join(", ")}.`,
      inputSchema: { key: z.enum(Object.keys(KEYS) as [string, ...string[]]), device },
      annotations: act,
    },
    ({ key, device }) => run(async () => { await c.key(key, device); return text(`Pressed ${key}`); }),
  );

  server.registerTool(
    "launch_app",
    { title: "Launch app", description: "Open an installed app by package name, for example com.android.settings.", inputSchema: { package: z.string().min(3).max(200), device }, annotations: act },
    ({ package: pkg, device }) => run(async () => { await c.launch(pkg, device); return text(`Launched ${pkg}`); }),
  );

  server.registerTool(
    "stop_app",
    { title: "Force-stop app", description: "Force-stop an app by package name. Unsaved state in that app is lost.", inputSchema: { package: z.string().min(3).max(200), device }, annotations: { ...act, destructiveHint: true } },
    ({ package: pkg, device }) => run(async () => { await c.stop(pkg, device); return text(`Stopped ${pkg}`); }),
  );

  server.registerTool(
    "screenshot",
    { title: "Screenshot", description: "Capture the current screen as a PNG image. Protected screens (banking, payments) come back blank or fail.", inputSchema: { device }, annotations: read },
    ({ device }) => run(async () => {
      const png = await c.screenshot(device);
      return { content: [{ type: "image", data: png.toString("base64"), mimeType: "image/png" }] };
    }),
  );

  server.registerTool(
    "ui_tree",
    {
      title: "UI tree",
      description: "Read what is on screen: one line per element with its text, id, description, bounds and whether it is clickable. Use this to find things to tap instead of guessing coordinates.",
      inputSchema: { maxNodes: z.number().int().min(10).max(2000).optional().describe("Default 300"), device },
      annotations: read,
    },
    ({ maxNodes, device }) => run(async () => {
      const tree = await c.uiTree(device, maxNodes);
      return text(`${tree.shown} of ${tree.total} elements shown\n${tree.text}`);
    }),
  );

  server.registerTool(
    "find_elements",
    { title: "Find elements", description: "Find on-screen elements matching all given fields. Returns text, id, bounds and the centre point of each.", inputSchema: { ...selectorShape, device }, annotations: read },
    ({ device, ...selector }) => run(async () => text(JSON.stringify(await c.findElements(selector as Selector, device), null, 2))),
  );

  server.registerTool(
    "tap_element",
    {
      title: "Tap element",
      description: "Find an on-screen element and tap its centre. Fails if nothing matches.",
      inputSchema: { ...selectorShape, index: z.number().int().min(0).optional().describe("Which match to tap when several match (0 = first)"), device },
      annotations: act,
    },
    ({ device, index, ...selector }) => run(async () => {
      const hit = await c.tapElement(selector as Selector, index, device);
      return text(`Tapped element at (${hit.center.x}, ${hit.center.y})`);
    }),
  );

  server.registerTool(
    "wait_for_element",
    {
      title: "Wait for element",
      description: "Wait until an element matching the fields appears on screen, then return it. Errors on timeout.",
      inputSchema: { ...selectorShape, timeoutMs: z.number().int().min(500).max(120000).optional().describe("Default 10000"), device },
      annotations: read,
    },
    ({ device, timeoutMs, ...selector }) => run(async () => text(JSON.stringify(await c.waitForElement(selector as Selector, timeoutMs, device), null, 2))),
  );

  server.registerTool(
    "screen_dark",
    {
      title: "Keep the screen dark",
      description:
        "Hold the phone's display dark while it stays awake and unlocked, so tests run without a lit screen. " +
        "Taps, swipes, ui_tree, find/tap_element and key presses keep working, and screenshot still captures the real screen. " +
        "The phone must already be unlocked (a locked phone shows only its lock screen to any tool). " +
        "It stays UNLOCKED and awake while this is on, so do not leave it unattended. " +
        "Needs scrcpy installed (brew install scrcpy). Turn it off when done; it is also turned off when the server stops.",
      inputSchema: { enabled: z.boolean().describe("true to make the screen dark, false to restore it"), device },
      annotations: act,
    },
    ({ enabled, device }) => run(async () => {
      const r = await c.screenDark(enabled, device);
      return text(r.dark
        ? `Screen is dark on ${r.serial}. The phone stays awake and unlocked; taps, ui_tree and screenshot keep working.`
        : `Screen restored on ${r.serial}.`);
    }),
  );

  // ---- Notifications: these talk to the DroidMirror Mac app, which holds the phone link ----

  server.registerTool(
    "notification_status",
    {
      title: "Notification link status",
      description: "Whether the phone is connected to the DroidMirror Mac app and whether its two switches (read, and reply/dismiss) are on. Contains no notification text.",
      inputSchema: {},
      annotations: read,
    },
    () => run(async () => text(JSON.stringify(await c.notificationStatus(), null, 2))),
  );

  server.registerTool(
    "list_notifications",
    {
      title: "List phone notifications",
      description:
        "Recent phone notifications, newest first: key, app, title, text, time and whether a reply is possible. " +
        "Needs --allow-notification-text AND the 'Allow local tools to read phone notifications' switch in the DroidMirror Mac menu.",
      inputSchema: { limit: z.number().int().min(1).max(100).optional().describe("Default 20") },
      annotations: read,
    },
    ({ limit }) => run(async () => text(JSON.stringify(await c.listNotifications(limit), null, 2))),
  );

  server.registerTool(
    "wait_for_notification",
    {
      title: "Wait for a notification",
      description: "Wait until a NEW notification arrives that matches all given fields (case-insensitive), then return it. Useful for asserting that an app sent a notification. Same permissions as list_notifications.",
      inputSchema: {
        appContains: z.string().optional().describe("Part of the app name"),
        titleContains: z.string().optional(),
        textContains: z.string().optional(),
        timeoutMs: z.number().int().min(1000).max(300000).optional().describe("Default 30000"),
      },
      annotations: read,
    },
    ({ appContains, titleContains, textContains, timeoutMs }) =>
      run(async () => text(JSON.stringify(await c.waitForNotification({ appContains, titleContains, textContains }, timeoutMs), null, 2))),
  );

  server.registerTool(
    "reply_notification",
    {
      title: "Reply to a notification",
      description:
        "Reply to a phone notification (for example a chat message) AS THE USER, using the key from list_notifications. " +
        "Needs --allow-notification-actions and the 'Allow local tools to reply and dismiss' switch on the Mac. " +
        "The Mac ALWAYS shows the person a dialog with the reply and waits for them to press Send, so this can take a while and can be declined.",
      inputSchema: { key: z.string().min(1).max(500), text: z.string().min(1).max(2000) },
      annotations: { readOnlyHint: false, destructiveHint: true, openWorldHint: true },
    },
    ({ key, text: reply }) => run(async () => { await c.replyNotification(key, reply); return text("Reply sent"); }),
  );

  server.registerTool(
    "dismiss_notification",
    {
      title: "Dismiss a notification",
      description: "Dismiss a phone notification by key. Needs --allow-notification-actions and the 'Allow local tools to reply and dismiss' switch on the Mac.",
      inputSchema: { key: z.string().min(1).max(500) },
      annotations: act,
    },
    ({ key }) => run(async () => { await c.dismissNotification(key); return text("Dismissed"); }),
  );

  return server;
}
