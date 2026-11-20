# DroidMirror automation

Drive an Android phone for test automation: taps, swipes, long press, scroll, typing, keys, app launch, screenshots, and reading what is on screen. Use it from an AI agent (MCP server) or from scripts and CI (CLI). It uses `adb`, so the phone needs USB or Wireless debugging on, which test devices normally have.

**New here? Follow the step-by-step guide: [SETUP.md](SETUP.md).** This page is the reference.

Requires Node 24 or newer and `adb` on your PATH (or set `ADB=/path/to/adb`).

Install from npm:

```bash
npm install --ignore-scripts droidmirror-automation
npx droidmirror-auto devices
```

The package ships compiled JavaScript (`npm run build`, run automatically by `npm pack` and `npm publish`). To build it yourself from this repository: `npm install --ignore-scripts && npm run build && npm pack`.

Working on this repo itself runs the TypeScript directly (`npm test`, `node src/cli.ts ...`), with no build step.

## Safety: opt-in, and only the phones you name

Nothing is allowed by default. There are no per-action prompts, because tests run hundreds of actions; instead:

- Control (taps, swipes, text, keys, launch/stop, screenshots, UI tree) is **off** until you pass `--allow-control`.
- Only devices you list with `--device <serial>` are ever touched. A phone that is merely plugged in is ignored.
- Reading notification text is a separate switch (`--allow-notification-text`).
- Every action is logged to stderr as JSON. Typed text, selector values and screen contents are never logged.

## MCP server

```bash
node src/mcp.ts --allow-control --device YOUR_DEVICE_SERIAL
```

For Claude Code, add it as a server (replace the path and serial):

```bash
claude mcp add droidmirror -- node /path/to/automation/src/mcp.ts --allow-control --device <serial>
```

Tools: `list_devices`, `device_size`, `tap`, `double_tap`, `long_press`, `swipe`, `scroll`, `type_text`, `press_key`, `launch_app`, `stop_app`, `screenshot`, `ui_tree`, `find_elements`, `tap_element`, `wait_for_element`.

Prefer `ui_tree` + `tap_element` over guessing coordinates. Match text with `textContains`: many apps show button text in capitals.

## CLI

```bash
node src/cli.ts devices
node src/cli.ts --device <serial> launch com.android.settings
node src/cli.ts --device <serial> tree
node src/cli.ts --device <serial> tap-element --text-contains "wi-fi"
node src/cli.ts --device <serial> swipe 540 1700 540 600 300
node src/cli.ts --device <serial> screenshot --out screen.png
```

Naming the device with `--device` (or `DROIDMIRROR_DEVICES`) is the opt-in for the CLI.

## Screen-dark mode

Run tests while the phone's screen stays dark: no lit screen on a desk or in a device rack, and the phone stays awake. Taps, swipes, key presses, the UI tree and screenshots all keep working.

```bash
node src/cli.ts --device <serial> dark -- npm test      # dark while the command runs, then restored
node src/cli.ts --device <serial> dark                  # dark until Ctrl-C
```

Over MCP it is the `screen_dark` tool (`enabled: true` or `false`). It needs `--allow-control` and a named device like every other control tool, and `scrcpy` installed (`brew install scrcpy`).

How it works and what to know:

- It runs scrcpy with no window and no audio, and scrcpy powers the display off at its own layer. `adb shell cmd display power-off` does not work for this: in a test on a Samsung SM-S916B (Android 16) taps were ignored and screenshots were black.
- **The phone must already be unlocked, and it stays unlocked and awake while the screen is dark.** A locked phone shows only its lock screen to any tool. Do not leave a dark, unlocked phone unattended.
- The screen is restored when you turn it off, when the server or CLI stops, when the MCP client disconnects, and on Ctrl-C or kill. As a backstop it also runs `cmd display power-reset 0`.
- Checked on one phone only. Behavior elsewhere is untested.

## Limits (measured on a Samsung SM-S916B, Android 16, over USB)

- Each `adb shell input` call costs about 70 ms, and a screenshot about 280 ms. Fine for test steps, not for fast continuous drags.
- `adb input` has no multi-touch, so pinch and rotate are not available yet. The tools sit behind a backend interface so a scrcpy or accessibility backend can be added later.
- Typing supports printable ASCII only, and the literal text `%s` cannot be typed.
- Protected screens (banking, payments) return blank screenshots.
- On Android 16, `uiautomator dump` to the terminal prints no XML, so the tool dumps to a temporary file on the phone, reads it, and deletes it.
- Wi-Fi debugging is untested and will be slower than USB.
