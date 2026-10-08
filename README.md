# Windows ISO Builder (10 / 11)

Orijinal bir Windows 10 veya Windows 11 ISO'sundan **temizlenmiş, sürücüleri eklenmiş ve otomatik kurulan** yeni bir ISO üreten ya da bunu doğrudan **USB diske yazan** grafik arayüzlü araç. Hazır bir ISO'yu Rufus gibi değiştirmeden USB'ye yazmak için de kullanılabilir. Öncelikle **Proxmox** sanal makineleri için tasarlandı (VirtIO sürücüleri), ama üretilen ISO normal bilgisayarlarda da kullanılabilir.

Tek bir PowerShell dosyasından oluşur, istenirse `.exe` haline getirilebilir.

---

## Dosyalar

| Dosya | Açıklama |
|---|---|
| `WindowsIsoBuilder.ps1` | Programın kendisi (arayüz + ISO oluşturma motoru tek dosyada) |
| `Build-EXE.cmd` | `ps2exe` ile `WindowsIsoBuilder.exe` üretir |
| `WindowsIsoBuilder.ico` | Program ikonu |

## Gereksinimler

- Windows 10 veya 11 (programın çalıştığı bilgisayar)
- Yönetici hakları — program yetkisiz açılırsa kendini yönetici olarak yeniden başlatır
- **Windows ADK – Deployment Tools** (`oscdimg.exe`) — **sadece ISO dosyası oluşturmak için** gerekir; kurulu değilse "ISO OLUŞTUR"a basıldığında winget ile indirip kurmayı önerir (~100 MB). USB'ye yazarken gerekmez
- Çalışma dizini için **~15 GB boş alan** (hazır ISO yazılırken sadece install.wim kadar, ~6 GB)
- Süre: disk hızına göre **20–40 dakika** (hazır ISO'yu USB'ye yazmak 5–20 dakika)

## Çalıştırma

**EXE olarak:** `Build-EXE.cmd` dosyasını çift tıklayın. `ps2exe` modülü yoksa kurulur ve aynı klasörde `WindowsIsoBuilder.exe` oluşur.

**Doğrudan script olarak:**
```powershell
powershell -ExecutionPolicy Bypass -File .\WindowsIsoBuilder.ps1
```

Arayüz dili Windows diline göre otomatik seçilir (Türkçe / English), sağ üstteki listeden değiştirilebilir.

---

## Arayüz

| Alan | Açıklama |
|---|---|
| **Windows ISO** | Kaynak Windows 10/11 ISO'su. Seçildiğinde içindeki sürümler okunur ve Win10/Win11 otomatik algılanır |
| **VirtIO ISO** *(isteğe bağlı)* | `virtio-win.iso` — Proxmox sürücüleri buradan alınır |
| **Sürücü klasörü** *(isteğe bağlı)* | İçinde `.inf` dosyaları olan herhangi bir sürücü klasörü (alt klasörler taranır) |
| **Çıktı** | **ISO dosyası** veya **USB disk (kurulum)**. USB seçiliyken **"Hazır ISO'yu değiştirmeden yaz"** işaretlenirse seçilen ISO hiç düzenlenmeden yazılır (düzenleme seçenekleri kapanır) |
| **Çıktı ISO** | *(ISO modunda)* Oluşacak ISO'nun yolu. Seçilen sürüme göre otomatik adlandırılır (ör. `Win11-Pro-Custom.iso`) |
| **USB disk** | *(USB modunda)* Yazılacak disk. Varsayılan olarak sadece USB/SD bağlantılı diskler listelenir; **Tüm diskler** işaretlenirse dahili diskler (SATA, NVMe vb.) de görünür. Yeni takılan disk için **Yenile** |
| **Çalışma dizini** | Geçici dosyalar (varsayılan `C:\WindowsIsoBuild`). Her çalıştırmada temizlenir |
| **Sürüm** | ISO'daki sürümlerden biri; varsayılan olarak *Pro* seçilir. ISO'ya yalnızca bu sürüm konur |
| **Kullanıcı adı / Şifre** | Otomatik oluşturulacak yerel yönetici hesabı (şifre en az 4 karakter) |
| **Dil** | Kurulum ve sistem dili (ör. `tr-TR`, `en-US`) |
| **Gereksiz uygulamaları kaldır** | Aşağıdaki temizlik adımlarını açar/kapatır |
| **Otomatik kurulum** | `autounattend.xml` ekler |
| **Windows özellikleri** | ISO'da hazır açık gelecek isteğe bağlı özellikler |

