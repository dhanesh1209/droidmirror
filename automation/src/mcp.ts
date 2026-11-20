#!/usr/bin/env node
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { createAdbRunner } from "./adb.ts";
import { AdbBackend } from "./backend.ts";
import { SERVER_USAGE, parseServerArgs } from "./config.ts";
import { Controller, stderrLogger } from "./controller.ts";
import { ScrcpyDarkScreen } from "./darkScreen.ts";
import { MacApiClient } from "./macApi.ts";
import { Policy } from "./policy.ts";
import { createServer } from "./server.ts";

let parsed;
try {
  parsed = parseServerArgs(process.argv.slice(2), process.env);
} catch (error) {
  console.error(error instanceof Error ? error.message : String(error));
  process.exit(2);
}
if (parsed.help) {
  console.error(SERVER_USAGE);
  process.exit(0);
}

const policy = new Policy(parsed.options);
const controller = new Controller(policy, new AdbBackend(createAdbRunner()), {
  log: stderrLogger,
  notifications: new MacApiClient(),
  darkScreen: new ScrcpyDarkScreen(),
});
const server = createServer(controller);

// A dark screen must never be left behind: restore it when the client disconnects, on Ctrl-C or kill, and on exit.
server.server.onclose = () => { void controller.close(); };
for (const signal of ["SIGINT", "SIGTERM"] as const) {
  process.on(signal, () => { void controller.close().finally(() => process.exit(0)); });
}
process.on("exit", () => controller.closeNow());
await server.connect(new StdioServerTransport());
console.error(
  `droidmirror-mcp ready: control=${policy.allowControl ? "on" : "off"} ` +
    `devices=[${policy.allowedSerials.join(", ")}] notification-text=${policy.allowNotificationText ? "on" : "off"} ` +
    `notification-actions=${policy.allowNotificationActions ? "on" : "off"}`,
);
