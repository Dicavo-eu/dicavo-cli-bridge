#!/bin/bash
#
# Build and package a signed Dicavo CLI Bridge.app from a git ref as a
# compressed read-only DMG.
#
# Two modes, deliberately separate:
#
#   local (default)   Apple Development identity from the unversioned
#                     Config/Signing.local.xcconfig. Runs on this machine;
#                     Gatekeeper on another Mac will refuse it.
#
#   --distribution    Developer ID Application identity from the login
#                     Keychain, Hardened Runtime and a secure timestamp, the
#                     DMG signed as well, then notarized by Apple and
#                     stapled. This mode never reads the local development
#                     signing config, and never writes the identity or any
#                     credential into the repository.
#
# The build happens in a detached worktree under /private/tmp, never in the
# working copy: it keeps local edits out of the artifact, and a checkout under
# a file-provider-synced directory such as ~/Documents carries extended
# attributes that make codesign fail with "resource fork, Finder information,
# or similar detritus not allowed".
#
# The DMG is moved into place only after every check has passed, so a failed
# run cannot leave a stale artifact behind that looks like a fresh one. In
# distribution mode that includes notarization and stapling: a DMG that was
# not accepted by Apple is never published.

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REF="origin/main"
CONFIGURATION="Release"
OUTPUT_DIR="$REPO/dist"
DISTRIBUTION=0
NOTARY_PROFILE=""
IDENTITY=""
# The Team ID the published bridge is signed with. The updater refuses any
# other (Sources/BridgeCore/BridgeUpdateInstaller.swift), so a distribution
# build with another identity is refused here before it costs a notarization.
EXPECTED_TEAM_ID="H8LTS9AT3K"
BUNDLE_ID="cz.smartbrains.dicavo.bridge"
APP_GROUP="H8LTS9AT3K.cz.smartbrains.dicavo"
FEED_URL="https://dicavo.eu/bridge/latest.json"
SKIP_PUBLISHED_CHECK=0

usage() {
    cat <<'USAGE'
usage: scripts/make-dmg.sh [options]

  --ref <git-ref>          commit to build (default: origin/main)
  --configuration <name>   Xcode configuration (default: Release)
  --output-dir <dir>       where the DMG is written (default: <repo>/dist)
  --distribution           Developer ID + Hardened Runtime + notarization
  --notary-profile <name>  notarytool keychain profile (required with
                           --distribution); create it once with
                           xcrun notarytool store-credentials <name>
  --identity <name>        signing identity to use instead of the
                           auto-detected Developer ID Application one
  --expected-team-id <id>  Team ID a distribution build must be signed with
                           (default: H8LTS9AT3K, the one the updater accepts)
  --skip-published-check   do not compare the build number with the one
                           published at https://dicavo.eu/bridge/latest.json
  -h, --help               this text

Local mode prints the path, version, commit, architectures, SHA-256 and the
signing status. Distribution mode additionally prints the notarization
submission ID and the Gatekeeper assessment. The script exits non-zero on the
first failed check.
USAGE
}

while [ $# -gt 0 ]; do
    case "$1" in
        --ref) REF="${2:?--ref needs a value}"; shift 2 ;;
        --configuration) CONFIGURATION="${2:?--configuration needs a value}"; shift 2 ;;
        --output-dir) OUTPUT_DIR="${2:?--output-dir needs a value}"; shift 2 ;;
        --distribution) DISTRIBUTION=1; shift ;;
        --notary-profile) NOTARY_PROFILE="${2:?--notary-profile needs a value}"; shift 2 ;;
        --identity) IDENTITY="${2:?--identity needs a value}"; shift 2 ;;
        --expected-team-id) EXPECTED_TEAM_ID="${2:?--expected-team-id needs a value}"; shift 2 ;;
        --skip-published-check) SKIP_PUBLISHED_CHECK=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "error: unknown argument: $1" >&2; usage >&2; exit 2 ;;
    esac
done

