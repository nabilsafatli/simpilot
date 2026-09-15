#!/bin/bash
#
# Builds, signs, and optionally notarizes Simpilot for direct distribution.
#
# Notarization uploads the app to Apple, so it is opt-in: without --notarize the
# script builds and signs locally and changes nothing outside this machine.
#
#   ./scripts/release.sh                    build, sign, verify locally
#   ./scripts/release.sh --notarize         also submit to Apple, staple, package
#   ./scripts/release.sh --version 1.0.0    set the marketing version first
#
# Prerequisites for --notarize:
#   1. A "Developer ID Application" certificate in the login keychain.
#      Xcode > Settings > Accounts > Manage Certificates > + > Developer ID Application.
#      Requires a paid Apple Developer Program membership.
#   2. A stored notarytool credential profile named by NOTARY_PROFILE:
#      xcrun notarytool store-credentials "simpilot" \
#          --apple-id "<your-apple-id>" --team-id "$TEAM_ID" \
#          --password "<app-specific-password>"
#      App-specific passwords come from appleid.apple.com, not your account password.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT="$REPO_ROOT/Simpilot/Simpilot.xcodeproj"
SCHEME="Simpilot"
APP_NAME="Simpilot"
# Account-specific configuration. Sourced from release.env when present, which is
# untracked, so a fork can build without editing anything and the repository
# carries no values tied to one developer account.
#
# The Team ID is not a secret — it is embedded in every Developer ID signature
# and readable with `codesign -dv` on any release — but keeping it out of the
# repository means this script works unchanged for whoever clones it.
[[ -f "$REPO_ROOT/scripts/release.env" ]] && source "$REPO_ROOT/scripts/release.env"

TEAM_ID="${TEAM_ID:-}"
GITHUB_REPO="${GITHUB_REPO:-}"
NOTARY_PROFILE="${NOTARY_PROFILE:-simpilot}"

BUILD_DIR="$REPO_ROOT/build"
ARCHIVE="$BUILD_DIR/$APP_NAME.xcarchive"
EXPORT_DIR="$BUILD_DIR/export"
APP="$EXPORT_DIR/$APP_NAME.app"

NOTARIZE=false
VERSION=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --notarize) NOTARIZE=true; shift ;;
        --version) VERSION="$2"; shift 2 ;;
        -h|--help) sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "Unknown option: $1" >&2; exit 2 ;;
    esac
done

step() { printf '\n\033[1m==> %s\033[0m\n' "$1"; }
fail() { printf '\033[31mError: %s\033[0m\n' "$1" >&2; exit 1; }

# ---------------------------------------------------------------- preflight

step "Checking prerequisites"

command -v xcodebuild >/dev/null || fail "xcodebuild not found. Install Xcode."

if [[ -z "$TEAM_ID" ]]; then
    fail "TEAM_ID is not set.

  Copy scripts/release.env.example to scripts/release.env and fill it in, or
  export TEAM_ID in the environment. Find yours with:
    security find-identity -v -p codesigning | grep 'Developer ID Application'
  The ten-character code in parentheses is the Team ID."
fi

if [[ -z "$GITHUB_REPO" ]]; then
    fail "GITHUB_REPO is not set (expected owner/name).

  The appcast's download links point at that repository's releases.
  Set it in scripts/release.env."
fi
echo "  Team: $TEAM_ID   Repo: $GITHUB_REPO"

# A Developer ID Application certificate is what makes the app runnable on
# another Mac without Gatekeeper blocking it. An "Apple Development" certificate
# is not a substitute: it only authorises running on registered devices.
#
# This is a warning rather than a gate. Under automatic signing, Xcode fetches or
# creates the certificate during export — so a hard check here would refuse to
# run the very step that obtains it, on exactly the fresh machine where that
# matters most. If it genuinely cannot be obtained, the export fails below with
# the full explanation.
if security find-identity -v -p codesigning | grep -q "Developer ID Application"; then
    SIGNING_IDENTITY=$(security find-identity -v -p codesigning \
        | grep "Developer ID Application" | head -1 \
        | sed -E 's/.*"(.*)"/\1/')
    echo "  Signing identity: $SIGNING_IDENTITY"
else
    SIGNING_IDENTITY=""
    echo "  No Developer ID certificate in the keychain yet."
    echo "  Automatic signing will try to obtain one during export."
fi

if [[ "$NOTARIZE" == true ]]; then
    if ! xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
        fail "No notarytool credential profile named '$NOTARY_PROFILE'.

  Create one with:
    xcrun notarytool store-credentials \"$NOTARY_PROFILE\" \\
        --apple-id \"<your-apple-id>\" \\
        --team-id \"$TEAM_ID\" \\
        --password \"<app-specific-password>\"

  The password is an app-specific password from appleid.apple.com,
  never your Apple ID password."
    fi
    echo "  Notary profile:   $NOTARY_PROFILE"
fi

# ---------------------------------------------------------------- tests

step "Running tests"
# Shipping an unverified build is not worth the minutes saved.
( cd "$REPO_ROOT" && swift test ) || fail "Tests failed. Not building a release."

