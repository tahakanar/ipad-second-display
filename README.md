# İkinci Ekran

İkinci Ekran, iPad’inizi Mac’iniz için kablosuz bir **genişletilmiş ekran** olarak kullanmanızı sağlar. Örneğin, bir PDF penceresini iPad’e sürükleyip Mac ekranında notlarınızı yazmaya devam edebilirsiniz. İki ekranı da Mac’in klavyesi ve trackpad’iyle kullanırsınız.

Mac ve iPad birbirini aynı yerel ağda Bonjour ile bulur. Mac’te gösterilen kodla eşleştikten sonra görüntü, TLS ile şifrelenmiş bağlantı üzerinden doğrudan iPad’e aktarılır. İki cihazda farklı Apple hesapları kullanabilirsiniz.

## Gereksinimler

| Bileşen | Gereken |
| --- | --- |
| Mac | macOS 14 veya üzeri |
| iPad | iPadOS 15 veya üzeri |
| İlk kurulum | Mac’te iPad’in sistem sürümünü destekleyen Xcode, bir Apple hesabı ve veri aktarabilen USB kablosu |
| Kullanım | Cihazların birbirine erişebildiği ortak bir yerel ağ |

## Kurulum

### 1. Projeyi Mac’te açın

```sh
git clone https://github.com/tahakanar/ipad-second-display.git
cd ipad-second-display
open IkinciEkran.xcodeproj
```

Xcode projesi ve iki uygulamanın şemaları depoya dahildir. Xcode’un üst çubuğundan **MacDisplay → My Mac** seçip **⌘R** tuşlarına basın.

Mac uygulamasını daha sonra Xcode açmadan kullanmak için aşağıdaki komutu proje klasöründe çalıştırabilirsiniz. Ardından Finder’da `build/Build/Products/Release/MacDisplay.app` dosyasını **Uygulamalar** klasörüne kopyalayın. İlk paylaşımı kullanacağınız kopyadan başlatın.

```sh
xcodebuild -project IkinciEkran.xcodeproj -scheme MacDisplay \
  -configuration Release -destination 'platform=macOS' -derivedDataPath build build
```

### 2. iPad uygulamasını yükleyin

1. iPad’in kilidini açıp USB ile Mac’e bağlayın. iPad sorarsa **Bu Bilgisayara Güven**’i onaylayın.
2. Xcode’da **Settings → Apple Accounts** bölümüne Apple hesabınızı ekleyin. Sol kenarda projeyi, ardından **TARGETS → iPadDisplay → Signing & Capabilities**’i seçin.
3. **Automatically manage signing** açıkken **Team** alanından hesabınızı seçin. Xcode paket kimliğinin kullanımda olduğunu bildirirse **Bundle Identifier** alanına size özgü bir değer girin.
4. Üst çubukta **iPadDisplay** şemasını ve hedef olarak fiziksel iPad’inizi seçin. **⌘R** ile yükleyin. iPadOS 16 veya üzerinde Xcode isterse iPad’de **Ayarlar → Gizlilik ve Güvenlik → Geliştirici Modu**’nu açın. Cihaz yeniden başladıktan sonra onay verip **⌘R**’ye tekrar basın.
5. iPad’de **İkinci Ekran** açıldığında yerel ağ erişimine izin verin. USB kablosunu çıkarabilirsiniz.

