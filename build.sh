#!/bin/zsh
set -eu

ROOT="${0:A:h}"
APP="$ROOT/MonkeWall.app"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

CONTENTS="$WORK/MonkeWall.app/Contents"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources"

swiftc -O -target arm64-apple-macos13.0 "$ROOT"/src/*.swift -o "$CONTENTS/MacOS/MonkeWall"
cp "$ROOT/Info.plist" "$CONTENTS/Info.plist"
cp "$ROOT/branding/AppIcon.icns" "$ROOT/branding/MenuBarIcon.png" "$CONTENTS/Resources/"
cp -R "$ROOT/Localization/"*.lproj "$CONTENTS/Resources/"
codesign --force --sign - "$WORK/MonkeWall.app"

rm -rf "$APP"
mv "$WORK/MonkeWall.app" "$APP"
echo "Hazır: $APP"