# ---------------------------------------------------------------- version

PBXPROJ="$REPO_ROOT/Simpilot/Simpilot.xcodeproj/project.pbxproj"

if [[ -n "$VERSION" ]]; then
    step "Setting version to $VERSION"
    # agvtool is the wrong tool here and fails silently. With
    # GENERATE_INFOPLIST_FILE the version lives in MARKETING_VERSION rather than
    # in a plist, so agvtool writes CFBundleShortVersionString into the Info.plist
    # that exists only to carry Sparkle's keys, misreads GENERATE_INFOPLIST_FILE=YES
    # as a path, and still exits 0. Edit the build setting directly instead.
    sed -i '' -E "s/MARKETING_VERSION = [^;]+;/MARKETING_VERSION = $VERSION;/g" "$PBXPROJ"
fi

# Sparkle decides whether a release is newer by comparing sparkle:version, which
# generate_appcast takes from CURRENT_PROJECT_VERSION. A release that leaves it
# unchanged is invisible to everyone who already has the app — the update exists,
# is signed, is served, and is silently never offered. So bump it every time.
CURRENT_BUILD=$(awk -F' = ' '/CURRENT_PROJECT_VERSION = /{gsub(/;/,"",$2); print $2; exit}' "$PBXPROJ")
NEXT_BUILD=$(( CURRENT_BUILD + 1 ))
sed -i '' -E "s/CURRENT_PROJECT_VERSION = [^;]+;/CURRENT_PROJECT_VERSION = $NEXT_BUILD;/g" "$PBXPROJ"

MARKETING_VERSION=$(xcodebuild -project "$PROJECT" -scheme "$SCHEME" \
    -showBuildSettings 2>/dev/null | awk -F' = ' '/MARKETING_VERSION/{print $2; exit}')

# Never ship a version the caller did not ask for. Silently building 0.1 when
# 0.2 was requested produced an appcast pointing at a release that did not exist.
if [[ -n "$VERSION" && "$MARKETING_VERSION" != "$VERSION" ]]; then
    fail "Version was not applied: asked for $VERSION, project reports $MARKETING_VERSION."
fi

echo "  Version: $MARKETING_VERSION (build $NEXT_BUILD)"

# ---------------------------------------------------------------- archive

step "Archiving"
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

xcodebuild archive \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration Release \
    -archivePath "$ARCHIVE" \
    -destination "generic/platform=macOS" \
    CODE_SIGN_STYLE=Automatic \
    DEVELOPMENT_TEAM="$TEAM_ID" \
    | grep -E "error:|warning:|Archive succeeded" || true

[[ -d "$ARCHIVE" ]] || fail "Archive failed."

step "Exporting signed app"
# Written here rather than committed: it would otherwise be a file whose only
# content is one developer's Team ID.
EXPORT_PLIST="$BUILD_DIR/ExportOptions.plist"
cat > "$EXPORT_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key><string>developer-id</string>
    <key>teamID</key><string>$TEAM_ID</string>
    <key>signingStyle</key><string>automatic</string>
    <key>destination</key><string>export</string>
</dict>
</plist>
PLIST

xcodebuild -exportArchive \
    -archivePath "$ARCHIVE" \
    -exportPath "$EXPORT_DIR" \
    -exportOptionsPlist "$EXPORT_PLIST" \
    | grep -E "error:|Export succeeded" || true

[[ -d "$APP" ]] || fail "Export failed; no app at $APP

  If the log mentions signing, no 'Developer ID Application' certificate could
  be obtained for team $TEAM_ID. Create one in
  Xcode > Settings > Accounts > Manage Certificates > + , or at
  developer.apple.com/account/resources/certificates. This requires a paid
  Apple Developer Program membership; the free tier issues only
  'Apple Development' certificates, which cannot sign for distribution
  outside the App Store."

# ---------------------------------------------------------------- verify

step "Verifying signature"
codesign --verify --deep --strict --verbose=2 "$APP" 2>&1 | sed 's/^/  /'

# The hardened runtime is mandatory for notarization, and the App Sandbox must
# stay off or the app cannot reach simctl at all.
if ! codesign -d --entitlements - "$APP" 2>/dev/null | grep -q "runtime"; then
    echo "  Note: checking hardened runtime via flags instead"
fi
codesign -d -vvv "$APP" 2>&1 | grep -E "^Identifier|^Authority|^TeamIdentifier|flags" | sed 's/^/  /'

if codesign -d --entitlements - "$APP" 2>/dev/null | grep -q "app-sandbox"; then
    fail "The App Sandbox is enabled. Simpilot cannot spawn xcrun or read
  ~/Library/Developer/CoreSimulator under the sandbox, and would ship
  showing an empty inventory with no visible error."
fi
echo "  App Sandbox: disabled (required)"

if [[ "$NOTARIZE" != true ]]; then
    step "Done (local build only)"
    echo "  App: $APP"
    echo
    echo "  Not notarized. Another Mac will refuse to open this build."
    echo "  Re-run with --notarize to submit it to Apple."
    exit 0
