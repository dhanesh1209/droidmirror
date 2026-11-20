import net from "node:net";
import os from "node:os";
import path from "node:path";

export class MacApiError extends Error {}

export interface MacNotification {
  key: string;
  app: string;
  pkg: string;
  title?: string;
  text?: string;
  postedAt: number;
  canReply: boolean;
}

export interface MacStatus {
  connected: boolean;
  phone?: string;
  canRead: boolean;
  canAct: boolean;
  count: number;
}

/** What the notification tools need from the DroidMirror Mac app. */
export interface NotificationBackend {
  status(): Promise<MacStatus>;
  list(limit: number): Promise<MacNotification[]>;
  reply(key: string, text: string): Promise<void>;
  dismiss(key: string): Promise<void>;
}

export function defaultSocketPath(): string {
  return process.env["DROIDMIRROR_SOCKET"] ?? path.join(os.homedir(), "Library/Application Support/DroidMirror/api.sock");
}

/**
 * Talks to the menu-bar app over its local socket (one JSON line per request and reply).
 * The Mac app, not this client, decides what is allowed: its menu switches gate reading and acting,
 * and every reply asks the person at the Mac.
 */
export class MacApiClient implements NotificationBackend {
  private readonly socketPath: string;

  constructor(socketPath: string = defaultSocketPath()) {
    this.socketPath = socketPath;
  }

  private call(method: string, params: Record<string, unknown>, timeoutMs: number): Promise<unknown> {
    return new Promise((resolve, reject) => {
      const socket = net.createConnection(this.socketPath);
      let buffer = "";
      let settled = false;
      const finish = (action: () => void) => {
        if (settled) return;
        settled = true;
        clearTimeout(timer);
        socket.destroy();
        action();
      };
      const timer = setTimeout(() => finish(() => reject(new MacApiError("The DroidMirror Mac app did not answer in time (a reply waits for you to confirm on the Mac)."))), timeoutMs);

      socket.on("connect", () => socket.write(JSON.stringify({ id: 1, method, params }) + "\n"));
      socket.on("data", (chunk) => {
        buffer += chunk.toString("utf8");
        const newline = buffer.indexOf("\n");
        if (newline < 0) return;
        let message: { ok?: boolean; result?: unknown; error?: string };
        try {
          message = JSON.parse(buffer.slice(0, newline));
        } catch {
          finish(() => reject(new MacApiError("Bad reply from the DroidMirror Mac app")));
          return;
        }
        finish(() => (message.ok ? resolve(message.result) : reject(new MacApiError(message.error ?? "The DroidMirror Mac app refused the request"))));
      });
      socket.on("error", (error: NodeJS.ErrnoException) => {
        const missing = error.code === "ENOENT" || error.code === "ECONNREFUSED";
        finish(() => reject(new MacApiError(
          missing
            ? "The DroidMirror menu-bar app is not running (no control socket). Start it first."
            : `Could not reach the DroidMirror Mac app: ${error.message}`,
        )));
      });
      socket.on("close", () => finish(() => reject(new MacApiError("The DroidMirror Mac app closed the connection without answering"))));
    });
  }

  async status(): Promise<MacStatus> {
    return (await this.call("status", {}, 5_000)) as MacStatus;
  }

  async list(limit: number): Promise<MacNotification[]> {
    return (await this.call("list_notifications", { limit }, 5_000)) as MacNotification[];
  }

  async reply(key: string, text: string): Promise<void> {
    // Long timeout: the Mac shows a confirmation dialog and waits for a person.
    await this.call("reply", { key, text }, 120_000);
  }

  async dismiss(key: string): Promise<void> {
    await this.call("dismiss", { key }, 10_000);
  }
}
