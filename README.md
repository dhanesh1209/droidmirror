# DroidMirror

[![npm](https://img.shields.io/npm/v/droidmirror-automation?label=npm%3A%20droidmirror-automation)](https://www.npmjs.com/package/droidmirror-automation) [![CI](https://github.com/dhanesh1209/droidmirror/actions/workflows/ci.yml/badge.svg)](https://github.com/dhanesh1209/droidmirror/actions/workflows/ci.yml) [![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

Your Android phone's notifications on your Mac, with replies, and a tool for driving the phone from scripts and AI agents. It aims for the feel of iPhone Mirroring on Android.

- **Notifications without USB debugging.** A small Android app sends your phone's notifications to a Mac menu-bar app over your own Wi-Fi, encrypted. You can reply to and dismiss them from the Mac.
- **Automation for testing.** An MCP server and a CLI (`automation/`) tap, swipe, type, screenshot and read the screen through adb, so an AI agent or a test script can drive a phone.
- **Screen mirroring** is a thin wrapper around [scrcpy](https://github.com/Genymobile/scrcpy). It needs USB or Wireless debugging.

Status: early. Expect rough edges.

## What works

| Feature | Needs debugging mode? | Verified |
|---|---|---|
| Phone notifications as Mac banners, auto-reconnect, heartbeat | No | Yes |
| Reply and dismiss from the Mac menu | No | Yes (reply with a test notification; not yet with a chat app) |
| QR pairing | No | Yes (re-paired by scanning the QR code, including with the release builds) |
| Notifications and reply/dismiss as MCP tools | No | Yes |
| Taps, swipes, text, screenshots, UI tree (MCP server + CLI) | Yes (adb) | Yes |
| Screen mirroring (scrcpy) | Yes (adb) | Yes (window, touch, keyboard) |

Not yet: pinch and other multi-touch gestures, clipboard and file transfer, Windows and Linux hosts, a store-ready Android release.

## Quick start

You need a Mac (macOS 13+), an Android phone (8+; the app was built for Android 14 to 16), both on the same Wi-Fi.

Pick one way to get the two apps: download them (easiest) or build them from source (nothing to trust but the code you read).

### Option A: download the release files

From the [latest release](https://github.com/dhanesh1209/droidmirror/releases/latest), download `DroidMirror-<version>.pkg` (Mac) and `DroidMirror-<version>.apk` (Android). Check them against `SHA256SUMS`:

```bash
shasum -a 256 DroidMirror-*.pkg DroidMirror-*.apk
```

**Heads-up: the Mac installer is not notarized by Apple** (that needs a paid Apple Developer ID, which this project does not have yet). The first time you open it, macOS says it cannot verify the developer. To continue, only if you downloaded it from this project's releases page and the checksum matches:

1. Open the `.pkg`. When macOS blocks it, go to **System Settings → Privacy & Security**, scroll to **Security** and click **Open Anyway** (shown for about an hour after the attempt), then enter your password.
2. After install, open **DroidMirror** from Applications. If it is blocked too, Control-click it, choose **Open**, then click **Open**.

Apple's own page on this: [Open a Mac app from an unknown developer](https://support.apple.com/guide/mac-help/open-a-mac-app-from-an-unknown-developer-mh40616/mac). Apple warns that overriding this check is a common way Macs get malware, so if you are unsure, use Option B.

On the phone, open the `.apk` from your browser or file manager and allow "install unknown apps" for that app when asked. The `.apk` is signed with the project's release key.

### Option B: build from source

**The Mac app**

```bash
swift run DroidMirrorApp          # or: scripts/make-app.sh && open build/DroidMirror.app
```

An app you build yourself opens without the warning above.

**The Android app**

```bash
cd android
JAVA_HOME=$(/usr/libexec/java_home -v 17) ./gradlew :app:assembleDebug
adb install -r app/build/outputs/apk/debug/app-debug.apk
```

Use JDK 17; very new JDKs can break the Android Gradle Plugin.

Maintainers can build the release files with `scripts/make-release.sh` (see the comments at the top of that script for the signing key it needs).

### Extra tools for mirroring and automation

A phone icon appears in the menu bar. For mirroring and automation, also install adb and scrcpy: `brew install android-platform-tools scrcpy`.

### Pair and allow

1. In the Mac menu, choose **Pair a phone…**. A QR code appears.
2. On the phone, open DroidMirror and tap **Scan QR code from your Mac**.
3. Tap **Open Notification access settings** and switch DroidMirror on.
   If Android says "Restricted setting", open **App info**, tap the ⋮ menu and choose **Allow restricted settings**. Some Samsung phones hide that menu; a developer can run `adb shell cmd appops set dev.droidmirror.companion ACCESS_RESTRICTED_SETTINGS allow` once.
4. Optional: tap **Battery optimization settings** and set DroidMirror to unrestricted, so Android does not stop the link.

The Mac log is at `~/Library/Logs/DroidMirror/companion.log` (app names and text lengths, never message text).

## Automation and MCP

Install: `npm install --ignore-scripts droidmirror-automation` ([npm package](https://www.npmjs.com/package/droidmirror-automation)).

**Setup guide: [automation/SETUP.md](automation/SETUP.md).** Reference: [automation/README.md](automation/README.md). Control is off until you pass `--allow-control` and name the phone with `--device <serial>`. Reading notifications and replying are separate opt-ins, and the Mac app has its own switches for both, off by default. Every reply asks for confirmation on the Mac.

## Security model

- Phone and Mac talk over your local network with AES-256-GCM. The QR code carries a random 32-byte secret; treat it like a password and reset pairing from the Mac menu if it leaks. Each connection derives fresh keys, so recorded traffic cannot be replayed.
- The Mac's tool socket is readable only by your user, and tools can do nothing until you switch them on in the menu.
- Message text is never written to logs.
- There is no cloud service and no account.

## Repository layout

| Path | What it is |
|---|---|
| `Sources/DroidMirrorCore` | Swift core: encrypted protocol, companion server, control socket, adb helpers |
| `Sources/DroidMirrorApp` | The menu-bar app |
| `Sources/droidmirror` | A small CLI (`devices`, `mirror`, `notifications`, `companion`) |
| `android/` | The Android companion app (Kotlin, no UI framework) |
| `automation/` | MCP server and CLI for driving a phone (Node, TypeScript) |
| `protocol/` | Test vectors that keep the Swift and Kotlin crypto in agreement |
| `PLAN.md` | Design notes and the wire protocol |

## Development

```bash
swift test                                       # Swift tests
cd automation && npm install --ignore-scripts && npm test
cd android && ./gradlew :app:testDebugUnitTest   # JDK 17
```

## Known limitations

- Mac banners are sent through `osascript`, so macOS labels them "Script Editor" and Script Editor's notifications must be allowed. Native notifications need a signed app bundle.
- The app bundle from `scripts/make-app.sh` is ad-hoc signed, for local use only.
- Android may stop the background link on phones with aggressive battery management.
- Protected screens (banking, payments) cannot be mirrored or captured; Android blocks it.

## License

MIT. See [LICENSE](LICENSE).