# Everything below names the product through these variables and never
# through a literal.
SCHEME="DicavoBridge"
APP_NAME="Dicavo CLI Bridge.app"
EXECUTABLE="Dicavo CLI Bridge"
DMG_PREFIX="DicavoCLIBridge"
VOLUME_PREFIX="Dicavo CLI Bridge"

step() { printf '\n==> %s\n' "$1"; }
ok()   { printf '    ok   %s\n' "$1"; }
fail() { printf '    FAIL %s\n' "$1" >&2; exit 1; }

WORKTREE=""
DERIVED=""
STAGING=""
MOUNTPOINT=""
CERTDIR=""
TMPDMG=""

cleanup() {
    local status=$?
    [ -n "$MOUNTPOINT" ] && mount | grep -q " ${MOUNTPOINT} " && hdiutil detach "$MOUNTPOINT" -quiet || true
    [ -n "$MOUNTPOINT" ] && rmdir "$MOUNTPOINT" 2>/dev/null || true
    [ -n "$CERTDIR" ] && rm -rf "$CERTDIR" || true
    [ -n "$STAGING" ] && rm -rf "$STAGING" || true
    [ -n "$TMPDMG" ] && rm -f "$TMPDMG" || true
    [ -n "$DERIVED" ] && rm -rf "$DERIVED" || true
    if [ -n "$WORKTREE" ] && [ -d "$WORKTREE" ]; then
        git -C "$REPO" worktree remove --force "$WORKTREE" >/dev/null 2>&1 || true
    fi
    exit $status
}
trap cleanup EXIT

# --- signing identity -------------------------------------------------------

FINGERPRINT=""
TEAM_ID=""

if [ "$DISTRIBUTION" -eq 1 ]; then
    step "Distribution identity"
    [ -n "$NOTARY_PROFILE" ] || fail "--distribution requires --notary-profile <name>; create it once with: xcrun notarytool store-credentials <name>"

    if [ -z "$IDENTITY" ]; then
        # The quoted friendly name, e.g. Developer ID Application: Acme (TEAMID).
        # Kept bash 3.2 compatible: macOS ships no bash 4.
        FOUND="$(security find-identity -v -p codesigning \
            | sed -nE 's/.*"(Developer ID Application: .*)".*/\1/p' | sort -u)"
        FOUND_COUNT="$(printf '%s' "$FOUND" | grep -c . || true)"
        [ "$FOUND_COUNT" -gt 0 ] \
            || fail "no Developer ID Application identity in the login Keychain; a distribution build cannot be signed with an Apple Development certificate"
        if [ "$FOUND_COUNT" -ne 1 ]; then
            printf '    several Developer ID Application identities found:\n%s\n' "$FOUND" >&2
            fail "pick one with --identity"
        fi
        IDENTITY="$FOUND"
    fi
    TEAM_ID="$(printf '%s' "$IDENTITY" | sed -nE 's/.*\(([A-Z0-9]+)\)$/\1/p')"
    [ -n "$TEAM_ID" ] || fail "cannot read the Team ID out of the identity name: $IDENTITY"
    ok "$IDENTITY"
    [ "$TEAM_ID" = "$EXPECTED_TEAM_ID" ] \
        || fail "the identity's Team ID $TEAM_ID is not $EXPECTED_TEAM_ID; the bridge's updater would refuse this build (pass --expected-team-id for a build of your own)"
    ok "Team ID $TEAM_ID"

    # A distribution build is always Release: Debug carries code, such as
    # printing the token on request, that a published bridge must not.
    [ "$CONFIGURATION" = "Release" ] || fail "--distribution builds the Release configuration only, not '$CONFIGURATION'"
    ok "configuration Release"

    # Fail before the build rather than after it, if the profile is unusable.
    if ! xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
        fail "the notarytool keychain profile '$NOTARY_PROFILE' is missing or unusable; create it with: xcrun notarytool store-credentials '$NOTARY_PROFILE' --apple-id <apple-id> --team-id $TEAM_ID --password <app-specific-password>"
    fi
    ok "notarytool profile '$NOTARY_PROFILE' answers"
