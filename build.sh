#!/bin/zsh
set -eu

ROOT="${0:A:h}"
APP="$ROOT/MonkeWall.app"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

SPARKLE_VERSION="2.10.1"
SPARKLE_SHA256="1a856d2a9edb8e628de88121d7be04cf0e2167f8641650b78fca00b14244cf27"
SPARKLE="$ROOT/vendor/Sparkle-$SPARKLE_VERSION"

if [ ! -d "$SPARKLE/Sparkle.framework" ]; then
    curl -fsSL "https://github.com/sparkle-project/Sparkle/releases/download/$SPARKLE_VERSION/Sparkle-$SPARKLE_VERSION.tar.xz" -o "$WORK/sparkle.tar.xz"
    echo "$SPARKLE_SHA256  $WORK/sparkle.tar.xz" | shasum -a 256 -c -
    mkdir -p "$SPARKLE"
    tar -xf "$WORK/sparkle.tar.xz" -C "$SPARKLE"
fi

CONTENTS="$WORK/MonkeWall.app/Contents"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources" "$CONTENTS/Frameworks"

swiftc -O -target arm64-apple-macos13.0 \
    -F "$SPARKLE" -Xlinker -rpath -Xlinker @executable_path/../Frameworks \
    "$ROOT"/src/*.swift -o "$CONTENTS/MacOS/MonkeWall"
cp "$ROOT/Info.plist" "$CONTENTS/Info.plist"
cp "$ROOT/branding/AppIcon.icns" "$ROOT/branding/MenuBarIcon.png" "$CONTENTS/Resources/"
cp -R "$ROOT/Localization/"*.lproj "$CONTENTS/Resources/"
ditto "$SPARKLE/Sparkle.framework" "$CONTENTS/Frameworks/Sparkle.framework"
codesign --force --sign - "$WORK/MonkeWall.app"

rm -rf "$APP"
mv "$WORK/MonkeWall.app" "$APP"
echo "Hazır: $APP"
