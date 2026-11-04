#!/bin/zsh
# MonkeWall'ı ve kilit ekranı kaydını tamamen kaldırır.
set -u

LABEL="com.hootbu.monkewall"
OLD_LABEL="com.hootbu.monkeywallpaper"
SUPPORT="$HOME/Library/Application Support/MonkeWall"
APP="$HOME/Desktop/MonkeWall/MonkeWall.app/Contents/MacOS/MonkeWall"

launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
launchctl bootout "gui/$(id -u)/$OLD_LABEL" 2>/dev/null || true
sleep 0.5

# Kilit ekranını eski haline döndür ve videoyu sistem kayıtlarından çıkar.
if [ -x "$APP" ]; then
    "$APP" --uninstall
fi

rm -f "$HOME/Library/LaunchAgents/$LABEL.plist"
rm -f "$HOME/Library/LaunchAgents/$OLD_LABEL.plist"
rm -f "$HOME/Library/Logs/MonkeWall.log" "$HOME/Library/Logs/MonkeWall.stderr.log"
rm -f "$HOME/Library/Logs/MonkeyWallpaper.log" "$HOME/Library/Logs/MonkeyWallpaper.stderr.log"

rm -rf "$SUPPORT"
rm -rf "$HOME/Library/Application Support/MonkeyWallpaper"

echo "MonkeWall kaldırıldı. Proje klasörünü (~/Desktop/MonkeWall) istersen silebilirsin."
