#!/bin/bash
set -e

PLATFORM=${1:-all}
mkdir -p dist

build_ios() {
    echo "📦 Building Koro.ipa for iOS..."
    rm -rf build/Build/Products/Release-iphoneos dist/Koro.ipa dist/Payload
    xcodebuild -project Koro.xcodeproj \
               -scheme Koro \
               -destination 'generic/platform=iOS' \
               -configuration Release \
               -derivedDataPath ./build \
               CODE_SIGNING_ALLOWED=NO \
               build -quiet

    mkdir -p dist/Payload
    cp -R ./build/Build/Products/Release-iphoneos/Koro.app dist/Payload/
    (cd dist && zip -qr Koro.ipa Payload && rm -rf Payload)
    echo "✅ Built: dist/Koro.ipa"
}

build_mac() {
    echo "🍏 Building Koro.app for macOS..."
    rm -rf build/Build/Products/Release-maccatalyst dist/Koro.app
    xcodebuild -project Koro.xcodeproj \
               -scheme Koro \
               -destination 'platform=macOS,variant=Mac Catalyst' \
               -configuration Release \
               -derivedDataPath ./build \
               build -quiet

    cp -R ./build/Build/Products/Release-maccatalyst/Koro.app dist/
    echo "✅ Built: dist/Koro.app"
}

case "$PLATFORM" in
    ios)
        build_ios
        ;;
    mac)
        build_mac
        ;;
    all)
        build_ios
        build_mac
        ;;
    *)
        echo "Usage: ./build.sh [ios|mac|all]"
        exit 1
        ;;
esac
