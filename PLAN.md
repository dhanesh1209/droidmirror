# DroidMirror v2 plan: no-debug companion + automation (MCP)

Why: AirDoxx (https://github.com/shanmuckh/AirDoxx) already does scrcpy-based mirroring and polls `dumpsys` over adb, so everything in it needs Developer options. Our differentiators: (1) a companion Android app that works **without debugging mode**, (2) an **automation/MCP interface**, (3) an **open license (MIT)**.

## Decisions (user)
- Link: local Wi-Fi, encrypted, paired once by QR. No cloud relay.
- MCP: thin Node/TypeScript bridge talking to the Mac app over a local-only Unix socket.
- MCP v1 tools: read notifications; reply and dismiss; screenshot and tap (adb, opt-in); send text or file.
- Android build: Gradle via Homebrew.

## Architecture
```
Android companion (Kotlin)  <-- AES-256-GCM over TCP, Bonjour/QR -->  Mac menu-bar app (Swift)
  NotificationListenerService                                          CompanionServer (Network.framework)
  foreground service                                                   notification store, Notifier
                                                                       local API: ~/Library/Application Support/DroidMirror/api.sock (0600)
                                                                                   ^
                                                                       Node MCP bridge (stdio)  <--  Claude / agents
adb (debug mode, optional): mirroring (scrcpy), screenshot, tap
```

## Wire protocol (v1)
- On connect each side sends a 16-byte random salt in the clear (Mac first, then phone). `salt = macSalt || phoneSalt`.
- Frame: 4-byte big-endian length (of the body), then body = `nonce(12) || ciphertext || tag(16)` of AES-256-GCM, no AAD.
- Plaintext = `seq(8, big-endian) || JSON payload`. `seq` starts at 1 and strictly increases per direction; the receiver rejects anything not greater than the last seen.
- Keys: 32-byte random pairing secret from the QR. Per-direction, per-session key = HMAC-SHA256(secret, label || salt) with label `mac->phone` or `phone->mac` (UTF-8). A fresh salt per connection means frames recorded in an earlier session fail to decrypt. Nonce = random 12 bytes.
- Max frame body 1 MiB (file chunks are 64 KiB).
- Interop proof: `protocol/gen-vectors.mjs` (Node crypto) generates `protocol/test-vectors.json`; Swift and Kotlin tests must decrypt it.
- QR payload (JSON): `{v:1, host, port, secret(base64), mac_name}`. Shown only in the Mac app; one-time use, expires in 5 minutes.
- Messages (JSON `type`): `hello`, `notification`, `dismissed`, `action` (reply / dismiss / click), `clipboard`, `file_begin|file_chunk|file_end`, `ping`.

## Security rules
- MCP/AI access is **off by default**. Read-only tools need the "Allow AI to read notifications" switch. Any action (reply, dismiss, tap, send) shows a confirmation on the Mac every time.
- API socket is user-only (0600). No network listener for MCP.
- Notification text is never logged. Logs hold counts and package names only.
- Pairing secret stored in macOS Keychain on the Mac and Android Keystore-wrapped storage on the phone.

## Phases
1. Protocol + crypto + framing in Swift and Kotlin with shared test vectors (interop proof). [first]
2. Mac `CompanionServer` + notification store + local API, tested with a simulated phone client.
3. Android app: pairing (QR), notification listener, foreground service. Build with Gradle, install on the real phone.
4. End to end: phone notification appears on the Mac without USB debugging.
5. Reply/dismiss (RemoteInput, `cancelNotification`) and two-way dismiss sync.
6. Node MCP bridge: tools `list_notifications`, `reply_notification`, `dismiss_notification`, `screenshot`, `tap`, `send_text`, `send_file`.
7. Clipboard and file transfer.
8. Security review, README, MIT license, Homebrew tap.

## Risks / unknowns
- Android may kill the background service on Samsung (battery optimisation): needs testing on SM-S916B.
- Reply requires the source app to expose a RemoteInput action; not all do.
- No-debug screen mirroring is out of scope (needs MediaProjection + accessibility; unverified and heavy).
- Foreground service type and notification-access flow must be verified against Android 14-16 docs before coding.