Ana düğme seçime göre **ISO OLUŞTUR** veya **USB'YE YAZ** olur. İşlem sırasında ilerleme alttaki log alanında canlı görünür; **İptal** ile durdurulabilir. Tam log: `%TEMP%\WindowsIsoBuilder-build.log`

---

## Özellikler

### Sürücüler
- VirtIO ISO'dan Windows 11 (yoksa Windows 10) amd64 sürücüleri alınır: `viostor`, `vioscsi`, `NetKVM`, `Balloon`, `vioserial`, `vioinput`, `viorng`, `pvpanic`, `viofs`, `viogpudo`, `qxldod`, `fwcfg`, `smbus`
- Sürücüler hem **kurulum ortamına** (`boot.wim` — disk ve ağ kurulumda görünür) hem de **kurulu sisteme** (`install.wim`) eklenir
- VirtIO paketindeki MSI'lar (guest agent dahil) ISO içinde `\virtio\` klasörüne kopyalanır
- Ek sürücü klasörü verilirse onun sürücüleri de eklenir

### Donanım kontrolleri
- TPM, Secure Boot, RAM, CPU ve depolama kontrolleri atlanır — Windows 11 desteklenmeyen donanıma / TPM'siz VM'e kurulabilir
- İnternet / Microsoft hesabı zorunluluğu kaldırılır (`BypassNRO`)

### Windows 10 desteği
- Win10 ISO'larında ürün anahtarı sorulmadan kurulum devam eder (`ei.cfg`)
- Win10'a özel ek özellikler listelenir: Internet Explorer 11, Windows Media Player, Windows Faks ve Tarama

### Windows özellikleri (isteğe bağlı)
.NET Framework 3.5, Hyper-V, Windows Sandbox, Sanal Makine Platformu, WSL, Telnet, TFTP, IIS, DirectPlay, SMB 1.0, XPS Yazıcı, Microsoft Print to PDF, Internet Yazdırma, İş Klasörleri.
Varsayılan seçili: **.NET Framework 3.5** ve **Microsoft Print to PDF**.

### Gereksiz uygulama temizliği
*("Gereksiz uygulamaları kaldır" işaretliyse)*
- Kaldırılan uygulamalar: Xbox uygulamaları, Teams, Outlook (yeni), Copilot, Clipchamp, Bing Haberler/Hava/Arama, Office Hub, Solitaire, Kişiler, Power Automate, To Do, Geri Bildirim Merkezi, Haritalar, Telefon Bağlantısı, Groove/Filmler, Dev Home, Cortana, Hızlı Yardım, Alarmlar, Yapışkan Notlar ve Win10'a özel Skype, 3D Viewer, Paint 3D, Mixed Reality vb.
- **OneDrive** kaldırılır ve yeniden kurulması engellenir
- **Başlat menüsü** (Win11): tanıtım sabitlemeleri yerine Ayarlar, Dosya Gezgini, Edge, Hesap Makinesi, Not Defteri, Terminal, Fotoğraflar, Ekran Alıntısı Aracı, Denetim Masası
- **Başlat menüsü** (Win10): kutucuksuz, boş düzen
- **Görev çubuğu**: yalnızca Dosya Gezgini ve Edge sabitli

### Gizlilik ve reklamlar
- Telemetri, hata raporlama, CEIP, reklam kimliği kapalı
- Başlat menüsü önerileri, kilit ekranı reklamları, otomatik uygulama kurulumu kapalı
- Windows Copilot, Haberler ve İlgi Alanları / Widget'lar, arama kutusu önerileri kapalı
- Windows Spotlight kapalı

### Masaüstü ve görev çubuğu
- Görev çubuğu **sola** hizalı; arama kutusu, Görev Görünümü, Widget ve Copilot düğmeleri gizli
- Masaüstünde **Bu Bilgisayar** ve **kullanıcı klasörü** simgeleri
- Dosya Gezgini **Bu Bilgisayar** ile açılır
- Başlat menüsünde "En son kullanılanlar" kapalı
- Print Screen tuşu Ekran Alıntısı Aracını açmaz
- Ekran koruyucu kapalı, varsayılan Windows duvar kağıdı
- Bu ayarlar her yeni kullanıcının ilk oturumunda da uygulanır (Active Setup)

### Microsoft Edge
İlk çalışma turu, oturum açma / senkronizasyon dayatması, "varsayılan tarayıcı yap" uyarıları, alışveriş asistanı, kenar çubuğu, yeni sekme içerikleri, arka planda çalışma ve telemetri kapalı.

