# Setting up DroidMirror automation

A step-by-step guide to let a script, a CI job or an AI agent (through MCP) drive an Android phone: taps, swipes, typing, screenshots, reading what is on screen, and optionally reading and replying to the phone's notifications. For the full command reference see [README.md](README.md).

**Time needed:** about 15 minutes the first time.

## What you need

| Thing | Why | How to check |
|---|---|---|
| A computer with **Node 24 or newer** | Runs the tool | `node -v` |
| **adb** (Android platform tools) | How the tool talks to the phone | `adb version` |
| An **Android phone** and a USB cable | The device you will drive | See step 2 |
| *(optional)* **scrcpy** | Only for "screen dark" mode | `scrcpy --version` |
| *(optional)* The **DroidMirror Mac app** | Only for notification tools | See step 7 |

## 1. Install adb

On a Mac with Homebrew:

```bash
brew install android-platform-tools
```

On other systems, install Google's "platform-tools" and make sure `adb` is on your PATH. If it lives somewhere unusual, set `ADB=/full/path/to/adb` before running any command below.

## 2. Prepare the phone

1. Open **Settings → About phone → Software information** and tap **Build number** seven times. This unlocks Developer options. (Menu names vary a little between brands.)
2. Open **Settings → Developer options** and turn on **USB debugging**.
3. Plug the phone into the computer with a USB cable.
4. The phone asks **"Allow USB debugging?"**. Tick "Always allow from this computer" and tap **Allow**. Only do this on a computer you trust.
5. Check it worked:

```bash
adb devices
```

You should see one line with a serial number and the word `device`:

```
YOUR_DEVICE_SERIAL    device
```

Note the serial: you need it below. If it says `unauthorized`, unlock the phone and accept the prompt from step 4. If nothing is listed, try another cable or port, because some cables only charge.

> **Test phones only, ideally.** USB debugging gives a connected computer wide control of the phone. Use a dedicated test device, not your personal phone, where you can.

## 3. Install the tool

Install it from npm into a project folder:

```bash
mkdir my-phone-tests && cd my-phone-tests
npm init -y
npm install --ignore-scripts droidmirror-automation
```

