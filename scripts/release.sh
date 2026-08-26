#!/usr/bin/env bash

set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PROJECT_PATH="$REPO_ROOT/VoiceInk.xcodeproj"
SCHEME="VoiceInk"
FORK_RELEASE_CONFIG="$REPO_ROOT/ForkRelease.xcconfig"
ENTITLEMENTS="$REPO_ROOT/VoiceInk/VoiceInk.local.entitlements"
KEYCHAIN="${VOICEINK_KEYCHAIN:-$HOME/Library/Keychains/login.keychain-db}"
SIGNING_IDENTITY="${VOICEINK_SIGNING_IDENTITY:-Apple Development: ANDREY SHRAYEV (87R47LZ5EP)}"
SPARKLE_ACCOUNT="${VOICEINK_SPARKLE_ACCOUNT:-VoiceInk ADS}"
REPOSITORY="${VOICEINK_GITHUB_REPOSITORY:-Diaspar4u/VoiceInk}"
FEED_BRANCH="${VOICEINK_FEED_BRANCH:-andrey/all-fixes}"
FEED_URL="https://raw.githubusercontent.com/$REPOSITORY/$FEED_BRANCH/appcast.xml"
RELEASE_BASE_URL="https://github.com/$REPOSITORY/releases/download"
EXPECTED_BUNDLE_ID="com.prakashjoshipax.VoiceInk"
EXPECTED_SHORT_VERSION="2.11.1-ads.8"
EXPECTED_MINIMUM_SYSTEM_VERSION="26.0"
BUILD_VERSION=""
NOTES_PATH=""
OUTPUT_DIR=""
APPCAST_OUTPUT="$REPO_ROOT/appcast.xml"
PUBLISH=0
ALLOW_DIRTY=0
PRE_METADATA_HEAD=""
PUBLISHED_METADATA_HEAD=""

rollback_published_metadata() {
    [[ -n "$PRE_METADATA_HEAD" && -n "$PUBLISHED_METADATA_HEAD" ]] || return 0
    git -C "$REPO_ROOT" push \
        "--force-with-lease=refs/heads/$FEED_BRANCH:$PUBLISHED_METADATA_HEAD" \
        origin "$PRE_METADATA_HEAD:refs/heads/$FEED_BRANCH"
    git -C "$REPO_ROOT" reset --hard "$PRE_METADATA_HEAD" >/dev/null
    PUBLISHED_METADATA_HEAD=""
}

on_exit() {
    local status=$?
    trap - EXIT
    if [[ "$status" != '0' && -n "$PUBLISHED_METADATA_HEAD" ]]; then
        rollback_published_metadata || status=1
    fi
    exit "$status"
}
trap on_exit EXIT

usage() {
    printf '%s\n' \
        'Usage: scripts/release.sh --build-number <integer> [options]' \
        '' \
        'Builds, Apple-signs, verifies, packages, Sparkle-signs, and stages VoiceInk.' \
        'With --publish, it uploads the immutable GitHub Release asset, verifies it,' \
        'publishes appcast.xml last, and verifies the public update channel.' \
        '' \
        'Options:' \
        '  --build-number <integer>  Monotonically increasing CFBundleVersion.' \
        "  --notes <file>            Release notes (default: release-notes/$EXPECTED_SHORT_VERSION.html)." \
        '  --output-dir <directory>  Artifact directory.' \
        '  --appcast-output <file>   Candidate feed destination (default: ./appcast.xml).' \
        '  --publish                 Publish release asset and feed; requires maintained branch.' \
        '  --allow-dirty             Permit source changes for a prepare-only build.' \
        '  -h, --help                Show this help.'
}