### Güç ve klavye
- Hazırda bekletme ve **Hızlı Başlatma** kapalı
- Uyku, ekran kapanma ve disk kapanma: **hiçbir zaman**
- **NumLock**, giriş ekranında ve oturumlarda **açık** başlar

### Otomatik kurulum (`autounattend.xml`)
*("Otomatik kurulum" işaretliyse)*
- Dil, klavye ve bölge seçilen dile göre ayarlanır; saat dilimi **Türkiye**
- Lisans sözleşmesi, çevrimiçi hesap ve kablosuz ağ ekranları atlanır
- Belirtilen kullanıcı adı ve şifreyle **yerel yönetici hesabı** oluşturulur
- Gizlilik ayarları ekranı sorulmaz (tümü kapalı)
- Kurulum sırasında güncelleme indirilmez
- **Disk seçimi elle yapılır** — hangi diske kurulacağı kurulumda sorulur

### USB'ye yazma
- Disk **tamamen silinir**, yazmadan önce disk adı ve boyutuyla onay istenir (varsayılan cevap *Hayır*)
- Windows'un kurulu olduğu disk listede **hiçbir durumda görünmez**; dahili diskler sadece **Tüm diskler** işaretliyse görünür ve onay mesajında ayrıca uyarılır
- Kaynak ISO'nun veya çalışma dizininin bulunduğu diske yazılamaz (yazma sırasında silineceği için)
- Seçimden sonra disk değişirse (çıkarılıp başka disk takılırsa) yazma iptal edilir
- Düzen: **MBR + tek FAT32 bölüm** → hem **UEFI** (Secure Boot açıkken de) hem **eski BIOS** bilgisayarlarda açılır
- 4 GB'tan büyük `install.wim`, FAT32 sınırı nedeniyle otomatik olarak `install.swm` parçalarına bölünür (Windows Kurulumu bunu destekler)
- Windows FAT32'yi en fazla 32 GB biçimlendirebildiği için 32 GB'tan büyük disklerde bölüm 32 GB olur, kalan alan boş (bölümsüz) kalır
- USB NVMe kutuları ve harici SSD'ler de desteklenir
- Rufus'tan farkı: ISO'daki `autounattend.xml` korunur, ek önyükleyici (UEFI:NTFS) gerekmez

---

## Proxmox VM önerisi

| Ayar | Değer |
|---|---|
| BIOS | OVMF (UEFI) + EFI disk |
| TPM | Gerekmez |
| Disk | VirtIO SCSI |
| Ağ | VirtIO |

Kurulumdan sonra ISO içindeki `\virtio\` klasöründen **guest agent** MSI'ını kurun.

---

## Notlar

- Otomatik kurulumdaki şifre ISO içindeki `autounattend.xml` dosyasında **düz metin** olarak durur. ISO'yu paylaşacaksanız kurulumdan sonra şifreyi değiştirin.
- Varsayılan kullanıcı `Inversa`, şifre `1234` — arayüzden değiştirin.
- USB'ye yazma yarıda kesilirse disk kullanılamaz durumda kalabilir; yazmayı tekrar başlatmanız yeterlidir.
- Bir işlem yarıda kalırsa (iptal, elektrik kesintisi vb.) bir sonraki çalıştırmada eski bağlantılar otomatik temizlenir. Temizlenemezse yönetici komut isteminde `dism /cleanup-wim` çalıştırıp çalışma dizinini silin veya bilgisayarı yeniden başlatın.
- Arayüzsüz kullanım: program çalışırken motor `%TEMP%\Build-WindowsIso.ps1` olarak yazılır; bu dosya parametrelerle doğrudan da çalıştırılabilir:
  ```powershell
  .\Build-WindowsIso.ps1 -WindowsIso C:\iso\Win11.iso -VirtioIso C:\iso\virtio-win.iso `
      -OutputIso C:\iso\Win11-Proxmox.iso -Edition "Windows 11 Pro" -UserName Kullanici -Password "Sifre123" `
      -Features NetFx3 [-KeepBloat] [-SkipUnattend]
  ```
  USB'ye yazma parametreleri (`-Target Usb`, `-WriteOnly`, `-UsbDisk`, `-UsbDiskSig`) disk doğrulaması gerektirdiği için arayüzden kullanılması önerilir.

---

## Lisans

[MIT](LICENSE) — kişisel ve ticari projelerde, açık veya kapalı kaynak olarak serbestçe kullanılabilir, değiştirilebilir ve dağıtılabilir. Tek şart, telif ve lisans notunun korunmasıdır. Yazılım "olduğu gibi" sunulur; disk silme işlemleri dahil kullanımdan doğacak sonuçlardan yazarlar sorumlu değildir.
