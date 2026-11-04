# MonkeWall

Masaüstünde ve kilit ekranında video oynatan küçük bir macOS uygulaması. Dock'ta görünmez, menü çubuğundaki 🐒 simgesinden yönetilir.

## Ne yapar?

- Videoyu masaüstünde kesintisiz oynatır (tüm ekranlarda).
- Videoyu isteğe bağlı olarak kilit ekranına / ekran koruyucuya da koyar.
- Başka bir uygulamaya geçince videoyu duraklatır (varsayılan açık).
- Ekran uykuya geçince veya oturum kilitlenince duraklar.
- Oturum açılışında kendiliğinden başlar.

## Kütüphane

Menü çubuğunda 🐒 > **Kütüphane…** (⌘L) ile açılan pencerede:

- Videolar kapak görselleriyle ızgara halinde listelenir.
- **Video Ekle** veya pencereye **sürükle-bırak** ile birden fazla video eklenir.
- Bir karta tıklayınca o video anında masaüstü + kilit ekranı için kullanılır.
- Sağ tık: **Duvar Kağıdı Yap**, **Finder'da Göster**, **Kütüphaneden Kaldır**.
- Seçim hatırlanır; uygulama yeniden başlayınca son video devam eder.

Yeni video eklerken kilit ekranı için 4K HEVC bir kopya arka planda hazırlanır; kartın üzerinde "Kilit ekranı hazırlanıyor…" görünür. Bu sırada masaüstü videoyu hemen oynatmaya başlar.

## Kontrol

Menü çubuğunda 🐒:

- **Kütüphane…** — video koleksiyonunu açar.
- **Video Ekle…** — kütüphaneye yeni video ekler.
- **Duraklat / Devam Et**
- **Odaklanınca Duraklat** — bir uygulama öne geldiğinde videoyu durdurur (varsayılan açık). MonkeWall'un kendi penceresi açıkken video oynamaya devam eder.
- **Kilit Ekranında Oynat** — videoyu macOS'un yerel ekran koruyucu/kilit ekranı videosu olarak kaydeder.
- **Yeniden Yükle** — ayarları ve videoyu yeniden okur.
- **Çıkış**

## Dosya konumları

- Uygulama: `~/Desktop/MonkeWall/MonkeWall.app`
- Kaynak kod: `~/Desktop/MonkeWall/src/`
- Logo dosyaları: `~/Desktop/MonkeWall/branding/`
  - `AppIcon.icns` — uygulama simgesi
  - `AppIcon-1024.png` — 1024 px uygulama ikonu
  - `Logo-transparent-1024.png` — şeffaf zeminli logo
  - `MenuBarIcon.png` — menü çubuğu için template ikon
- Çalışma verileri: `~/Library/Application Support/MonkeWall/`
  - `library/` — kütüphaneye eklenen videolar, kapak görselleri ve kilit ekranı kopyaları
  - `library/library.json` — kütüphane sırası ve seçili video
  - `config.json` — ayarlar
  - `backup/` — ilk kurulumdaki duvar kağıdı ayarının yedeği

Çalışma verileri bilerek Application Support'ta tutulur; böylece macOS'un "Masaüstü klasörüne erişim" izni gerekmez.

## Kilit ekranı nasıl çalışıyor?

Video, macOS'un kendi "aerial" duvar kağıdı sistemine kaydedilir. Sistem Ayarları > Duvar Kağıdı bölümünde **MonkeWall** olarak da görünür. macOS kilit ekranının arka planını masaüstü duvar kağıdı seçiminden aldığı için hem masaüstü hem Idle (ekran koruyucu) seçimi aynı videoya bağlanır. Bu sayede kilit ekranı/ekran koruyucu videoyu uygulama kapalıyken bile oynatır.

Kilit ekranı için her video adına 4K HEVC 10-bit bir kopya üretilir (ffmpeg gerekir). Bu format macOS'un kendi aerial videolarıyla aynı olduğu için kilit ekranındaki siyah kare sorununu önler.

- İlk kurulumda eski kilit ekranı ayarı `backup/Index.plist.original` dosyasına yedeklenir.
- **Kilit Ekranında Oynat** kapatılınca veya kaldırma betiği çalışınca eski kilit ekranı geri yüklenir.
- Apple bu sistemi resmî olarak desteklemiyor; macOS güncellemeleri sonrası kayıt kaybolursa 🐒 > **Yeniden Yükle** yeterli.

## Kaldırma

```sh
~/Desktop/MonkeWall/uninstall.sh
```

Bu betik uygulamanın LaunchAgent'ını ve kilit ekranı kaydını kaldırır, eski duvar kağıdını geri yükler ve `~/Library/Application Support/MonkeWall` verilerini siler. Proje klasörünü ayrıca silebilirsin.

## Notlar

- Odaklanınca duraklatma açıkken video yalnızca masaüstü görünürken (Finder veya MonkeWall öndeyken) oynar; başka bir uygulamadayken CPU/GPU kullanımı ~0'a düşer.
- Fiziksel bellek kullanımı yaklaşık 33 MB, oynarken CPU kullanımı yaklaşık %3–5 civarındadır (1080p, iki ekran).
- Kilit ekranı kopyaları için `ffmpeg` gerekir (`brew install ffmpeg`). ffmpeg yoksa kilit ekranı videonun orijinal halini kullanır.