else
    step "Local signing identity"
    LOCAL_CONFIG="$REPO/Config/Signing.local.xcconfig"
    [ -f "$LOCAL_CONFIG" ] || fail "Config/Signing.local.xcconfig is missing; initialize it from Config/Signing.local.xcconfig.example"

    # The fingerprint is a personal value: it is compared, never echoed.
    FINGERPRINT="$(grep -v '^[[:space:]]*//' "$LOCAL_CONFIG" \
        | grep -oE '[0-9A-Fa-f]{40}' | head -n 1 | tr '[:lower:]' '[:upper:]' || true)"
    [ -n "$FINGERPRINT" ] || fail "no 40-character certificate SHA-1 found in Config/Signing.local.xcconfig"

    if ! security find-identity -v -p codesigning | tr '[:lower:]' '[:upper:]' | grep -q "$FINGERPRINT"; then
        fail "the certificate configured in Config/Signing.local.xcconfig is not available to codesigning in this login session; unlock the login Keychain or install the identity, then retry"
    fi
    ok "configured certificate is available in the login Keychain"
fi

# --- commit -----------------------------------------------------------------

step "Commit"
COMMIT="$(git -C "$REPO" rev-parse "$REF^{commit}")" || fail "cannot resolve ref: $REF"
SHORT="$(git -C "$REPO" rev-parse --short=7 "$COMMIT")"
ok "$REF -> $COMMIT"

if [ "$DISTRIBUTION" -eq 1 ]; then
    # Every published DMG names a commit anyone can look up: it has to be
    # on a branch of the remote already, not only in this checkout.
    git -C "$REPO" fetch --quiet origin || fail "git fetch origin failed; a distribution build checks that the commit is pushed"
    [ -n "$(git -C "$REPO" branch -r --contains "$COMMIT" 2>/dev/null)" ] \
        || fail "commit $COMMIT is not on any branch of origin; push it before building a published DMG"
    ok "commit is on origin"
fi

# --- build ------------------------------------------------------------------

step "Signed build ($CONFIGURATION)"
WORKTREE="/private/tmp/Dicavo-dmg-$SHORT-$$"
DERIVED="/private/tmp/Dicavo-dmg-dd-$SHORT-$$"
git -C "$REPO" worktree add --detach "$WORKTREE" "$COMMIT" >/dev/null 2>&1 \
    || fail "could not create a worktree at $WORKTREE"
ok "worktree $WORKTREE"

BUILD_SETTINGS=(
    CODE_SIGNING_ALLOWED=YES
    CODE_SIGNING_REQUIRED=YES
    CODE_SIGN_STYLE=Manual
)
if [ "$DISTRIBUTION" -eq 1 ]; then
    # Passed on the command line so the distribution identity never touches a
    # file in the repository, and the local development config is not read.
    BUILD_SETTINGS+=(
        "CODE_SIGN_IDENTITY=$IDENTITY"
        "DEVELOPMENT_TEAM=$TEAM_ID"
        ENABLE_HARDENED_RUNTIME=YES
        "OTHER_CODE_SIGN_FLAGS=--timestamp"
        # Xcode injects com.apple.security.get-task-allow into every build
        # whose entitlements it prepares, including Release, and notarization
        # rejects an executable that asks to be debuggable. The entitlements
        # file does not mention it, which is what makes this hard to see: the
        # build adds it after reading that file.
        CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO
    )
else
    # Untracked by design, so a fresh worktree does not have it.
    cp "$LOCAL_CONFIG" "$WORKTREE/Config/Signing.local.xcconfig"
fi

# The log lives inside the derived data so a successful run leaves nothing
# behind; a failed one is copied out, because that is when it is needed.
mkdir -p "$DERIVED"
BUILD_LOG="$DERIVED/xcodebuild.log"
if ! ( cd "$WORKTREE" && xcodebuild \
        -project DicavoBridge.xcodeproj \
        -scheme "$SCHEME" \
        -configuration "$CONFIGURATION" \
        -derivedDataPath "$DERIVED" \
        "${BUILD_SETTINGS[@]}" \
        build >"$BUILD_LOG" 2>&1 ); then
    KEPT_LOG="/private/tmp/Dicavo-dmg-failed-$SHORT-$$.log"
    cp "$BUILD_LOG" "$KEPT_LOG" 2>/dev/null || true
    echo "    --- last 20 log lines ---" >&2
    tail -20 "$BUILD_LOG" >&2
    fail "the signed build failed; full log: $KEPT_LOG"
