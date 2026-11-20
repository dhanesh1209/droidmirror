import type { PhoneBackend, ScrollDirection, Size } from "./backend.ts";
import type { DarkScreenProvider, DarkSession } from "./darkScreen.ts";
import type { MacNotification, MacStatus, NotificationBackend } from "./macApi.ts";
import { PolicyError } from "./policy.ts";
import type { Policy } from "./policy.ts";
import { InputError } from "./shell.ts";
import { center, compactTree, findNodes, hasSelector } from "./uiTree.ts";
import type { Bounds, Selector, UiNode } from "./uiTree.ts";

export type Logger = (event: Record<string, unknown>) => void;

/** Logs one JSON line per action to stderr (stdout belongs to the MCP protocol). Never includes typed text or screen contents. */
export const stderrLogger: Logger = (event) => {
  console.error(JSON.stringify({ t: new Date().toISOString(), ...event }));
};
export const silentLogger: Logger = () => {};

export class ElementNotFound extends Error {}
export class NotificationTimeout extends Error {}

/** All given fields must match; matching ignores case. */
export interface NotificationFilter {
  appContains?: string;
  titleContains?: string;
  textContains?: string;
}

export interface MatchedElement {
  text: string;
  resourceId: string;
  contentDesc: string;
  className: string;
  clickable: boolean;
  bounds: Bounds;
  center: { x: number; y: number };
}

function toMatched(n: UiNode): MatchedElement {
  return {
    text: n.text,
    resourceId: n.resourceId,
    contentDesc: n.contentDesc,
    className: n.className,
    clickable: n.clickable,
    bounds: n.bounds,
    center: center(n.bounds),
  };
}

function selectorKeys(sel: Selector): string[] {
  return Object.entries(sel).filter(([, v]) => v !== undefined).map(([k]) => k);
}

/** Every operation goes through the policy first, then the backend. */
export class Controller {
  readonly policy: Policy;
  private readonly backend: PhoneBackend;
  private readonly log: Logger;
  private readonly sleep: (ms: number) => Promise<void>;
  private readonly notifications?: NotificationBackend;
  private readonly darkProvider?: DarkScreenProvider;
  private readonly darkSessions = new Map<string, DarkSession>();

  constructor(
    policy: Policy,
    backend: PhoneBackend,
    options: { log?: Logger; sleep?: (ms: number) => Promise<void>; notifications?: NotificationBackend; darkScreen?: DarkScreenProvider } = {},
  ) {
    this.policy = policy;
    this.backend = backend;
    this.log = options.log ?? silentLogger;
    this.sleep = options.sleep ?? ((ms) => new Promise((resolve) => setTimeout(resolve, ms)));
    this.notifications = options.notifications;
    this.darkProvider = options.darkScreen;
  }

  /** Lists every device adb can see, marking which ones this server may control. Needs no opt-in. */
  async devices() {
    const list = await this.backend.listDevices();
    return list.map((d) => ({ ...d, allowed: this.policy.isAllowed(d.serial) }));
  }

  async size(device?: string): Promise<Size> {
    return this.backend.size(this.policy.requireControl(device));
  }

  async tap(x: number, y: number, device?: string): Promise<void> {
    const s = this.policy.requireControl(device);
    await this.backend.tap(s, x, y);
    this.log({ action: "tap", device: s, x, y });
  }

  async doubleTap(x: number, y: number, device?: string): Promise<void> {
    const s = this.policy.requireControl(device);
    await this.backend.doubleTap(s, x, y);
    this.log({ action: "double_tap", device: s, x, y });
  }

  async longPress(x: number, y: number, durationMs = 800, device?: string): Promise<void> {
    const s = this.policy.requireControl(device);
    await this.backend.longPress(s, x, y, durationMs);
    this.log({ action: "long_press", device: s, x, y, durationMs });
  }