(No network? Each [GitHub release](https://github.com/dhanesh1209/droidmirror/releases/latest) also has the same package as a `.tgz` file: `npm install --ignore-scripts /path/to/droidmirror-automation-<version>.tgz`.)

## 4. Try it from the command line

Nothing is allowed until you name the phone with `--device`. Use your serial from step 2:

```bash
npx droidmirror-auto devices
npx droidmirror-auto --device YOUR_DEVICE_SERIAL size
npx droidmirror-auto --device YOUR_DEVICE_SERIAL launch com.android.settings
npx droidmirror-auto --device YOUR_DEVICE_SERIAL tree
npx droidmirror-auto --device YOUR_DEVICE_SERIAL tap-element --text-contains "wi-fi"
npx droidmirror-auto --device YOUR_DEVICE_SERIAL screenshot --out screen.png
```

If `size` prints the phone's resolution, everything works. The phone must be **unlocked and awake** for taps and screenshots to work: a locked phone shows only its lock screen to any tool.

## 5. Connect an AI agent (MCP)

The MCP server is `droidmirror-mcp`. It needs two things to do anything: `--allow-control` and at least one `--device <serial>`. Without them it refuses every control action.

Find the absolute path of the installed command first (run this inside `my-phone-tests`):

```bash
echo "$(pwd)/node_modules/.bin/droidmirror-mcp"
```

**Claude Code:**

```bash
claude mcp add droidmirror -- /full/path/from/above/droidmirror-mcp --allow-control --device YOUR_DEVICE_SERIAL
```

**Claude Desktop** (and most other MCP clients) use a JSON config. Add this under `mcpServers` in `claude_desktop_config.json`, then restart the app:

```json
{
  "mcpServers": {
    "droidmirror": {
      "command": "/full/path/from/above/droidmirror-mcp",
      "args": ["--allow-control", "--device", "YOUR_DEVICE_SERIAL"]
    }
  }
}
```

Then ask the agent something like: *"Open Settings on the phone, find the Wi-Fi screen and take a screenshot."*

Tips for good results:
- Tell the agent to read the screen with `ui_tree` and tap with `tap_element`, rather than guessing coordinates.
- Many apps show button text in capitals, so match with `textContains`.
- To allow several phones, repeat `--device`. Only the phones you name are ever touched.

## 6. Optional: keep the phone's screen dark

Useful for test racks, or to avoid a lit screen on a desk. Install scrcpy (`brew install scrcpy`), then:

```bash
npx droidmirror-auto --device YOUR_DEVICE_SERIAL dark -- npm test
```

The screen stays dark while your command runs and is restored when it ends. Over MCP this is the `screen_dark` tool.

Important:
- The phone must already be **unlocked**, and it **stays unlocked and awake** while dark. Do not leave it unattended in a public place.

## 7. Optional: notification tools

These let an agent read the phone's notifications, wait for one (for example a login code during a test), dismiss it, or reply to it. They go through the **DroidMirror Mac app**, which keeps the phone's notifications on the Mac over your own Wi-Fi without USB debugging.

1. Install the Mac app from the release (`DroidMirror-<version>.pkg`). It is not notarized, so macOS warns on first open: go to **System Settings → Privacy & Security → Open Anyway**.
2. Install the Android app (`DroidMirror-<version>.apk`) on the phone. You may need to allow installs from your browser or file manager the first time.
3. On the Mac, click the DroidMirror icon in the menu bar, choose **Pair a phone…** and scan the QR code from the phone app. Follow the checklist on the phone app: notification access on, and battery set to unrestricted so Android does not stop the link.
4. On the Mac menu, open **Automation** and switch on:
   - **Let tools read notifications**, to list and wait for notifications.
   - **Let tools reply and dismiss**, to dismiss or reply.
   Both are **off by default**, and only you can turn them on.
5. Start the MCP server with the matching flags:

```bash
droidmirror-mcp --allow-control --device YOUR_DEVICE_SERIAL \
  --allow-notification-text --allow-notification-actions
```

(Leave off `--allow-notification-actions` if the agent should only read.)

Tools you get: `notification_status`, `list_notifications`, `wait_for_notification`, `dismiss_notification` and `reply_notification`.

**Every reply still asks you first.** A dialog on the Mac shows the reply and waits for you to confirm, each time. This cannot be turned off.

## Safety summary

- Control is off until you pass `--allow-control`, and only phones named with `--device` are touched.
- Reading notification text and acting on notifications are two more separate switches, plus the two Mac menu switches.
- Actions are logged as JSON to stderr. Typed text, selectors and screen contents are never logged.
- The Mac app's log is at `~/Library/Logs/DroidMirror/companion.log` (open it from the menu with **Show activity log**). It records app names and text lengths only, never message text.

## Troubleshooting

| Symptom | Likely cause and fix |
|---|---|
| `adb devices` shows nothing | Try another cable or USB port; check USB debugging is on; some cables only charge. |
| `unauthorized` | Unlock the phone and accept the "Allow USB debugging?" prompt. If it never appears, turn USB debugging off and on again. |
| Tools say the device or control is not allowed | Pass `--allow-control` and `--device <serial>` exactly as `adb devices` shows the serial. |
| Taps do nothing or screenshots are black | The phone is locked or its screen is off. Unlock it first. Banking and payment screens always return blank screenshots. |
| `adb: command not found` | Install adb (step 1) or set `ADB=/full/path/to/adb`. |
| Typing drops characters or fails | Typing supports printable ASCII only, and the literal text `%s` cannot be typed. |
| Notification tools say the app is unreachable | The DroidMirror Mac app must be running with a phone connected, and the Automation switches must be on. |
| Phone app shows "Needs attention" | Open it and follow the checklist: usually notification access or battery restriction. |

## Known limits

- Each tap or key costs about 70 ms and a screenshot about 280 ms over USB. Fine for test steps, not for fast continuous drags.
- No multi-touch (pinch, rotate) yet.
- Wi-Fi debugging (instead of USB) is untested and will be slower.
