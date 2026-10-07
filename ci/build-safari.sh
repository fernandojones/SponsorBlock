#!/usr/bin/env bash
set -euo pipefail

# Build Safari Extension macOS App and optional iOS App (IPA) using Xcode
# Usage: ./ci/build-safari.sh [--zip <path-to-SafariExtension.zip>] [--output-dir <path>] [--team-id <team-id>] [--macos-only]

ZIP_PATH=""
OUTPUT_DIR="./dist-safari"
TEAM_ID="D9A6A3ZA4X"
BUILD_IOS="true"
TEMP_DIR=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --zip)
      ZIP_PATH="$2"
      shift 2
      ;;
    --output-dir)
      OUTPUT_DIR="$2"
      shift 2
      ;;
    --team-id)
      TEAM_ID="$2"
      shift 2
      ;;
    --macos-only)
      BUILD_IOS="false"
      shift 1
      ;;
    *)
      echo "Unknown argument: $1" >&2
      exit 1
      ;;
  esac
done

if [ -z "$ZIP_PATH" ]; then
  echo "Error: --zip <path-to-SafariExtension.zip> is required." >&2
  exit 1
fi

if [ ! -f "$ZIP_PATH" ]; then
  echo "Error: zip file not found: $ZIP_PATH" >&2
  exit 1
fi

mkdir -p "$OUTPUT_DIR"
OUTPUT_DIR=$(cd "$OUTPUT_DIR" && pwd)
ZIP_PATH=$(cd "$(dirname "$ZIP_PATH")" && pwd)/$(basename "$ZIP_PATH")

TEMP_DIR=$(mktemp -d -t sponsorblock-safari-XXXXXX)
cleanup() {
  echo "==> Cleaning up temporary files..."
  rm -rf "$TEMP_DIR"
}
trap cleanup EXIT

echo "==> Working in temporary directory: $TEMP_DIR"
EXT_DIR="$TEMP_DIR/extension"
XCODE_DIR="$TEMP_DIR/xcode"
DERIVED_DATA="$TEMP_DIR/DerivedData"

mkdir -p "$EXT_DIR" "$XCODE_DIR"

echo "==> Unpacking SafariExtension.zip..."
unzip -q "$ZIP_PATH" -d "$EXT_DIR"

echo "==> Converting web extension to Xcode project..."
xcrun safari-web-extension-converter \
  --no-open \
  --no-prompt \
  --force \
  --project-location "$XCODE_DIR" \
  "$EXT_DIR"

PROJECT_PATH="$XCODE_DIR/SponsorBlock for YouTube/SponsorBlock for YouTube.xcodeproj"
if [ ! -d "$PROJECT_PATH" ]; then
  echo "Error: Xcode project not found at $PROJECT_PATH" >&2
  exit 1
fi

echo "==> Building macOS App (Release)..."
if ! xcodebuild \
  -project "$PROJECT_PATH" \
  -scheme "SponsorBlock for YouTube (macOS)" \
  -configuration Release \
  -derivedDataPath "$DERIVED_DATA" \
  ARCHS="x86_64 arm64" \
  ONLY_ACTIVE_ARCH=NO \
  MACOSX_DEPLOYMENT_TARGET="12.0" \
  DEVELOPMENT_TEAM="$TEAM_ID" \
  CODE_SIGN_STYLE=Automatic \
  build; then
  echo "==> Development team signing failed. Falling back to Ad-Hoc signing for macOS..."
  xcodebuild \
    -project "$PROJECT_PATH" \
    -scheme "SponsorBlock for YouTube (macOS)" \
    -configuration Release \
    -derivedDataPath "$DERIVED_DATA" \
    ARCHS="x86_64 arm64" \
    ONLY_ACTIVE_ARCH=NO \
    MACOSX_DEPLOYMENT_TARGET="12.0" \
    CODE_SIGN_IDENTITY="-" \
    CODE_SIGN_STYLE=Manual \
    build
fi

echo "==> Packaging macOS App..."
MACOS_APP="$DERIVED_DATA/Build/Products/Release/SponsorBlock for YouTube.app"
if [ -d "$MACOS_APP" ]; then
  (cd "$DERIVED_DATA/Build/Products/Release" && zip -qry "$OUTPUT_DIR/SponsorBlock-Safari-macOS.zip" "SponsorBlock for YouTube.app")
  echo "Created: $OUTPUT_DIR/SponsorBlock-Safari-macOS.zip"
else
  echo "Error: macOS app not found at $MACOS_APP" >&2
  exit 1
fi

if [ "$BUILD_IOS" = "true" ]; then
  echo "==> Building iOS App (Release)..."
  if ! xcodebuild \
    -project "$PROJECT_PATH" \
    -scheme "SponsorBlock for YouTube (iOS)" \
    -configuration Release \
    -destination "generic/platform=iOS" \
    -derivedDataPath "$DERIVED_DATA" \
    DEVELOPMENT_TEAM="$TEAM_ID" \
    CODE_SIGN_STYLE=Automatic \
    build; then
    echo "==> Development team signing failed. Falling back to unsigned build for iOS (sideload-ready)..."
    xcodebuild \
      -project "$PROJECT_PATH" \
      -scheme "SponsorBlock for YouTube (iOS)" \
      -configuration Release \
      -destination "generic/platform=iOS" \
      -derivedDataPath "$DERIVED_DATA" \
      CODE_SIGNING_ALLOWED=NO \
      CODE_SIGNING_REQUIRED=NO \
      CODE_SIGN_IDENTITY="" \
      build || {
        echo "==> Warning: iOS build failed due to missing iOS SDK platform runtimes on host runner."
        echo "==> Skipping iOS IPA packaging."
        BUILD_IOS="failed"
      }
  fi

  if [ "$BUILD_IOS" = "true" ]; then
    echo "==> Packaging iOS IPA..."
    IOS_APP="$DERIVED_DATA/Build/Products/Release-iphoneos/SponsorBlock for YouTube.app"
    if [ -d "$IOS_APP" ]; then
      PAYLOAD_DIR="$TEMP_DIR/Payload"
      mkdir -p "$PAYLOAD_DIR"
      cp -R "$IOS_APP" "$PAYLOAD_DIR/"
      (cd "$TEMP_DIR" && zip -qry "$OUTPUT_DIR/SponsorBlock-Safari-iOS.ipa" Payload)
      echo "Created: $OUTPUT_DIR/SponsorBlock-Safari-iOS.ipa"
    else
      echo "Warning: iOS app not found at $IOS_APP" >&2
    fi
  fi
fi

cp "$ZIP_PATH" "$OUTPUT_DIR/SafariExtension.zip"
echo "Copied: $OUTPUT_DIR/SafariExtension.zip"

echo "==> Safari build & packaging complete!"