fi
APP="$DERIVED/Build/Products/$CONFIGURATION/$APP_NAME"
[ -d "$APP" ] || fail "no app bundle at $APP"
ok "built $APP"

# --- signature checks -------------------------------------------------------

verify_app() {
    local app="$1" label="$2"

    # --deep covers every nested component, not just the outer bundle.
    codesign --verify --deep --strict --verbose=4 "$app" >/dev/null 2>&1 \
        || fail "$label: codesign --verify --deep --strict failed"
    ok "$label: codesign --verify --deep --strict"

    local info authority team
    info="$(codesign -dv --verbose=4 "$app" 2>&1)"
    authority="$(printf '%s\n' "$info" | grep '^Authority=' | head -n 1)"
    team="$(printf '%s\n' "$info" | grep '^TeamIdentifier=' | head -n 1)"
    [ -n "$authority" ] && [ -n "$team" ] \
        || fail "$label: codesign did not report an Authority and a TeamIdentifier"
    ok "$label: $authority; $team"
    APP_AUTHORITY="$authority"
    APP_TEAM="$team"

    if [ "$DISTRIBUTION" -eq 1 ]; then
        printf '%s\n' "$authority" | grep -q "Developer ID Application" \
            || fail "$label: signed by '$authority' instead of a Developer ID Application identity"
        printf '%s\n' "$team" | grep -q "TeamIdentifier=$TEAM_ID" \
            || fail "$label: $team does not match the expected Team ID $TEAM_ID"
        printf '%s\n' "$info" | grep -q 'flags=.*runtime' \
            || fail "$label: the signature does not carry the Hardened Runtime flag"
        ok "$label: Hardened Runtime enabled"
        printf '%s\n' "$info" | grep -q '^Timestamp=' \
            || fail "$label: the signature has no secure timestamp"
        ok "$label: secure timestamp present"

        # Checked here rather than discovered by Apple. Notarization refuses a
        # debuggable executable, and finding that out costs an upload and a
        # wait; reading the entitlements costs nothing.
        if codesign -d --entitlements - --xml "$app" 2>/dev/null \
            | grep -q 'get-task-allow'; then
            fail "$label: the executable requests com.apple.security.get-task-allow, which notarization refuses"
        fi
        ok "$label: no debug entitlement"
    else
        CERTDIR="$(mktemp -d /private/tmp/Dicavo-dmg-cert.XXXXXX)"
        codesign -d "--extract-certificates=$CERTDIR/cert" "$app" >/dev/null 2>&1 \
            || fail "$label: no signing certificate could be extracted"
        local found
        found="$(openssl x509 -inform DER -in "$CERTDIR/cert0" -noout -fingerprint -sha1 \
            | tr -d ':' | grep -oE '[0-9A-Fa-f]{40}' | tr '[:lower:]' '[:upper:]')"
        rm -rf "$CERTDIR"; CERTDIR=""
        # Compared, never printed.
        [ "$found" = "$FINGERPRINT" ] \
            || fail "$label: the bundle was signed with a different certificate than the configured one"
        ok "$label: certificate SHA-1 matches the configured identity"
    fi
}

step "Signature of the built app"
verify_app "$APP" "built app"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
BUILD_NUMBER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist" 2>/dev/null || echo '-')"
ARCHS="$(lipo -archs "$APP/Contents/MacOS/$EXECUTABLE" 2>/dev/null || echo 'unknown')"
ok "version $VERSION (build $BUILD_NUMBER), architectures: $ARCHS"

