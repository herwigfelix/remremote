#!/bin/sh
# compile.sh — build (and optionally sign, notarize, package) the remremote macOS app.
#
#   ./compile.sh            build a Release remremote.app (Developer ID, Hardened Runtime)
#   ./compile.sh --dmg      also produce a remremote-<version>.dmg
#   ./compile.sh --release  notarize the app at Apple and staple the ticket (implies --dmg,
#                           which is then notarized too)
#
# Normal `xcodebuild` builds are already signed with the stable Developer ID identity from
# project.yml, so the app keeps its TCC permissions across rebuilds. --release adds
# notarization for distribution and reads the App Store Connect credentials from
# compile.sh.dat (template: compile.sh.dat.example). Requires xcodegen + Xcode.
set -e

ROOT=$(cd "$(dirname "$0")" && pwd)
cd "$ROOT"

VERSION=$(sed -n 's/^ *MARKETING_VERSION: *\(.*\)/\1/p' project.yml | head -1 | tr -d ' "')
[ -n "$VERSION" ] || VERSION="dev"

DMG=0
RELEASE=0
for a in "$@"; do
	case "$a" in
		--dmg) DMG=1 ;;
		--release) RELEASE=1; DMG=1 ;;
		*) echo "Unknown argument: $a"; exit 1 ;;
	esac
done

DAT="$ROOT/compile.sh.dat"
if [ "$RELEASE" = 1 ]; then
	[ -f "$DAT" ] || { echo "ERROR: $DAT missing. cp compile.sh.dat.example compile.sh.dat && chmod 600 compile.sh.dat"; exit 1; }
	# shellcheck disable=SC1090
	. "$DAT"
	for v in SIGN_IDENTITY API_KEY_P8 API_KEY_ID API_ISSUER_ID; do
		eval "val=\$$v"
		[ -n "$val" ] || { echo "ERROR: $v missing in compile.sh.dat"; exit 1; }
	done
	case "$API_KEY_P8" in /*) ;; *) API_KEY_P8="$ROOT/$API_KEY_P8" ;; esac
	[ -f "$API_KEY_P8" ] || { echo "ERROR: API key not found: $API_KEY_P8"; exit 1; }
fi

echo "== remremote $VERSION for macOS (universal) =="
command -v xcodegen >/dev/null 2>&1 && xcodegen generate >/dev/null
# 'generic/platform=macOS' avoids the "multiple matching destinations" ambiguity and
# builds a universal (arm64 + x86_64) binary rather than just the host architecture.
xcodebuild -project remremote.xcodeproj -scheme RemRemote -configuration Release \
	-destination 'generic/platform=macOS' \
	-derivedDataPath build \
	ONLY_ACTIVE_ARCH=NO ARCHS="arm64 x86_64" build >/dev/null

APP="$ROOT/build/Build/Products/Release/remremote.app"
[ -d "$APP" ] || { echo "remremote.app was not produced"; exit 1; }
# The Release build is already Developer-ID + Hardened Runtime signed by Xcode; add a
# secure timestamp for notarization if we are releasing.
if [ "$RELEASE" = 1 ]; then
	echo "== re-sign with secure timestamp =="
	codesign --force --options runtime --timestamp \
		--entitlements "$ROOT/RemRemote/remremote.entitlements" \
		--sign "$SIGN_IDENTITY" "$APP"
	codesign --verify --strict --verbose=2 "$APP"

	echo "== notarize the app (takes a few minutes) =="
	APPZIP="$ROOT/remremote-$VERSION-app.zip"
	rm -f "$APPZIP"
	ditto -c -k --keepParent "$APP" "$APPZIP"
	xcrun notarytool submit "$APPZIP" --key "$API_KEY_P8" --key-id "$API_KEY_ID" --issuer "$API_ISSUER_ID" --wait
	xcrun stapler staple "$APP"
	xcrun stapler validate "$APP"
	rm -f "$APPZIP"
	echo "App notarized and stapled."
fi

# Copy the finished app to a stable location (build/ is wiped on every build).
DIST="$ROOT/dist"
rm -rf "$DIST"
mkdir -p "$DIST"
cp -R "$APP" "$DIST/"
echo "App copied to $DIST/remremote.app"

if [ "$DMG" = 1 ]; then
	DMGFILE="$ROOT/remremote-$VERSION.dmg"
	rm -f "$DMGFILE"
	echo "== build DMG =="
	STAGE=$(mktemp -d)
	cp -R "$APP" "$STAGE/"
	ln -s /Applications "$STAGE/Applications" 2>/dev/null || true
	hdiutil create -volname "remremote $VERSION" -srcfolder "$STAGE" -ov -format UDZO "$DMGFILE"
	rm -rf "$STAGE"
	if [ "$RELEASE" = 1 ]; then
		echo "== sign + notarize DMG =="
		codesign --force --timestamp --sign "$SIGN_IDENTITY" "$DMGFILE"
		xcrun notarytool submit "$DMGFILE" --key "$API_KEY_P8" --key-id "$API_KEY_ID" --issuer "$API_ISSUER_ID" --wait
		xcrun stapler staple "$DMGFILE"
		spctl -a -vvv -t install "$DMGFILE" || true
	fi
	echo "Done: $DMGFILE"
else
	echo "Done: $APP  (--dmg for a disk image, --release to notarize)"
fi