  async swipe(x1: number, y1: number, x2: number, y2: number, durationMs = 300, device?: string): Promise<void> {
    const s = this.policy.requireControl(device);
    await this.backend.swipe(s, x1, y1, x2, y2, durationMs);
    this.log({ action: "swipe", device: s, x1, y1, x2, y2, durationMs });
  }

  async scroll(direction: ScrollDirection, fraction = 0.5, device?: string): Promise<void> {
    const s = this.policy.requireControl(device);
    await this.backend.scroll(s, direction, fraction);
    this.log({ action: "scroll", device: s, direction, fraction });
  }

  async text(text: string, device?: string): Promise<void> {
    const s = this.policy.requireControl(device);
    await this.backend.text(s, text);
    this.log({ action: "type_text", device: s, length: text.length }); // length only, never the text
  }

  async key(name: string, device?: string): Promise<void> {
    const s = this.policy.requireControl(device);
    await this.backend.key(s, name);
    this.log({ action: "press_key", device: s, key: name.toUpperCase() });
  }

  async launch(pkg: string, device?: string): Promise<void> {
    const s = this.policy.requireControl(device);
    await this.backend.launch(s, pkg);
    this.log({ action: "launch_app", device: s, package: pkg });
  }

  async stop(pkg: string, device?: string): Promise<void> {
    const s = this.policy.requireControl(device);
    await this.backend.stop(s, pkg);
    this.log({ action: "stop_app", device: s, package: pkg });
  }

  async screenshot(device?: string): Promise<Buffer> {
    const s = this.policy.requireControl(device);
    const png = await this.backend.screenshot(s);
    this.log({ action: "screenshot", device: s, bytes: png.length });
    return png;
  }

  async uiTree(device?: string, maxNodes = 300) {
    const s = this.policy.requireControl(device);
    const nodes = await this.backend.uiTree(s);
    this.log({ action: "ui_tree", device: s, nodes: nodes.length });
    return compactTree(nodes, maxNodes);
  }

  async findElements(selector: Selector, device?: string): Promise<MatchedElement[]> {
    if (!hasSelector(selector)) throw new InputError("Give at least one selector field (text, textContains, resourceId, contentDesc, className, ...)");
    const s = this.policy.requireControl(device);
    const matches = findNodes(await this.backend.uiTree(s), selector).map(toMatched);
    this.log({ action: "find_elements", device: s, selector: selectorKeys(selector), matches: matches.length });
    return matches;
  }

  /** Finds an element and taps the centre of it. `index` picks among several matches (0 = first). */
  async tapElement(selector: Selector, index = 0, device?: string): Promise<MatchedElement> {
    const matches = await this.findElements(selector, device);
    if (matches.length === 0) throw new ElementNotFound("No element on screen matched the selector");
    const hit = matches[index];
    if (!hit) throw new ElementNotFound(`Only ${matches.length} element(s) matched; index ${index} is out of range`);
    const s = this.policy.requireControl(device);
    await this.backend.tap(s, hit.center.x, hit.center.y);
    this.log({ action: "tap_element", device: s, selector: selectorKeys(selector), index, x: hit.center.x, y: hit.center.y });
    return hit;
  }

  /** Polls the UI until an element matches, or throws after `timeoutMs`. */
  async waitForElement(selector: Selector, timeoutMs = 10_000, device?: string, pollMs = 500): Promise<MatchedElement[]> {
    const deadline = Date.now() + timeoutMs;
    for (;;) {
      const matches = await this.findElements(selector, device);
      if (matches.length > 0) return matches;
      if (Date.now() >= deadline) throw new ElementNotFound(`Element did not appear within ${timeoutMs} ms`);
      await this.sleep(pollMs);
    }
  }

  // ---- Notifications (served by the DroidMirror Mac app, which holds the phone link) ----

  private notificationBackend(): NotificationBackend {
    if (!this.notifications) throw new PolicyError("Notification tools are not available: this server has no connection to the DroidMirror Mac app.");
    return this.notifications;
  }