FOUND_BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist" 2>/dev/null || true)"
[ "$FOUND_BUNDLE_ID" = "$BUNDLE_ID" ] || fail "bundle identifier is '$FOUND_BUNDLE_ID', not $BUNDLE_ID"
ok "bundle identifier $BUNDLE_ID"
codesign -d --entitlements - --xml "$APP" 2>/dev/null | grep -q "<string>$APP_GROUP</string>" \
    || fail "the signed entitlements do not carry the App Group $APP_GROUP"
ok "App Group $APP_GROUP in the signed entitlements"

if [ "$DISTRIBUTION" -eq 1 ] && [ "$SKIP_PUBLISHED_CHECK" -eq 0 ]; then
    # The updater installs only a higher build; a DMG that is not higher
    # than the published one would never reach anyone who updates.
    PUBLISHED_BUILD="$(curl -fsS --max-time 30 "$FEED_URL" \
        | /usr/bin/python3 -c 'import json, sys; print(int(json.load(sys.stdin)["build"]))')" \
        || fail "could not read the published build from $FEED_URL (use --skip-published-check to build anyway)"
    [ "$BUILD_NUMBER" -gt "$PUBLISHED_BUILD" ] 2>/dev/null \
        || fail "build $BUILD_NUMBER is not higher than the published build $PUBLISHED_BUILD; raise CURRENT_PROJECT_VERSION in Config/Version.xcconfig"
    ok "build $BUILD_NUMBER is higher than the published $PUBLISHED_BUILD"
fi

# --- staging and image ------------------------------------------------------

step "DMG"
STAGING="$(mktemp -d /private/tmp/Dicavo-dmg-stage.XXXXXX)"
# ditto preserves the bundle structure and its signature; nothing in the
# bundle is touched after signing.
ditto "$APP" "$STAGING/$APP_NAME"
ln -s /Applications "$STAGING/Applications"
ok "staging holds $APP_NAME and the Applications link only"

NAME="$DMG_PREFIX-$VERSION-$SHORT.dmg"
TMPDMG="/private/tmp/Dicavo-dmg-out-$SHORT-$$.dmg"
rm -f "$TMPDMG"
hdiutil create -quiet -format UDZO -volname "$VOLUME_PREFIX $VERSION" \
    -srcfolder "$STAGING" "$TMPDMG" || fail "hdiutil create failed"
ok "created $(basename "$TMPDMG") (UDZO)"

SUBMISSION_ID="-"
GATEKEEPER="not assessed (locally signed build)"

if [ "$DISTRIBUTION" -eq 1 ]; then
    step "Signing the image"
    codesign --force --sign "$IDENTITY" --timestamp "$TMPDMG" >/dev/null 2>&1 \
        || fail "could not sign the disk image"
    codesign --verify --strict --verbose=2 "$TMPDMG" >/dev/null 2>&1 \
        || fail "the signed disk image does not verify"
    ok "image signed with the Developer ID identity and verified"

    step "Notarization"
    NOTARY_OUT="$DERIVED/notarytool-submit.txt"
    if ! xcrun notarytool submit "$TMPDMG" \
            --keychain-profile "$NOTARY_PROFILE" --wait >"$NOTARY_OUT" 2>&1; then
        sed -E 's/[A-Za-z0-9_-]{20,}/<redacted>/g' "$NOTARY_OUT" | tail -20 >&2
        fail "notarytool submit failed"
    fi
    SUBMISSION_ID="$(grep -m1 -E '^[[:space:]]*id:' "$NOTARY_OUT" | awk '{print $2}')"
    STATUS="$(grep -E '^[[:space:]]*status:' "$NOTARY_OUT" | tail -1 | awk '{print $2}')"
    ok "submission $SUBMISSION_ID"
    if [ "$STATUS" != "Accepted" ]; then
        echo "    --- notarization log ---" >&2
        xcrun notarytool log "$SUBMISSION_ID" --keychain-profile "$NOTARY_PROFILE" >&2 2>&1 || true
        fail "notarization returned '$STATUS' instead of 'Accepted'; the log is above and the DMG was not published"
    fi
    ok "status Accepted"

    step "Stapling"
    xcrun stapler staple "$TMPDMG" >/dev/null 2>&1 || fail "stapler staple failed"
    xcrun stapler validate "$TMPDMG" >/dev/null 2>&1 || fail "stapler validate failed"
    ok "ticket stapled and validated"
