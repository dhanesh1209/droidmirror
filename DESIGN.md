---
name: DroidMirror
description: Native-first, status-forward utility UI for a Mac menu-bar app and its Android companion.
colors:
  accent: "#1A73E8"
  connected: system green
  attention: system amber
  destructive: system red
  neutrals: system (follow light and dark)
typography:
  mac: SF Pro (system); SF Mono for IP addresses and codes
  android: Roboto (platform default); monospace for codes
spacing:
  base: 4pt
  rhythm: 8pt
  mac-window-padding: 20pt
  mac-group-gap: 12pt
  android-margin: 16dp
  android-row: 8dp
motion: minimal-functional, system transitions only
---

# DroidMirror design system

## Direction
Industrial/utilitarian, native-first. Quiet, status-forward, nothing decorative. It serves
"powerful, but you stay in control": state and consent are shown in plain words.

## Decisions
- **Platform type is a justified exception to "no system font".** macOS draws the menu and the
  surfaces are Operate tools; matching the platform is the point. Hierarchy comes from size and weight.
- **One accent**, #1A73E8 (matches the app icon), for interactive emphasis only.
- **State words are the same everywhere:** connected, needs attention, off. Green = connected,
  amber = needs attention, red = destructive actions only.
- **Light vs dark follows the system.**

## Menu bar (sections, subsections as submenus)
1. Phone (header carries state: "Phone: <name> connected" or "Phone: not connected"): Pair another phone...
2. Notifications: Recent (n) > item > Reply... / Dismiss on phone; Show alerts on this Mac
3. Mirroring (rows explain the USB or Wi-Fi debugging need): Mirror <name>; Keep the phone's screen off; Set up Wi-Fi mirroring...
4. Automation > : Let tools read notifications; Let tools reply and dismiss; note that every reply still asks first
5. Show activity log; Quit DroidMirror
- The menu-bar icon shows a slashed phone when not connected.
- No "Refresh" row: the menu updates itself every 3 seconds.
- Device names are normalised (SM_S916B and SM-S916B show as SM-S916B).

## Deliberate risks
1. The pairing QR is hidden while a phone is connected (button: "Show QR code to pair another phone").
2. Developer switches live in an "Automation" submenu that shows "(on)" when any tool access is enabled.
3. The menu-bar icon changes when disconnected.

## Windows (Mac)
Single column, fixed width, 20pt padding, 12pt between groups. Codes and addresses in SF Mono.
Destructive buttons use the red role; the primary action uses the default (accent) button.

## Android
16dp margins, 8dp rows, themed light and dark, a status card first, then numbered setup steps,
one filled primary button per screen and text or outlined buttons for the rest.