  /** Phone connection and the Mac app's two switches. Holds no notification text, so it needs no opt-in. */
  async notificationStatus(): Promise<MacStatus> {
    return this.notificationBackend().status();
  }

  async listNotifications(limit = 20): Promise<MacNotification[]> {
    this.policy.requireNotificationText();
    const items = await this.notificationBackend().list(limit);
    this.log({ action: "list_notifications", count: items.length });
    return items;
  }

  async dismissNotification(key: string): Promise<void> {
    this.policy.requireNotificationActions();
    await this.notificationBackend().dismiss(key);
    this.log({ action: "dismiss_notification" });
  }

  /** Sends a reply as the user. The Mac app always asks the person to confirm each one. */
  async replyNotification(key: string, text: string): Promise<void> {
    this.policy.requireNotificationActions();
    const reply = text.trim();
    if (reply.length === 0) throw new InputError("The reply text is empty");
    if (reply.length > 2000) throw new InputError("The reply is longer than 2000 characters");
    await this.notificationBackend().reply(key, reply);
    this.log({ action: "reply_notification", length: reply.length });   // length only, never the text
  }

  /** Waits for a notification that was not there when the call started and matches the filter. */
  async waitForNotification(filter: NotificationFilter = {}, timeoutMs = 30_000, pollMs = 1_000): Promise<MacNotification> {
    this.policy.requireNotificationText();
    const backend = this.notificationBackend();
    const signature = (n: MacNotification) => `${n.key}|${n.title ?? ""}|${n.text ?? ""}`;
    const has = (haystack: string | undefined, needle: string | undefined) =>
      needle === undefined || (haystack ?? "").toLowerCase().includes(needle.toLowerCase());
    const matches = (n: MacNotification) => has(n.app, filter.appContains) && has(n.title, filter.titleContains) && has(n.text, filter.textContains);

    const baseline = new Set((await backend.list(100)).map(signature));
    const deadline = Date.now() + timeoutMs;
    for (;;) {
      const fresh = (await backend.list(100)).find((n) => !baseline.has(signature(n)) && matches(n));
      if (fresh) {
        this.log({ action: "wait_for_notification", matched: true, app: fresh.app });
        return fresh;
      }
      if (Date.now() >= deadline) throw new NotificationTimeout(`No matching new notification arrived within ${timeoutMs} ms`);
      await this.sleep(pollMs);
    }
  }

  // ---- Screen-dark mode: the display stays off while the phone stays awake and unlocked ----

  /** Turns screen-dark mode on or off for one phone. The phone must already be unlocked. */
  async screenDark(enabled: boolean, device?: string): Promise<{ serial: string; dark: boolean }> {
    const serial = this.policy.requireControl(device);
    const existing = this.darkSessions.get(serial);
    if (existing && !existing.alive) this.darkSessions.delete(serial);   // the helper died, for example the phone was unplugged
    if (enabled) {
      if (!this.darkProvider) throw new PolicyError("Screen-dark mode is not available in this server.");
      if (!this.darkSessions.has(serial)) {
        this.darkSessions.set(serial, await this.darkProvider.start(serial));
        this.log({ action: "screen_dark", device: serial, enabled: true });
      }
      return { serial, dark: true };
    }
    const session = this.darkSessions.get(serial);
    if (session) {
      this.darkSessions.delete(serial);
      await session.stop();
      this.log({ action: "screen_dark", device: serial, enabled: false });
    }
    return { serial, dark: false };
  }

  isDark(serial: string): boolean {
    return this.darkSessions.get(serial)?.alive ?? false;
  }

  /** Restores every dark screen. Call on shutdown. */
  async close(): Promise<void> {
    const sessions = [...this.darkSessions.values()];
    this.darkSessions.clear();
    await Promise.all(sessions.map((s) => s.stop().catch(() => {})));
  }

  /** For process-exit handlers, where nothing can be awaited. */
  closeNow(): void {
    for (const s of this.darkSessions.values()) s.killNow();
    this.darkSessions.clear();
  }
}
