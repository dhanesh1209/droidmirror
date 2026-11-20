import type { DeviceInfo, PhoneBackend, ScrollDirection, Size } from "../src/backend.ts";
import { parseUiTree } from "../src/uiTree.ts";
import type { UiNode } from "../src/uiTree.ts";

/** Synthetic screen: a login button, a text view with escaped characters, and an invisible node. */
export const SAMPLE_XML = `<?xml version='1.0' encoding='UTF-8' standalone='yes' ?>
<hierarchy rotation="0">
  <node index="0" text="" resource-id="" class="android.widget.FrameLayout" package="com.example" content-desc="" clickable="false" enabled="true" scrollable="false" checked="false" bounds="[0,0][1080,2340]">
    <node index="0" text="Log in" resource-id="com.example:id/login" class="android.widget.Button" package="com.example" content-desc="" clickable="true" enabled="true" scrollable="false" checked="false" bounds="[100,200][300,400]" />
    <node index="1" text="a &lt; b &amp; &quot;c&quot; &#x41;" resource-id="" class="android.widget.TextView" package="com.example" content-desc="x > y" clickable="false" enabled="true" scrollable="false" checked="false" bounds="[0,500][1080,600]" />
    <node index="2" text="Hidden" resource-id="" class="android.widget.TextView" package="com.example" content-desc="" clickable="false" enabled="true" scrollable="false" checked="false" bounds="[0,0][0,0]" />
  </node>
</hierarchy>`;

export const PNG_BYTES = Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0, 0, 0, 0]);

/** A phone that records what it was asked to do. */
export class FakeBackend implements PhoneBackend {
  calls: unknown[][] = [];
  tree: UiNode[] = parseUiTree(SAMPLE_XML);
  /** When set, uiTree returns an empty screen this many times before showing the real one. */
  emptyScreens = 0;

  async listDevices(): Promise<DeviceInfo[]> {
    return [
      { serial: "ALLOWED1", state: "device", model: "Pixel_Test", transport: "usb" },
      { serial: "OTHER2", state: "device", transport: "wifi" },
    ];
  }
  async size(): Promise<Size> { return { width: 1080, height: 2340 }; }
  async tap(serial: string, x: number, y: number) { this.calls.push(["tap", serial, x, y]); }
  async doubleTap(serial: string, x: number, y: number) { this.calls.push(["doubleTap", serial, x, y]); }
  async longPress(serial: string, x: number, y: number, ms: number) { this.calls.push(["longPress", serial, x, y, ms]); }
  async swipe(serial: string, x1: number, y1: number, x2: number, y2: number, ms: number) { this.calls.push(["swipe", serial, x1, y1, x2, y2, ms]); }
  async scroll(serial: string, direction: ScrollDirection, fraction: number) { this.calls.push(["scroll", serial, direction, fraction]); }
  async text(serial: string, text: string) { this.calls.push(["text", serial, text]); }
  async key(serial: string, name: string) { this.calls.push(["key", serial, name]); }
  async screenshot(serial: string) { this.calls.push(["screenshot", serial]); return PNG_BYTES; }
  async uiTree(serial: string) {
    this.calls.push(["uiTree", serial]);
    if (this.emptyScreens > 0) { this.emptyScreens--; return []; }
    return this.tree;
  }
  async launch(serial: string, pkg: string) { this.calls.push(["launch", serial, pkg]); }
  async stop(serial: string, pkg: string) { this.calls.push(["stop", serial, pkg]); }
}