log() { printf '\n==> %s\n' "$1"; }
fail() { printf 'error: %s\n' "$1" >&2; exit 1; }
require_command() { command -v "$1" >/dev/null 2>&1 || fail "Required command not found: $1"; }
read_plist_value() { plutil -extract "$2" raw "$1"; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --build-number)
            [[ $# -ge 2 ]] || fail '--build-number requires a value'
            BUILD_VERSION="$2"
            shift 2
            ;;
        --notes)
            [[ $# -ge 2 ]] || fail '--notes requires a path'
            NOTES_PATH="$2"
            shift 2
            ;;
        --output-dir)
            [[ $# -ge 2 ]] || fail '--output-dir requires a path'
            OUTPUT_DIR="$2"
            shift 2
            ;;
        --appcast-output)
            [[ $# -ge 2 ]] || fail '--appcast-output requires a path'
            APPCAST_OUTPUT="$2"
            shift 2
            ;;
        --publish)
            PUBLISH=1
            shift
            ;;
        --allow-dirty)
            ALLOW_DIRTY=1
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *) fail "Unknown argument: $1" ;;
    esac
done

[[ "$BUILD_VERSION" =~ ^[0-9]+$ ]] || fail '--build-number must be an integer'
[[ -f "$FORK_RELEASE_CONFIG" ]] || fail "Missing $FORK_RELEASE_CONFIG"
[[ -f "$ENTITLEMENTS" ]] || fail "Missing $ENTITLEMENTS"
[[ -f "$KEYCHAIN" ]] || fail "Missing signing Keychain: $KEYCHAIN"

if [[ -z "$NOTES_PATH" ]]; then
    NOTES_PATH="$REPO_ROOT/release-notes/$EXPECTED_SHORT_VERSION.html"
elif [[ "$NOTES_PATH" != /* ]]; then
    NOTES_PATH="$REPO_ROOT/$NOTES_PATH"
fi
[[ -f "$NOTES_PATH" ]] || fail "Release notes not found: $NOTES_PATH"

if [[ -z "$OUTPUT_DIR" ]]; then
    OUTPUT_DIR="$REPO_ROOT/.fork-build/releases/$BUILD_VERSION"
elif [[ "$OUTPUT_DIR" != /* ]]; then
    OUTPUT_DIR="$REPO_ROOT/$OUTPUT_DIR"
fi
[[ ! -e "$OUTPUT_DIR" ]] || fail "Output already exists: $OUTPUT_DIR"

for command_name in codesign curl ditto gh-diaspar git plutil security shasum stat xcodebuild xmllint; do
    require_command "$command_name"
done

if [[ "$ALLOW_DIRTY" == '0' && -n "$(git -C "$REPO_ROOT" status --porcelain)" ]]; then
    fail 'Git working tree is not clean. Commit/stash changes or pass --allow-dirty for a prepare-only build.'
fi
if [[ "$PUBLISH" == '1' ]]; then
    [[ "$ALLOW_DIRTY" == '0' ]] || fail '--publish cannot be combined with --allow-dirty'
    git -C "$REPO_ROOT" fetch origin "$FEED_BRANCH"
    git -C "$REPO_ROOT" merge-base --is-ancestor "origin/$FEED_BRANCH" HEAD \
        || fail "Release commit is not a descendant of origin/$FEED_BRANCH"
    [[ "$(gh-diaspar api user --jq .login)" == 'Diaspar4u' ]] || fail 'GitHub release owner is not Diaspar4u'
fi

IDENTITY_SHA="$(security find-identity -v -p codesigning "$KEYCHAIN" | awk -v identity="$SIGNING_IDENTITY" 'index($0, identity) {print $2; exit}')"
[[ -n "$IDENTITY_SHA" ]] || fail "Signing identity unavailable in $KEYCHAIN: $SIGNING_IDENTITY"

SPARKLE_BIN_DIR="${SPARKLE_BIN_DIR:-$REPO_ROOT/.fork-build/release-packages/artifacts/sparkle/Sparkle/bin}"
GENERATE_APPCAST="$SPARKLE_BIN_DIR/generate_appcast"
GENERATE_KEYS="$SPARKLE_BIN_DIR/generate_keys"
SIGN_UPDATE="$SPARKLE_BIN_DIR/sign_update"
[[ -x "$GENERATE_APPCAST" && -x "$GENERATE_KEYS" && -x "$SIGN_UPDATE" ]] \
    || fail 'Sparkle tools are unavailable. Resolve Swift packages into .fork-build/release-packages first.'

mkdir -p "$OUTPUT_DIR"
DERIVED_DATA="$OUTPUT_DIR/DerivedData"
APP_PATH="$OUTPUT_DIR/VoiceInk.app"
ARCHIVE_NAME="VoiceInk-$EXPECTED_SHORT_VERSION-b$BUILD_VERSION.zip"
ARCHIVE_PATH="$OUTPUT_DIR/$ARCHIVE_NAME"
APPCAST_WORK_DIR="$OUTPUT_DIR/appcast-work"
GENERATED_APPCAST="$APPCAST_WORK_DIR/appcast.xml"
RELEASE_TAG="v$EXPECTED_SHORT_VERSION"
DOWNLOAD_URL="$RELEASE_BASE_URL/$RELEASE_TAG/$ARCHIVE_NAME"

log "Building VoiceInk $EXPECTED_SHORT_VERSION ($BUILD_VERSION)"
xcodebuild \
    -project "$PROJECT_PATH" \
    -scheme "$SCHEME" \
    -configuration Release \
    -xcconfig "$FORK_RELEASE_CONFIG" \
    -derivedDataPath "$DERIVED_DATA" \
    -skipPackagePluginValidation \
    -skipMacroValidation \
    CODE_SIGNING_ALLOWED=NO \
    CURRENT_PROJECT_VERSION="$BUILD_VERSION" \
    build

BUILT_APP="$DERIVED_DATA/Build/Products/Release/VoiceInk.app"
[[ -d "$BUILT_APP" ]] || fail "Built app not found: $BUILT_APP"
ditto "$BUILT_APP" "$APP_PATH"
xattr -cr "$APP_PATH"

log 'Apple-signing application and nested code'
codesign --force --deep --options runtime --timestamp=none \
    --entitlements "$ENTITLEMENTS" --sign "$IDENTITY_SHA" "$APP_PATH"
codesign --verify --deep --strict --verbose=2 "$APP_PATH"

INFO_PLIST="$APP_PATH/Contents/Info.plist"
SHORT_VERSION="$(read_plist_value "$INFO_PLIST" CFBundleShortVersionString)"
ACTUAL_BUILD_VERSION="$(read_plist_value "$INFO_PLIST" CFBundleVersion)"
BUNDLE_ID="$(read_plist_value "$INFO_PLIST" CFBundleIdentifier)"
MINIMUM_SYSTEM_VERSION="$(read_plist_value "$INFO_PLIST" LSMinimumSystemVersion)"
ACTUAL_FEED_URL="$(read_plist_value "$INFO_PLIST" SUFeedURL)"
APP_PUBLIC_KEY="$(read_plist_value "$INFO_PLIST" SUPublicEDKey)"
REQUIRE_SIGNED_FEED="$(read_plist_value "$INFO_PLIST" SURequireSignedFeed)"
VERIFY_BEFORE_EXTRACTION="$(read_plist_value "$INFO_PLIST" SUVerifyUpdateBeforeExtraction)"

[[ "$SHORT_VERSION" == "$EXPECTED_SHORT_VERSION" ]] || fail "Unexpected short version: $SHORT_VERSION"
[[ "$ACTUAL_BUILD_VERSION" == "$BUILD_VERSION" ]] || fail "Unexpected build version: $ACTUAL_BUILD_VERSION"
[[ "$BUNDLE_ID" == "$EXPECTED_BUNDLE_ID" ]] || fail "Unexpected bundle identifier: $BUNDLE_ID"
[[ "$MINIMUM_SYSTEM_VERSION" == "$EXPECTED_MINIMUM_SYSTEM_VERSION" ]] || fail "Unexpected minimum macOS: $MINIMUM_SYSTEM_VERSION"
[[ "$ACTUAL_FEED_URL" == "$FEED_URL" ]] || fail "Unexpected feed URL: $ACTUAL_FEED_URL"
[[ "$REQUIRE_SIGNED_FEED" == 'true' ]] || fail 'SURequireSignedFeed is not true'
[[ "$VERIFY_BEFORE_EXTRACTION" == 'true' ]] || fail 'SUVerifyUpdateBeforeExtraction is not true'
KEYCHAIN_PUBLIC_KEY="$("$GENERATE_KEYS" --account "$SPARKLE_ACCOUNT" -p)"
[[ "$KEYCHAIN_PUBLIC_KEY" == "$APP_PUBLIC_KEY" ]] || fail 'Embedded Sparkle public key does not match the Keychain key'

log 'Packaging symlink-preserving Sparkle archive'
ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$ARCHIVE_PATH"
[[ -s "$ARCHIVE_PATH" ]] || fail 'Release archive is empty'

mkdir -p "$APPCAST_WORK_DIR"
ditto "$ARCHIVE_PATH" "$APPCAST_WORK_DIR/$ARCHIVE_NAME"
cp "$NOTES_PATH" "$APPCAST_WORK_DIR/${ARCHIVE_NAME%.zip}.html"

log 'Generating signed enclosure and signed feed'
"$GENERATE_APPCAST" \
    --account "$SPARKLE_ACCOUNT" \
    --download-url-prefix "$RELEASE_BASE_URL/$RELEASE_TAG/" \
    --embed-release-notes \
    --maximum-versions 1 \
    --maximum-deltas 0 \
    --versions "$BUILD_VERSION" \
    "$APPCAST_WORK_DIR"
[[ -f "$GENERATED_APPCAST" ]] || fail 'Sparkle did not generate appcast.xml'
xmllint --noout "$GENERATED_APPCAST"

APPCAST_VERSION="$(xmllint --xpath "string(//*[local-name()='item']/*[local-name()='version'])" "$GENERATED_APPCAST")"
APPCAST_SHORT_VERSION="$(xmllint --xpath "string(//*[local-name()='item']/*[local-name()='shortVersionString'])" "$GENERATED_APPCAST")"
APPCAST_URL="$(xmllint --xpath "string(//*[local-name()='item']/*[local-name()='enclosure']/@url)" "$GENERATED_APPCAST")"
APPCAST_LENGTH="$(xmllint --xpath "string(//*[local-name()='item']/*[local-name()='enclosure']/@length)" "$GENERATED_APPCAST")"
APPCAST_SIGNATURE="$(xmllint --xpath "string(//*[local-name()='item']/*[local-name()='enclosure']/@*[local-name()='edSignature'])" "$GENERATED_APPCAST")"
ARCHIVE_LENGTH="$(stat -f '%z' "$ARCHIVE_PATH")"
[[ "$APPCAST_VERSION" == "$BUILD_VERSION" ]] || fail 'Appcast build version mismatch'
[[ "$APPCAST_SHORT_VERSION" == "$SHORT_VERSION" ]] || fail 'Appcast short version mismatch'
[[ "$APPCAST_URL" == "$DOWNLOAD_URL" ]] || fail "Unexpected Appcast download URL: $APPCAST_URL"
[[ "$APPCAST_LENGTH" == "$ARCHIVE_LENGTH" ]] || fail 'Appcast archive length mismatch'
[[ -n "$APPCAST_SIGNATURE" ]] || fail 'Appcast enclosure is unsigned'
"$SIGN_UPDATE" --account "$SPARKLE_ACCOUNT" --verify "$ARCHIVE_PATH" "$APPCAST_SIGNATURE"
"$SIGN_UPDATE" --account "$SPARKLE_ACCOUNT" --verify "$GENERATED_APPCAST"

mkdir -p "$(dirname "$APPCAST_OUTPUT")"
cp "$GENERATED_APPCAST" "$APPCAST_OUTPUT"
xmllint --noout "$APPCAST_OUTPUT"
ARCHIVE_SHA256="$(shasum -a 256 "$ARCHIVE_PATH" | awk '{print $1}')"

if [[ "$PUBLISH" == '1' ]]; then
    log 'Publishing immutable GitHub Release asset'
    HEAD_SHA="$(git -C "$REPO_ROOT" rev-parse HEAD)"
    gh-diaspar release create "$RELEASE_TAG" \
        "$ARCHIVE_PATH#$ARCHIVE_NAME" \
        --repo "$REPOSITORY" \
        --target "$HEAD_SHA" \
        --title "VoiceInk $SHORT_VERSION ($BUILD_VERSION)" \
        --notes-file "$NOTES_PATH"

    REMOTE_ARCHIVE="$OUTPUT_DIR/public-$ARCHIVE_NAME"
    curl --fail --location --retry 3 --output "$REMOTE_ARCHIVE" "$DOWNLOAD_URL"
    [[ "$(stat -f '%z' "$REMOTE_ARCHIVE")" == "$ARCHIVE_LENGTH" ]] || fail 'Public archive length mismatch'
    [[ "$(shasum -a 256 "$REMOTE_ARCHIVE" | awk '{print $1}')" == "$ARCHIVE_SHA256" ]] || fail 'Public archive hash mismatch'
    "$SIGN_UPDATE" --account "$SPARKLE_ACCOUNT" --verify "$REMOTE_ARCHIVE" "$APPCAST_SIGNATURE"

    log 'Publishing signed appcast last'
    PRE_METADATA_HEAD="$(git -C "$REPO_ROOT" rev-parse HEAD)"
    git -C "$REPO_ROOT" add -- appcast.xml
    [[ -z "$(git -C "$REPO_ROOT" diff --cached --name-only | grep -v '^appcast.xml$' || true)" ]] || fail 'Unexpected staged files before appcast commit'
    git -C "$REPO_ROOT" commit -m "release: publish VoiceInk $SHORT_VERSION build $BUILD_VERSION"
    git -C "$REPO_ROOT" push origin "HEAD:$FEED_BRANCH"
    PUBLISHED_METADATA_HEAD="$(git -C "$REPO_ROOT" rev-parse HEAD)"

    PUBLIC_APPCAST="$OUTPUT_DIR/public-appcast.xml"
    for attempt in 1 2 3 4 5 6; do
        if curl --fail --location --output "$PUBLIC_APPCAST" "$FEED_URL" \
            && [[ "$(shasum -a 256 "$PUBLIC_APPCAST" | awk '{print $1}')" == "$(shasum -a 256 "$APPCAST_OUTPUT" | awk '{print $1}')" ]]; then
            break
        fi
        [[ "$attempt" != '6' ]] || fail 'Public appcast did not converge to the published feed'
        sleep 2
    done
    xmllint --noout "$PUBLIC_APPCAST"
    "$SIGN_UPDATE" --account "$SPARKLE_ACCOUNT" --verify "$PUBLIC_APPCAST"
    [[ "$(xmllint --xpath "string(//*[local-name()='item']/*[local-name()='version'])" "$PUBLIC_APPCAST")" == "$BUILD_VERSION" ]] \
        || fail 'Public appcast build version mismatch'
    PUBLISHED_METADATA_HEAD=""
fi

printf '\nVoiceInk release prepared successfully.\n'
printf 'Version: %s\nBuild: %s\nArchive SHA-256: %s\n' "$SHORT_VERSION" "$BUILD_VERSION" "$ARCHIVE_SHA256"
if [[ "$PUBLISH" == '1' ]]; then
    printf 'Publication: public asset and signed feed verified\n'
else
    printf 'Publication: not requested\n'
fi
