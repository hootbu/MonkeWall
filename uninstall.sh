#!/bin/zsh
# MonkeWall'ı ve kilit ekranı kaydını tamamen kaldırır.
set -u

LABEL="com.hootbu.monkewall"
OLD_LABEL="com.hootbu.monkeywallpaper"
PROJECT="${0:A:h}"
APP="$PROJECT/MonkeWall.app/Contents/MacOS/MonkeWall"

if [ ! -x "$APP" ]; then
    echo "Uygulama bulunamadı: $APP"
    echo "Kilit ekranı geri yüklenemeyeceği için hiçbir şey silinmedi."
    exit 1
fi

launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
launchctl bootout "gui/$(id -u)/$OLD_LABEL" 2>/dev/null || true
pkill -x MonkeWall 2>/dev/null || true
sleep 0.5

# Kilit ekranını eski haline döndür ve videoyu sistem kayıtlarından çıkar.
if ! "$APP" --uninstall; then
    echo "Önceki duvar kağıdı geri yüklenemedi, hiçbir şey silinmedi."
    echo "Sistem Ayarları'ndan başka bir duvar kağıdı ve ekran koruyucu seçip betiği yeniden çalıştır."
    exit 1
fi

rm -f "$HOME/Library/LaunchAgents/$OLD_LABEL.plist"
rm -f "$HOME/Library/Logs/MonkeyWallpaper.log" "$HOME/Library/Logs/MonkeyWallpaper.stderr.log"
rm -rf "$HOME/Library/Application Support/MonkeyWallpaper"

echo "MonkeWall kaldırıldı. Proje klasörünü ($PROJECT) istersen silebilirsin."