fi

# --- verify the image -------------------------------------------------------

step "Verification of the image"
hdiutil verify "$TMPDMG" >/dev/null 2>&1 || fail "hdiutil verify failed"
ok "hdiutil verify"

if [ "$DISTRIBUTION" -eq 1 ]; then
    GK="$(spctl --assess --type open --context context:primary-signature --verbose=2 "$TMPDMG" 2>&1)" \
        || fail "Gatekeeper rejected the image: $GK"
    GATEKEEPER="$(printf '%s' "$GK" | tr '\n' ' ')"
    ok "spctl --assess --type open: accepted"
fi

MOUNTPOINT="$(mktemp -d /private/tmp/Dicavo-dmg-mount.XXXXXX)"
hdiutil attach "$TMPDMG" -readonly -nobrowse -mountpoint "$MOUNTPOINT" -quiet \
    || fail "could not attach the image"
ok "attached read-only at $MOUNTPOINT"

[ -d "$MOUNTPOINT/$APP_NAME" ] || fail "$APP_NAME is missing from the image"
LINK_TARGET="$(readlink "$MOUNTPOINT/Applications" || true)"
[ "$LINK_TARGET" = "/Applications" ] || fail "the Applications link points at '$LINK_TARGET' instead of /Applications"
ok "$APP_NAME and Applications -> /Applications are present"

verify_app "$MOUNTPOINT/$APP_NAME" "app on the mounted image"

if [ "$DISTRIBUTION" -eq 1 ]; then
    APP_GK="$(spctl --assess --type execute --verbose=2 "$MOUNTPOINT/$APP_NAME" 2>&1)" \
        || fail "Gatekeeper rejected the app on the image: $APP_GK"
    ok "app on the mounted image: Gatekeeper accepted"
    xcrun stapler validate "$MOUNTPOINT/$APP_NAME" >/dev/null 2>&1 \
        && ok "app on the mounted image: ticket validates" \
        || ok "app on the mounted image: ticket is on the image, not the bundle (expected)"
fi

hdiutil detach "$MOUNTPOINT" -quiet || fail "could not detach the image"
rmdir "$MOUNTPOINT" 2>/dev/null || true
MOUNTPOINT=""
ok "detached"

# --- publish ----------------------------------------------------------------

mkdir -p "$OUTPUT_DIR"
DEST="$OUTPUT_DIR/$NAME"
mv "$TMPDMG" "$DEST"
TMPDMG=""
# After stapling, so the hash covers exactly what is handed over.
SHA256="$(shasum -a 256 "$DEST" | awk '{print $1}')"
# Exact bytes: the manifest's `size` must match the file to the byte.
SIZE="$(stat -f %z "$DEST")"

printf '\n==> Result\n'
printf '    path           %s\n' "$DEST"
printf '    size           %s bytes\n' "$SIZE"
printf '    version        %s (build %s)\n' "$VERSION" "$BUILD_NUMBER"
printf '    commit         %s\n' "$COMMIT"
printf '    configuration  %s\n' "$CONFIGURATION"
printf '    architectures  %s\n' "$ARCHS"
printf '    sha256         %s\n' "$SHA256"
printf '    signature      %s; %s\n' "$APP_AUTHORITY" "$APP_TEAM"

if [ "$DISTRIBUTION" -eq 1 ]; then
    printf '    notarization   Accepted, ticket stapled\n'
    printf '    submission     %s\n' "$SUBMISSION_ID"
    printf '    gatekeeper     %s\n' "$GATEKEEPER"
else
    printf '    notarization   not notarized\n\n'
    printf '    This is a locally signed package. An Apple Development signature is not a\n'
    printf '    distribution signature: on another Mac Gatekeeper will refuse it. Run with\n'
    printf '    --distribution --notary-profile <name> to produce a notarized image.\n'
fi
