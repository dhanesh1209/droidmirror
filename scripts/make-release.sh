#!/bin/bash
# Builds the downloadable release files into release/:
#   DroidMirror-<version>.pkg   Mac installer (puts DroidMirror.app in /Applications)
#   DroidMirror-<version>.apk   Android companion, signed with your release key
#   SHA256SUMS                  checksums so people can verify the downloads
#
# The Mac app is ad-hoc signed and NOT notarized: macOS shows an "unidentified developer" warning on the
# first open of a downloaded copy. Notarizing needs an Apple Developer ID (99 USD a year).
#
# The Android release key lives OUTSIDE the repo. Set DROIDMIRROR_SIGNING to its signing.properties file
# (default: ~/Documents/DroidMirror-signing/signing.properties). Keep a backup of that folder: without
# the same key, phones cannot update an installed DroidMirror, only reinstall it.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="$(sed -n 's/.*versionName = "\(.*\)".*/\1/p' android/app/build.gradle.kts)"
export DROIDMIRROR_SIGNING="${DROIDMIRROR_SIGNING:-$HOME/Documents/DroidMirror-signing/signing.properties}"
[ -f "$DROIDMIRROR_SIGNING" ] || { echo "Missing signing file: $DROIDMIRROR_SIGNING" >&2; exit 1; }

OUT="release"
rm -rf "$OUT"; mkdir -p "$OUT"

echo "== Mac app"
./scripts/make-app.sh >/dev/null
# Not relocatable: otherwise macOS may "update" another copy of the app it finds elsewhere (for example
# a development build) instead of installing to /Applications.
STAGE="$(mktemp -d)"
mkdir -p "$STAGE/root"
cp -R build/DroidMirror.app "$STAGE/root/"
pkgbuild --analyze --root "$STAGE/root" "$STAGE/components.plist" >/dev/null
plutil -replace 0.BundleIsRelocatable -bool NO "$STAGE/components.plist"
pkgbuild --root "$STAGE/root" \
         --component-plist "$STAGE/components.plist" \
         --install-location /Applications \
         --identifier dev.droidmirror.mac.pkg \
         --version "$VERSION" \
         "$OUT/DroidMirror-$VERSION.pkg" >/dev/null
rm -rf "$STAGE"

echo "== Android app"
(cd android && ./gradlew --no-daemon -q :app:assembleRelease)
cp android/app/build/outputs/apk/release/app-release.apk "$OUT/DroidMirror-$VERSION.apk"

echo "== Automation package"
(cd automation && npm run build >/dev/null && npm pack --pack-destination "../$OUT" --silent >/dev/null)
mv "$OUT/droidmirror-automation-"*.tgz "$OUT/droidmirror-automation-$VERSION.tgz" 2>/dev/null || true

# Verify the APK is signed with the release key, not left unsigned or debug-signed.
BT="$(ls -d "${ANDROID_HOME:-$HOME/Library/Android/sdk}"/build-tools/* | sort -V | tail -1)"
"$BT/apksigner" verify --print-certs "$OUT/DroidMirror-$VERSION.apk" | grep -E "Signer #1 certificate (DN|SHA-256)"

(cd "$OUT" && shasum -a 256 DroidMirror-* droidmirror-automation-* > SHA256SUMS && cat SHA256SUMS)
echo "Built $OUT/"
