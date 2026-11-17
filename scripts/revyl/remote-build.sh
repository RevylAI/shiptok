#!/usr/bin/env bash
# The one build pipeline for ShipTok, used by local builds, Revyl remote builds and TestFlight uploads.
# Usage: remote-build.sh {setup|compile|zip|upload-to-testflight}
set -euo pipefail

cd "$(dirname "$0")/../.."

MIN_XCODE_VERSION="${REVYL_MIN_XCODE_VERSION:-27.1}"
DERIVED_DATA="$PWD/build/DerivedData"
PRODUCTS_DIR="$DERIVED_DATA/Build/Products/Debug-iphonesimulator"
OUTPUT_ZIP="$PWD/build/ShipTok.app.zip"

setup() {
    command -v xcodebuild >/dev/null 2>&1 || {
        echo "error: xcodebuild not found" >&2
        exit 1
    }
    local version
    version="$(xcodebuild -version | awk 'NR==1 {print $2}')"
    if [ "$(printf '%s\n' "$MIN_XCODE_VERSION" "$version" | sort -V | head -n 1)" != "$MIN_XCODE_VERSION" ]; then
        echo "error: Xcode ${MIN_XCODE_VERSION}+ required (the feed reads the system's reserved regions, new in the iOS 27.1 SDK), found ${version}" >&2
        exit 1
    fi
    echo "setup ok (Xcode ${version})"
}

compile() {
    xcodebuild build \
        -project ShipTok.xcodeproj \
        -scheme ShipTok \
        -configuration Debug \
        -sdk iphonesimulator \
        -destination 'generic/platform=iOS Simulator' \
        -derivedDataPath "$DERIVED_DATA" \
        CODE_SIGN_IDENTITY=- \
        CODE_SIGN_STYLE=Manual \
        ARCHS=arm64 \
        ${SHIPTOK_REVYL_BACKEND_URL:+"SHIPTOK_REVYL_BACKEND_URL=$SHIPTOK_REVYL_BACKEND_URL"}
    find_built_app >/dev/null
    echo "built: $(find_built_app)"
}

find_built_app() {
    local app
    app="$(find "$PRODUCTS_DIR" -maxdepth 1 -name '*.app' -print -quit 2>/dev/null || true)"
    if [ -z "$app" ]; then
        echo "error: no .app under $PRODUCTS_DIR; run compile first" >&2
        exit 1
    fi
    echo "$app"
}

zip_app() {
    local app
    app="$(find_built_app)"
    rm -f "$OUTPUT_ZIP"
    (cd "$(dirname "$app")" && zip -qry "$OUTPUT_ZIP" "$(basename "$app")")
    echo "zipped: $OUTPUT_ZIP"
}

APPLE_TEAM_ID="9MQ4RWNL3N"

# The archive stays unsigned: the export signs it for distribution with the team's cloud-managed certificate, so no machine needs a signing identity.
# Takes an App Store Connect API key of the team: APP_STORE_CONNECT_API_KEY_ID, APP_STORE_CONNECT_API_ISSUER_ID and APP_STORE_CONNECT_API_PRIVATE_KEY (the .p8 file's contents).
upload_to_testflight() {
    : "${APP_BUILD_NUMBER:?set APP_BUILD_NUMBER}"
    local key_id="${APP_STORE_CONNECT_API_KEY_ID:?set APP_STORE_CONNECT_API_KEY_ID}"
    local issuer_id="${APP_STORE_CONNECT_API_ISSUER_ID:?set APP_STORE_CONNECT_API_ISSUER_ID}"
    : "${APP_STORE_CONNECT_API_PRIVATE_KEY:?set APP_STORE_CONNECT_API_PRIVATE_KEY}"
    APP_STORE_CONNECT_KEY_DIR="$(mktemp -d)"
    trap 'rm -rf "$APP_STORE_CONNECT_KEY_DIR"' EXIT
    local key_path="$APP_STORE_CONNECT_KEY_DIR/AuthKey_$key_id.p8"
    (umask 077 && printf '%s\n' "$APP_STORE_CONNECT_API_PRIVATE_KEY" >"$key_path")
    local archive_path="$PWD/build/TestFlight/ShipTok.xcarchive"
    local export_path="$PWD/build/TestFlight/export"
    local export_options_path="$PWD/build/TestFlight/export-options.plist"
    rm -rf "$PWD/build/TestFlight"
    mkdir -p "$PWD/build/TestFlight"
    xcodebuild archive \
        -project ShipTok.xcodeproj \
        -scheme ShipTok \
        -configuration Release \
        -destination 'generic/platform=iOS' \
        -archivePath "$archive_path" \
        CURRENT_PROJECT_VERSION="$APP_BUILD_NUMBER" \
        CODE_SIGNING_ALLOWED=NO
    cat >"$export_options_path" <<EXPORT_OPTIONS
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key><string>app-store-connect</string>
    <key>destination</key><string>upload</string>
    <key>signingStyle</key><string>automatic</string>
    <key>teamID</key><string>$APPLE_TEAM_ID</string>
    <key>manageAppVersionAndBuildNumber</key><false/>
    <key>uploadSymbols</key><true/>
</dict>
</plist>
EXPORT_OPTIONS
    xcodebuild -exportArchive \
        -archivePath "$archive_path" \
        -exportPath "$export_path" \
        -exportOptionsPlist "$export_options_path" \
        -allowProvisioningUpdates \
        -authenticationKeyPath "$key_path" \
        -authenticationKeyID "$key_id" \
        -authenticationKeyIssuerID "$issuer_id"
    echo "uploaded ShipTok build $APP_BUILD_NUMBER to App Store Connect on team $APPLE_TEAM_ID"
}

case "${1:-}" in
    setup) setup ;;
    compile) compile ;;
    zip) zip_app ;;
    upload-to-testflight) upload_to_testflight ;;
    *)
        echo "usage: $0 {setup|compile|zip|upload-to-testflight}" >&2
        exit 2
        ;;
esac