Ücretsiz **Personal Team** ile kurulumda geliştirme profili 7 gün geçerlidir. Süre dolduğunda iPad’i yeniden seçip Xcode’dan **⌘R** ile yükleyebilirsiniz. [Apple’ın cihazda çalıştırma kılavuzu](https://developer.apple.com/documentation/xcode/running-your-app-on-simulated-or-physical-devices) · [Apple hesabı ve profil süreleri](https://developer.apple.com/help/account/basics/about-your-developer-account/)

## İlk bağlantı

1. İki cihazı aynı Wi-Fi ağına bağlayın. Mac uygulamasında **Paylaşımı başlat**’ı seçin. macOS istediğinde ekran kaydı ve yerel ağ izinlerini verin. macOS yeniden açmanızı isterse uygulamayı kapatıp açın ve paylaşımı tekrar başlatın.
2. iPad’de listeden Mac’inizi seçin. Mac’te görünen dört gruplu, 16 karakterli eşleme kodunu girip **Bağlan**’a dokunun.
3. Mac’te **Ekranları yerleştir…** düğmesine basın. **iPad Ekranı**’nı iPad’in masada durduğu tarafa yerleştirin. Bir pencereyi o yönde Mac ekranının kenarından sürükleyin.

Paylaşımı Mac’te **Paylaşımı durdur** ile bitirebilirsiniz. iPad’de ise ekrana dokunup **Bağlantıyı kes**’i seçin. Yeniden bağlanırken Mac’in gösterdiği güncel kodu kullanın.

## Görüntü ve uyumluluk

Sanal ekranın çalışma alanı **1024 × 768 punto**dur. Mac, görüntüyü imleçle birlikte **2048 × 1536 piksel** çözünürlükte H.264 olarak saniyede en fazla 30 kare hızında gönderir. iPad, yönü değiştiğinde görüntünün en boy oranını korur. Ses Mac’ten çalar.

Mac uygulaması sanal ekranı macOS’un belgelenmemiş `CGVirtualDisplay` arabirimiyle oluşturur. macOS güncellemeleri bu özelliğin uyumluluğunu etkileyebilir.

## Sorun giderme

| Belirti | Kontrol |
| --- | --- |
| Mac, iPad’de görünmüyor | Mac’te eşleme kodunun göründüğünü ve her iki uygulamanın da yerel ağ izni olduğunu kontrol edin. Misafir Wi-Fi ağları cihazlar arası erişimi engelleyebilir. |
| Kod kabul edilmiyor | Mac’te o anda görünen kodu kullanın. Önceki oturumun kodu bağlantı kapandığında geçerliliğini yitirir. |
| Mac ekran kaydı izni istiyor | **Sistem Ayarları → Gizlilik ve Güvenlik → Ekran ve Sistem Sesi Kaydı** bölümünden çalıştırdığınız uygulamaya izin verin. Gerekirse uygulamayı kapatıp yeniden açın. |
| Pencere yanlış kenardan geçiyor | Mac’te **Ekranları yerleştir…** ile sanal ekranı iPad’in fiziksel konumuna taşıyın. |

## Geliştirme ve test

[MacApp](MacApp) paylaşım penceresini ve oturumu yönetir. [MacEngine](MacEngine) sanal ekranı oluşturur, ScreenCaptureKit ile yakalar ve VideoToolbox ile kodlar. [Shared](Shared) cihaz keşfi, eşleştirme ve veri aktarımını içerir. [iPadClient](iPadClient) gelen kareleri iPad’de gösterir.

25 Kasım 2026’da Xcode 26.6 ile her iki hedefin Release derlemesi ve statik analizi geçti. macOS 26.5 üzerinde sanal ekrana yerleştirilen bir test penceresinin iPadOS 26.5 yüklü iPad (A16) simülatörüne ulaştığı, pencerenin rengi simülatör ekranından okunarak doğrulandı. Fiziksel iPad’de kurulum ve gerçek Wi-Fi gecikmesi henüz doğrulanmadı.

Bağlantı protokolü ve Mac oturum testlerini proje klasöründe çalıştırabilirsiniz.

```sh
checks_dir="$(mktemp -d)"
swiftc Shared/*.swift Tests/Transport/main.swift -o "$checks_dir/transport" && "$checks_dir/transport"
swiftc -parse-as-library Shared/DisplayLink.swift MacApp/HostController.swift \
  Tests/HostController/HostControllerChecks.swift -o "$checks_dir/host" && "$checks_dir/host"
```

Sanal ekranın açılıp kapanmasını ve H.264 çıktısını sınamak için ekran kaydı izni olan bir terminalde `Tests/MacEngine/run.sh` çalıştırın. iPad oturum testleri için bir iPad simülatörü açın, `xcrun simctl list devices booted` ile kimliğini bulun ve `Tests/PadSession/run.sh "SIMULATOR_UUID"` komutuna bu kimliği verin.
