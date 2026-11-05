#!/bin/zsh
set -eu

ROOT="${0:A:h}"
NOTES="${1:?Kullanım: ./release.sh \"sürüm notu\" (önce Info.plist'te sürümü artır)}"

cd "$ROOT"
if [ -n "$(git status --porcelain)" ]; then
    echo "Commitlenmemiş değişiklik var, önce commit et."
    exit 1
fi

DIST="$(mktemp -d)"
trap 'rm -rf "$DIST"' EXIT

./build.sh

plist() { /usr/libexec/PlistBuddy -c "Print :$1" Info.plist }
VERSION="$(plist CFBundleShortVersionString)"
BUILD="$(plist CFBundleVersion)"
MIN_SYSTEM="$(plist LSMinimumSystemVersion)"
TAG="v$VERSION"
ZIP="MonkeWall-$VERSION.zip"
SPARKLE="vendor/Sparkle-$(sed -n 's/^SPARKLE_VERSION="\(.*\)"$/\1/p' build.sh)"

ditto -c -k --sequesterRsrc --keepParent MonkeWall.app "$DIST/$ZIP"

"$SPARKLE/bin/generate_keys" -x "$DIST/key"
SIGNATURE="$("$SPARKLE/bin/sign_update" --ed-key-file "$DIST/key" "$DIST/$ZIP")"
cp "$DIST/$ZIP" "$DIST/MonkeWall.zip"

cat > "$DIST/appcast.xml" <<EOF
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>MonkeWall</title>
    <item>
      <title>$VERSION</title>
      <pubDate>$(LC_ALL=C date -u "+%a, %d %b %Y %H:%M:%S +0000")</pubDate>
      <sparkle:version>$BUILD</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>$MIN_SYSTEM</sparkle:minimumSystemVersion>
      <description><![CDATA[<p>$NOTES</p>]]></description>
      <enclosure url="https://github.com/hootbu/MonkeWall/releases/download/$TAG/$ZIP" type="application/octet-stream" $SIGNATURE/>
    </item>
  </channel>
</rss>
EOF

"$SPARKLE/bin/sign_update" --ed-key-file "$DIST/key" "$DIST/appcast.xml"
"$SPARKLE/bin/sign_update" --verify --ed-key-file "$DIST/key" "$DIST/appcast.xml"
rm -f "$DIST/key"

gh release create "$TAG" "$DIST/$ZIP" "$DIST/MonkeWall.zip" "$DIST/appcast.xml" \
    --target "$(git rev-parse HEAD)" \
    --title "MonkeWall $VERSION" \
    --notes "$NOTES"