fi

# ---------------------------------------------------------------- notarize

step "Submitting app to Apple for notarization"
echo "  This uploads the app to Apple's notary service and may take a few minutes."

ZIP="$BUILD_DIR/$APP_NAME.zip"
ditto -c -k --keepParent "$APP" "$ZIP"

xcrun notarytool submit "$ZIP" \
    --keychain-profile "$NOTARY_PROFILE" \
    --wait \
    | sed 's/^/  /'

step "Stapling the ticket to the app"
xcrun stapler staple "$APP" | sed 's/^/  /'
xcrun stapler validate "$APP" | sed 's/^/  /'

# ---------------------------------------------------------------- package

step "Building DMG"
DMG="$BUILD_DIR/$APP_NAME-$MARKETING_VERSION.dmg"
STAGE="$BUILD_DIR/dmg-stage"
rm -rf "$STAGE"; mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

hdiutil create -volname "$APP_NAME" -srcfolder "$STAGE" -ov -format UDZO "$DMG" \
    | sed 's/^/  /'

step "Signing and notarizing the DMG"
if [[ -z "$SIGNING_IDENTITY" ]]; then
    # Resolve it now: export will have installed the certificate.
    SIGNING_IDENTITY=$(security find-identity -v -p codesigning \
        | grep "Developer ID Application" | head -1 \
        | sed -E 's/.*"(.*)"/\1/')
    [[ -n "$SIGNING_IDENTITY" ]] || fail "No Developer ID identity available to sign the DMG."
fi
# The app inside is already stapled; notarizing the DMG as well means the
# download itself passes Gatekeeper without a network round trip.
codesign --sign "$SIGNING_IDENTITY" --timestamp "$DMG"

xcrun notarytool submit "$DMG" \
    --keychain-profile "$NOTARY_PROFILE" \
    --wait \
    | sed 's/^/  /'

xcrun stapler staple "$DMG" | sed 's/^/  /'

# ---------------------------------------------------------------- appcast

step "Updating the appcast"

# Sparkle ships its tools as SPM build artifacts, whose location depends on the
# derived data path, so resolve it from the build settings rather than guessing.
BUILD_PRODUCTS=$(xcodebuild -project "$PROJECT" -scheme "$SCHEME" \
    -showBuildSettings 2>/dev/null | awk -F' = ' '/ BUILD_DIR =/{print $2; exit}')
SPARKLE_BIN="$(dirname "$(dirname "$BUILD_PRODUCTS")")/SourcePackages/artifacts/sparkle/Sparkle/bin"

if [[ ! -x "$SPARKLE_BIN/generate_appcast" ]]; then
    fail "Sparkle's generate_appcast not found at:
  $SPARKLE_BIN
  Build the app once in Xcode so SwiftPM resolves the Sparkle artifacts."
fi

# generate_appcast reads every update in a directory and signs each with the
# private EdDSA key from the login keychain. Carrying the previous appcast in
# alongside lets it preserve entries whose DMGs are no longer on this machine.
APPCAST_DIR="$BUILD_DIR/appcast"
rm -rf "$APPCAST_DIR"; mkdir -p "$APPCAST_DIR"
cp "$DMG" "$APPCAST_DIR/"
[[ -f "$REPO_ROOT/appcast.xml" ]] && cp "$REPO_ROOT/appcast.xml" "$APPCAST_DIR/"

# Downloads live on the GitHub release for this tag, which is why the tag name
# and the marketing version have to agree.
"$SPARKLE_BIN/generate_appcast" \
    --download-url-prefix "https://github.com/$GITHUB_REPO/releases/download/v$MARKETING_VERSION/" \
    "$APPCAST_DIR" | sed 's/^/  /'

[[ -f "$APPCAST_DIR/appcast.xml" ]] || fail "generate_appcast produced no appcast.xml"
cp "$APPCAST_DIR/appcast.xml" "$REPO_ROOT/appcast.xml"
echo "  Written to $REPO_ROOT/appcast.xml"

# ---------------------------------------------------------------- final check

step "Verifying Gatekeeper acceptance"
# What another Mac will actually decide when the app is opened.
spctl --assess --type execute --verbose=4 "$APP" 2>&1 | sed 's/^/  /'

step "Release ready"
echo "  App:     $APP"
echo "  DMG:     $DMG"
echo "  Appcast: $REPO_ROOT/appcast.xml"
echo
echo "  Publishing is two manual steps, because the appcast must not advertise a"
echo "  download before that download exists:"
echo
echo "    1. Create the GitHub release and attach the DMG:"
echo "         https://github.com/$GITHUB_REPO/releases/new?tag=v$MARKETING_VERSION"
echo "       The tag must be v$MARKETING_VERSION exactly; the appcast points there."
echo
echo "    2. Only then commit and push the appcast:"
echo "         git add appcast.xml && git commit -m \"Release $MARKETING_VERSION\" && git push"
echo
echo "  Verify on a machine that has never run this app:"
echo "    spctl --assess --type execute --verbose=4 /Applications/$APP_NAME.app"
