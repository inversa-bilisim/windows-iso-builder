<#
    Windows ISO Builder (10 / 11) - tek dosya surum / single-file version
    Dogrudan: powershell -ExecutionPolicy Bypass -File .\WindowsIsoBuilder.ps1
    EXE icin: Build-EXE.cmd
#>
$BuilderSource = @'
<#
.SYNOPSIS
    Windows 10/11 ISO'sunu özelleştirir: VirtIO / ek sürücüleri enjekte eder,
    gereksiz paketleri kaldırır, TPM/online hesap kontrollerini atlatan autounattend ekler,
    sonucu yeni bir ISO olarak ya da doğrudan USB kurulum diski olarak yazar.

.EXAMPLE
    .\Build-WindowsIso.ps1 -WindowsIso C:\iso\Win11.iso -VirtioIso C:\iso\virtio-win.iso `
        -OutputIso C:\iso\Win11-Proxmox.iso -Edition "Windows 11 Pro" -UserName Inversa -Password "1234"

.EXAMPLE
    # ISO yerine dogrudan USB diske yaz (Disk numarasi ve imzasi arayuzden gelir)
    .\Build-WindowsIso.ps1 -WindowsIso C:\iso\Win11.iso -Target Usb -UsbDisk 2 -UsbDiskSig "<ad>|<boyut>|<seri>"
    # Hazir ISO'yu degistirmeden USB'ye yaz
    .\Build-WindowsIso.ps1 -WindowsIso C:\iso\Win11.iso -WriteOnly -UsbDisk 2 -UsbDiskSig "<ad>|<boyut>|<seri>"

.NOTES
    Gereksinimler: Windows 10/11, yönetici hakları, Windows ADK "Deployment Tools" (oscdimg, sadece ISO çıktısı için).
    Çalışma süresi disk hızına göre 20-40 dakika. WorkDir için ~15 GB boş alan gerekir.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string]$WindowsIso,
    [string]$VirtioIso = "",
    [string]$DriverDir = "",
    [string]$OutputIso = "",
    [ValidateSet("Iso","Usb")] [string]$Target = "Iso",
    [int]$UsbDisk = -1,
    [string]$UsbDiskSig = "",
    [switch]$AllowAnyDisk,
    [switch]$WriteOnly,
    [string]$Edition  = "Windows 11 Pro",
    [string]$WorkDir  = "C:\WindowsIsoBuild",
    [string]$UserName = "Inversa",
    [string]$Password = "1234",
    [string]$Language = "tr-TR",
    [string[]]$Features = @(),
    [switch]$KeepBloat,
    [switch]$SkipUnattend
)

$ErrorActionPreference = "Stop"
$script:Mounted = @()

function Log($msg) { Write-Host ("[{0}] {1}" -f (Get-Date -Format HH:mm:ss), $msg) -ForegroundColor Cyan }

# Yerel komutlari (reg, takeown, icacls, oscdimg) EAP'den bagimsiz calistirir; stderr hata sayilmaz, cikis koduna bakilir
function Invoke-Native {
    param([string]$Exe, [string[]]$Arguments, [switch]$IgnoreFailure)
    $prev = $ErrorActionPreference; $ErrorActionPreference = "Continue"
    $out = & $Exe @Arguments 2>&1 | ForEach-Object { "$_" }
    $rc = $LASTEXITCODE
    $ErrorActionPreference = $prev
    if ($rc -ne 0 -and -not $IgnoreFailure) {
        throw ("{0} {1} -> kod {2}: {3}" -f $Exe, ($Arguments -join ' '), $rc, (($out | Where-Object { $_ -match '\S' }) -join ' | '))
    }
    return $out
}
function Reg      { param([string[]]$a) Invoke-Native reg.exe $a | Out-Null }
function RegQuiet { param([string[]]$a) Invoke-Native reg.exe $a -IgnoreFailure | Out-Null }

function Find-Oscdimg {
    $candidates = @(
        "${env:ProgramFiles(x86)}\Windows Kits\10\Assessment and Deployment Kit\Deployment Tools\amd64\Oscdimg\oscdimg.exe",
        "${env:ProgramFiles}\Windows Kits\10\Assessment and Deployment Kit\Deployment Tools\amd64\Oscdimg\oscdimg.exe"
    )
    foreach ($c in $candidates) { if (Test-Path $c) { return $c } }
    $cmd = Get-Command oscdimg.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    throw "oscdimg.exe bulunamadi. Windows ADK -> Deployment Tools bilesenini kurun."
}

function Mount-Iso($path) {
    $img = Mount-DiskImage -ImagePath $path -PassThru
    $script:Mounted += $path
    $letter = ($img | Get-Volume).DriveLetter
    if (-not $letter) { throw "ISO mount edilemedi: $path" }
    return "${letter}:"
}

function Cleanup {
    [GC]::Collect()
    foreach ($h in "HKLM\INSTSW","HKLM\INSTSYS","HKLM\INSTDEF","HKLM\INSTNTU","HKLM\BOOTSYS") { RegQuiet @("unload", $h) }
    foreach ($p in $script:Mounted) { Dismount-DiskImage -ImagePath $p -ErrorAction SilentlyContinue | Out-Null }
    $mountedNow = @(Get-WindowsImage -Mounted -ErrorAction SilentlyContinue | ForEach-Object { $_.Path })
    foreach ($m in @("$WorkDir\mount\install", "$WorkDir\mount\boot")) {
        if ($mountedNow -contains $m) { Dismount-WindowsImage -Path $m -Discard -ErrorAction SilentlyContinue | Out-Null }
    }
}

# Disk kimligi: arayuzde secilen disk ile yazilacak diskin ayni oldugunu dogrulamak icin
function Get-DiskSig($d) { "{0}|{1}|{2}" -f $d.FriendlyName, $d.Size, "$($d.SerialNumber)".Trim() }

# Kurulum dosyalarini USB diske yazar: MBR + tek FAT32 bolum (UEFI + Legacy BIOS, Secure Boot uyumlu).
# FAT32'ye sigmayan (4 GB ustu) install.wim, install.swm parcalarina bolunur; Windows Setup bunu destekler.
function Write-Usb([string]$SourceDir) {
    $src = $SourceDir.TrimEnd('\'); if ($src -match '^[A-Za-z]:$') { $src += '\' }
    $disk = Get-Disk -Number $UsbDisk -ErrorAction Stop
    if ((Get-DiskSig $disk) -ne $UsbDiskSig) { throw "Disk $UsbDisk secildikten sonra degismis (cikarilip takilmis olabilir). Listeyi yenileyip tekrar secin." }
    if ($disk.IsBoot -or $disk.IsSystem) { throw "Disk $UsbDisk Windows'un kurulu oldugu disk; yazma iptal edildi." }
    if (-not $AllowAnyDisk -and $disk.BusType -notin @("USB","SD","MMC")) { throw "Disk $UsbDisk USB disk degil ($($disk.BusType)); yazma iptal edildi." }

    # Silmeden once: FAT32 dosya siniri ve boyut kontrolu
    $files = @(Get-ChildItem $src -Recurse -File -Force)
    $big = @($files | Where-Object { $_.Length -ge 4GB -and $_.Name -ne "install.wim" })
    if ($big.Count -gt 0) { throw "FAT32'ye sigmayan dosya (4 GB ustu, bolunemez): $($big[0].FullName)" }
    $total = ($files | Measure-Object Length -Sum).Sum + 200MB
    # Windows FAT32'yi en fazla 32 GB bicimlendirir; buyuk diskte kalan alan bos birakilir
    $diskMB = [Math]::Floor($disk.Size / 1MB)
    $sizeArg = if ($diskMB -gt 32100) { " size=32000" } else { "" }
    $partMB = if ($sizeArg) { 32000 } else { $diskMB - 8 }
    if ($total -gt $partMB * 1MB) { throw ("USB disk yetersiz: {0:N1} GB gerekli, disk {1:N1} GB" -f ($total / 1GB), ($disk.Size / 1GB)) }

    # DISM salt-okunur kaynaktan (bagli ISO) bolme yapamiyor (erisim engellendi):
    # hazir ISO yazilirken install.wim once calisma dizinine kopyalanir, oradan bolunur
    $wim = Join-Path $src "sources\install.wim"
    $needSplit = (Test-Path $wim) -and (Get-Item $wim).Length -ge 4GB
    $splitDir = Join-Path $WorkDir "split"
    if ($needSplit -and $WriteOnly) {
        $root = Split-Path -Qualifier ([System.IO.Path]::GetFullPath($WorkDir))
        $free = ([System.IO.DriveInfo]::new($root)).AvailableFreeSpace
        $need = (Get-Item $wim).Length + 500MB
        if ($free -lt $need) { throw ("Calisma dizini surucusunde ({0}) yer yetersiz: install.wim'i bolmek icin {1:N1} GB gerekli, bos {2:N1} GB" -f $root, ($need / 1GB), ($free / 1GB)) }
    }

    Log ("USB disk siliniyor ve hazirlaniyor: Disk {0} - {1} ({2:N1} GB)" -f $disk.Number, $disk.FriendlyName, ($disk.Size / 1GB))
    # Diskteki acik birimleri birak (Gezgin vb. kilitlemesin); cikarilabilir medyada desteklenmez, sorun degil
    try { Set-Disk -Number $disk.Number -IsOffline $true -ErrorAction Stop; Set-Disk -Number $disk.Number -IsOffline $false -ErrorAction Stop } catch { }
    $dp = Join-Path $env:TEMP "WindowsIsoBuilder-diskpart.txt"
    @(
        "select disk $($disk.Number)",
        "attributes disk clear readonly noerr",
        "online disk noerr",
        "clean",
        "convert mbr",
        "create partition primary$sizeArg",
        "format fs=fat32 quick label=WINSETUP",
        "active",
        "assign",
        "exit"
    ) | Set-Content -Path $dp -Encoding ASCII
    Invoke-Native diskpart.exe @("/s", $dp) | Out-Null
    Remove-Item $dp -Force -ErrorAction SilentlyContinue

    $usb = $null
    for ($i = 0; $i -lt 30 -and -not $usb; $i++) {
        Start-Sleep -Seconds 1
        Update-HostStorageCache -ErrorAction SilentlyContinue
        $l = (Get-Partition -DiskNumber $disk.Number -ErrorAction SilentlyContinue |
              Where-Object { "$($_.DriveLetter)" -match '^[A-Za-z]$' } | Select-Object -First 1).DriveLetter
        if ($l) { $usb = "${l}:" }
    }
    if (-not $usb) { throw "USB bolumune surucu harfi atanamadi." }

    Log "Dosyalar USB'ye kopyalaniyor ($usb) ..."
    $prev = $ErrorActionPreference; $ErrorActionPreference = "Continue"
    robocopy $src "$usb\" /E /XF install.wim /R:1 /W:1 /NFL /NDL /NJH /NJS /NC /NS /NP | Out-Null
    $rc = $LASTEXITCODE; $ErrorActionPreference = $prev
    if ($rc -ge 8) { throw "USB'ye kopyalama hatasi (robocopy kod $rc)" }

    if (Test-Path $wim) {
        if ($needSplit) {
            $splitSrc = $wim
            if ($WriteOnly) {
                Log "install.wim bolmek icin calisma dizinine kopyalaniyor ..."
                $null = New-Item -ItemType Directory -Path $splitDir -Force
                Copy-Item $wim $splitDir -Force
                $splitSrc = Join-Path $splitDir "install.wim"
            }
            (Get-Item $splitSrc).IsReadOnly = $false
            Log "install.wim 4 GB'tan buyuk, FAT32 icin parcalara bolunuyor ..."
            Split-WindowsImage -ImagePath $splitSrc -SplitImagePath "$usb\sources\install.swm" -FileSize 3800 | Out-Null
            if ($WriteOnly) { Remove-Item $splitDir -Recurse -Force -ErrorAction SilentlyContinue }
        } else {
            Log "install.wim kopyalaniyor ..."
            Copy-Item $wim "$usb\sources\install.wim" -Force
        }
    }

    # Legacy BIOS acilisi icin boot kodu (UEFI bunu kullanmaz)
    $bs = Join-Path $src "boot\bootsect.exe"
    if (Test-Path $bs) {
        Invoke-Native $bs @("/nt60", $usb, "/mbr", "/force") -IgnoreFailure | Out-Null
        if ($LASTEXITCODE -ne 0) { Write-Warning "bootsect basarisiz: Legacy BIOS acilisi calismayabilir (UEFI etkilenmez)." }
    }
    Log ("Tamamlandi. USB disk hazir: {0} (Disk {1} - {2})" -f $usb, $disk.Number, $disk.FriendlyName)
}

try {
    if ($Target -eq "Usb" -or $WriteOnly) {
        if ($UsbDisk -lt 0 -or -not $UsbDiskSig) { throw "USB disk belirtilmedi (-UsbDisk / -UsbDiskSig)." }
    } elseif (-not $OutputIso) { throw "-OutputIso belirtilmedi." }

    # Hazir ISO'yu degistirmeden USB'ye yaz
    if ($WriteOnly) {
        $src = Mount-Iso $WindowsIso
        Write-Usb "$src\"
        return
    }

    if ($Target -eq "Iso") {
        $oscdimg = Find-Oscdimg
        Log "oscdimg: $oscdimg"
    }

    # --- Çalışma dizini (önceki yarım kalmış build'in mount kalıntılarını temizle) ---
    if (Test-Path $WorkDir) {
        $stale = @(Get-WindowsImage -Mounted -ErrorAction SilentlyContinue | Where-Object { $_.Path -like "$WorkDir*" })
        if ($stale.Count -gt 0) {
            Log "Onceki build'den kalan $($stale.Count) mount temizleniyor ..."
            foreach ($m in $stale) { Dismount-WindowsImage -Path $m.Path -Discard -ErrorAction SilentlyContinue | Out-Null }
            Invoke-Native dism.exe @("/cleanup-wim") -IgnoreFailure | Out-Null
        }
        Remove-Item $WorkDir -Recurse -Force -ErrorAction SilentlyContinue
        if (Test-Path $WorkDir) { throw "Calisma dizini silinemedi: $WorkDir - bilgisayari yeniden baslatip tekrar deneyin." }
    }
    $isoDir   = "$WorkDir\iso"
    $drvDir   = "$WorkDir\drivers"
    $mntInst  = "$WorkDir\mount\install"
    $mntBoot  = "$WorkDir\mount\boot"
    $null = New-Item -ItemType Directory -Path $isoDir, $drvDir, $mntInst, $mntBoot -Force

    # --- Windows ISO içeriğini kopyala ---
    $win = Mount-Iso $WindowsIso
    Log "Windows ISO kopyalaniyor ($win) ..."
    robocopy "$win\" $isoDir /E /NFL /NDL /NJH /NJS /NC /NS | Out-Null
    Get-ChildItem $isoDir -Recurse | ForEach-Object { $_.Attributes = 'Normal' }
    Dismount-DiskImage -ImagePath $WindowsIso | Out-Null
    $script:Mounted = $script:Mounted | Where-Object { $_ -ne $WindowsIso }

    # --- VirtIO sürücülerini topla (w11/amd64) - isteğe bağlı ---
    $haveDrivers = $false
    if ($VirtioIso -and (Test-Path $VirtioIso)) {
        $vio = Mount-Iso $VirtioIso
        Log "VirtIO surucuileri toplaniyor ($vio) ..."
        $wanted = @("viostor","vioscsi","NetKVM","Balloon","vioserial","vioinput","viorng","pvpanic","viofs","viogpudo","qxldod","fwcfg","smbus")
        foreach ($d in $wanted) {
            $src = @("$vio\$d\w11\amd64", "$vio\$d\w10\amd64") | Where-Object { Test-Path $_ } | Select-Object -First 1
            if ($src) {
                $null = New-Item -ItemType Directory -Path "$drvDir\$d" -Force
                Copy-Item "$src\*" "$drvDir\$d" -Recurse -Force
            }
        }
        # Guest agent ve sürücü paketi MSI'larını da ISO'ya koy (kurulumdan sonra elle kurmak için)
        $null = New-Item -ItemType Directory -Path "$isoDir\virtio" -Force
        Get-ChildItem "$vio\*.msi","$vio\guest-agent\*.msi" -ErrorAction SilentlyContinue | Copy-Item -Destination "$isoDir\virtio" -Force
        Dismount-DiskImage -ImagePath $VirtioIso | Out-Null
        $script:Mounted = @()
        Log ("{0} surucu klasoru hazir." -f (Get-ChildItem $drvDir -Directory).Count)
        $haveDrivers = (Get-ChildItem $drvDir -Directory).Count -gt 0
    } else {
        Log "VirtIO ISO verilmedi."
    }

    # --- Ek sürücü klasörü (herhangi .inf tabanlı sürücü) ---
    if ($DriverDir -and (Test-Path $DriverDir)) {
        $infCount = (Get-ChildItem $DriverDir -Recurse -Filter *.inf).Count
        if ($infCount -gt 0) {
            Log "Ek surucu klasoru: $DriverDir ($infCount .inf)"
            $null = New-Item -ItemType Directory -Path "$drvDir\_extra" -Force
            Copy-Item "$DriverDir\*" "$drvDir\_extra" -Recurse -Force
            $haveDrivers = $true
        } else {
            Write-Warning "Surucu klasorunde .inf dosyasi yok, atlaniyor: $DriverDir"
        }
    }
    if (-not $haveDrivers) { Log "Surucu enjeksiyonu atlaniyor." }

    # --- install.esd ise wim'e çevir, istenen sürümü seç ---
    $sources = "$isoDir\sources"
    if (Test-Path "$sources\install.esd") {
        Log "install.esd -> install.wim donusturuluyor (uzun surebilir) ..."
        $idx = (Get-WindowsImage -ImagePath "$sources\install.esd" | Where-Object ImageName -eq $Edition).ImageIndex
        if (-not $idx) { throw "'$Edition' install.esd icinde bulunamadi. Mevcutlar: $((Get-WindowsImage -ImagePath "$sources\install.esd").ImageName -join ', ')" }
        Export-WindowsImage -SourceImagePath "$sources\install.esd" -SourceIndex $idx `
            -DestinationImagePath "$sources\install.wim" -CompressionType Max | Out-Null
        Remove-Item "$sources\install.esd" -Force
    } else {
        $all = Get-WindowsImage -ImagePath "$sources\install.wim"
        $idx = ($all | Where-Object ImageName -eq $Edition).ImageIndex
        if (-not $idx) { throw "'$Edition' install.wim icinde bulunamadi. Mevcutlar: $($all.ImageName -join ', ')" }
        if ($all.Count -gt 1) {
            Log "Sadece '$Edition' export ediliyor ..."
            Export-WindowsImage -SourceImagePath "$sources\install.wim" -SourceIndex $idx `
                -DestinationImagePath "$sources\install_single.wim" -CompressionType Max | Out-Null
            Remove-Item "$sources\install.wim" -Force
            Rename-Item "$sources\install_single.wim" "install.wim"
        }
    }

    # --- Windows 10 / 11 algılama (build 22000 ve üstü = Windows 11) ---
    $imgInfo = Get-WindowsImage -ImagePath "$sources\install.wim" -Index 1
    $build   = [int]($imgInfo.Version -split '\.')[2]
    $isWin11 = $build -ge 22000
    $osLabel = if ($isWin11) { "Windows 11" } else { "Windows 10" }
    Log "Algilanan: $osLabel (build $build, $($imgInfo.ImageName))"
    if (-not $isWin11) {
        # Win10 kurulumu urun anahtari ister; ei.cfg ile anahtarsiz, imajdaki surumle devam eder
        Set-Content -Path "$sources\ei.cfg" -Value "[Channel]`r`nRetail`r`n[VL]`r`n0" -Encoding ASCII
        Remove-Item "$sources\pid.txt" -Force -ErrorAction SilentlyContinue
    }

    # --- boot.wim: kurulum ortamına disk/ağ sürücüleri ---
    foreach ($bi in 1, 2) {
        Log "boot.wim index $bi mount ediliyor ..."
        Mount-WindowsImage -ImagePath "$sources\boot.wim" -Index $bi -Path $mntBoot | Out-Null
        if ($haveDrivers) { Add-WindowsDriver -Path $mntBoot -Driver $drvDir -Recurse -ForceUnsigned | Out-Null }
        if ($bi -eq 2) {
            # Setup ortamında TPM/SecureBoot/RAM kontrollerini atla
            Reg @("load", "HKLM\BOOTSYS", "$mntBoot\Windows\System32\config\SYSTEM")
            foreach ($k in "BypassTPMCheck","BypassSecureBootCheck","BypassRAMCheck","BypassCPUCheck","BypassStorageCheck") {
                Reg @("add", "HKLM\BOOTSYS\Setup\LabConfig", "/v", $k, "/t", "REG_DWORD", "/d", "1", "/f")
            }
            [GC]::Collect(); Reg @("unload", "HKLM\BOOTSYS")
        }
        Log "boot.wim index $bi kaydediliyor ..."
        Dismount-WindowsImage -Path $mntBoot -Save | Out-Null
    }

    # --- install.wim: sürücüler, bloat temizliği, OOBE ayarları ---
    Log "install.wim mount ediliyor ..."
    Mount-WindowsImage -ImagePath "$sources\install.wim" -Index 1 -Path $mntInst | Out-Null
    if ($haveDrivers) { Add-WindowsDriver -Path $mntInst -Driver $drvDir -Recurse -ForceUnsigned | Out-Null }

    if ($Features.Count -gt 0) {
        Log "Windows ozellikleri etkinlestiriliyor: $($Features -join ', ')"
        $sxs = "$sources\sxs"
        foreach ($f in $Features) {
            try {
                if (Test-Path $sxs) {
                    Enable-WindowsOptionalFeature -Path $mntInst -FeatureName $f -All -Source $sxs -LimitAccess -NoRestart | Out-Null
                } else {
                    Enable-WindowsOptionalFeature -Path $mntInst -FeatureName $f -All -NoRestart | Out-Null
                }
                Log "  + $f"
            } catch { Write-Warning "Ozellik etkinlestirilemedi: $f -> $_" }
        }
    }

    if (-not $KeepBloat) {
        Log "Gereksiz uygulamalar kaldiriliyor ..."
        $bloat = @(
            "Clipchamp.Clipchamp","Microsoft.BingNews","Microsoft.BingWeather","Microsoft.GamingApp",
            "Microsoft.GetHelp","Microsoft.Getstarted","Microsoft.MicrosoftOfficeHub","Microsoft.MicrosoftSolitaireCollection",
            "Microsoft.People","Microsoft.PowerAutomateDesktop","Microsoft.Todos","Microsoft.WindowsFeedbackHub",
            "Microsoft.WindowsMaps","Microsoft.Xbox.TCUI","Microsoft.XboxGameOverlay","Microsoft.XboxGamingOverlay",
            "Microsoft.XboxIdentityProvider","Microsoft.XboxSpeechToTextOverlay","Microsoft.YourPhone",
            "Microsoft.ZuneMusic","Microsoft.ZuneVideo","MicrosoftTeams","MSTeams","Microsoft.OutlookForWindows",
            "Microsoft.Windows.DevHome","Microsoft.549981C3F5F10","MicrosoftCorporationII.QuickAssist",
            "Microsoft.Copilot","MicrosoftWindows.Client.WebExperience","Microsoft.Windows.Ai.Copilot.Provider",
            "Microsoft.Windows.Getstarted","MicrosoftWindows.Client.Getstarted","Microsoft.BingSearch","Microsoft.WindowsAlarms",
            "Microsoft.MicrosoftStickyNotes","Microsoft.Wallet",
            # Windows 10'a ozel paketler (Win11'de yoksa sessizce atlanir)
            "Microsoft.SkypeApp","Microsoft.MSPaint","Microsoft.Microsoft3DViewer","Microsoft.Print3D","Microsoft.3DBuilder",
            "Microsoft.MixedReality.Portal","Microsoft.Office.OneNote","Microsoft.Messaging","Microsoft.OneConnect",
            "Microsoft.XboxApp","Microsoft.WindowsCamera","Microsoft.Windows.Cortana"
        )
        $prov = Get-AppxProvisionedPackage -Path $mntInst
        foreach ($p in $prov) {
            if ($bloat -contains $p.DisplayName) {
                try { Remove-AppxProvisionedPackage -Path $mntInst -PackageName $p.PackageName | Out-Null }
                catch { Write-Warning "Kaldirilamadi: $($p.DisplayName)" }
            }
        }
    }

    Log "OOBE / registry ayarlari ..."
    Reg @("load", "HKLM\INSTSW",  "$mntInst\Windows\System32\config\SOFTWARE")
    Reg @("load", "HKLM\INSTSYS", "$mntInst\Windows\System32\config\SYSTEM")
    Reg @("load", "HKLM\INSTDEF", "$mntInst\Windows\System32\config\DEFAULT")
    Reg @("load", "HKLM\INSTNTU", "$mntInst\Users\Default\NTUSER.DAT")

    function RegSet($key, $name, $value, $type = "REG_DWORD") { Reg @("add", $key, "/v", $name, "/t", $type, "/d", "$value", "/f") }
    # Kullanici profili tercihleri: bazi anahtarlar (Explorer\Advanced) Win11 imajinda kilitli, yazilamazsa uyar ve gec
    function RegSetSoft($key, $name, $value, $type = "REG_DWORD") {
        try { RegSet $key $name $value $type } catch { Write-Warning ("Atlandi (kilitli anahtar): {0}\{1}" -f $key, $name) }
    }

    # Kurulum / OOBE
    RegSet "HKLM\INSTSW\Microsoft\Windows\CurrentVersion\OOBE" BypassNRO 1
    RegSet "HKLM\INSTSYS\Setup\MoSetup" AllowUpgradesWithUnsupportedTPMOrCPU 1

    # Telemetri ve reklam/öneri sistemleri
    RegSet "HKLM\INSTSW\Policies\Microsoft\Windows\DataCollection" AllowTelemetry 0
    RegSet "HKLM\INSTSW\Policies\Microsoft\Windows\DataCollection" DoNotShowFeedbackNotifications 1
    RegSet "HKLM\INSTSW\Policies\Microsoft\Windows\CloudContent" DisableWindowsConsumerFeatures 1
    RegSet "HKLM\INSTSW\Policies\Microsoft\Windows\CloudContent" DisableTailoredExperiencesWithDiagnosticData 1
    RegSet "HKLM\INSTSW\Policies\Microsoft\Windows\CloudContent" DisableSoftLanding 1
    RegSet "HKLM\INSTSW\Policies\Microsoft\Windows\AdvertisingInfo" DisabledByGroupPolicy 1
    RegSet "HKLM\INSTSW\Policies\Microsoft\Windows\Windows Error Reporting" Disabled 1
    RegSet "HKLM\INSTSW\Policies\Microsoft\SQMClient\Windows" CEIPEnable 0
    RegSet "HKLM\INSTSW\Policies\Microsoft\Windows\WindowsCopilot" TurnOffWindowsCopilot 1
    RegSet "HKLM\INSTSW\Policies\Microsoft\Dsh" AllowNewsAndInterests 0
    RegSet "HKLM\INSTSW\Policies\Microsoft\Windows\Windows Feeds" EnableFeeds 0
    RegSet "HKLM\INSTSW\Policies\Microsoft\Windows\Explorer" HideSCAMeetNow 1
    RegSet "HKLM\INSTSW\Policies\Microsoft\Windows\Explorer" DisableSearchBoxSuggestions 1
    # Yeni kullanıcı profili varsayılanları (Start menüsü önerileri, reklam kimliği, hoş geldin deneyimi)
    foreach ($hive in "HKLM\INSTDEF", "HKLM\INSTNTU") {
        $cdm = "$hive\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager"
        foreach ($v in "SubscribedContent-338388Enabled","SubscribedContent-338389Enabled","SubscribedContent-310093Enabled",
                       "SubscribedContent-353694Enabled","SubscribedContent-353696Enabled","SystemPaneSuggestionsEnabled",
                       "SilentInstalledAppsEnabled","SoftLandingEnabled","RotatingLockScreenOverlayEnabled","OemPreInstalledAppsEnabled") {
            RegSetSoft $cdm $v 0
        }
        RegSetSoft "$hive\Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo" Enabled 0
        RegSetSoft "$hive\Software\Microsoft\Windows\CurrentVersion\Privacy" TailoredExperiencesWithDiagnosticDataEnabled 0
        RegSetSoft "$hive\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" ShowCopilotButton 0
        RegSetSoft "$hive\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" TaskbarDa 0
        RegSetSoft "$hive\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" Start_IrisRecommendations 0
        RegSetSoft "$hive\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" TaskbarAl 0
        RegSetSoft "$hive\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" LaunchTo 1
        RegSetSoft "$hive\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" ShowTaskViewButton 0
        RegSetSoft "$hive\Software\Microsoft\Windows\CurrentVersion\Search" SearchboxTaskbarMode 0
        RegSetSoft "$hive\Control Panel\Keyboard" PrintScreenKeyForSnippingEnabled 0
        RegSetSoft "$hive\Control Panel\Desktop" ScreenSaveActive 0 REG_SZ
        # Masaustu simgeleri: Bu Bilgisayar ve Kullanici Klasoru
        RegSetSoft "$hive\Software\Microsoft\Windows\CurrentVersion\Explorer\HideDesktopIcons\NewStartPanel" "{20D04FE0-3AEA-1069-A2D8-08002B30309D}" 0
        RegSetSoft "$hive\Software\Microsoft\Windows\CurrentVersion\Explorer\HideDesktopIcons\NewStartPanel" "{59031a47-3f72-44a7-89c5-5595fe6b30ee}" 0
    }
    # NumLock acik: giris ekrani (.DEFAULT) ve yeni kullanicilar icin
    # 2147483650 = 0x80000002, Win10/11 giris ekraninda NumLock'u acik tutan deger
    RegSet "HKLM\INSTDEF\Control Panel\Keyboard" InitialKeyboardIndicators 2147483650 REG_SZ
    RegSetSoft "HKLM\INSTNTU\Control Panel\Keyboard" InitialKeyboardIndicators 2 REG_SZ
    # Hizli baslatma kapali: acilista NumLock durumunu hazirda bekletme imajindan geri yukleyip kapatmasin
    RegSet "HKLM\INSTSYS\ControlSet001\Control\Session Manager\Power" HiberbootEnabled 0

    # Masaustu: Spotlight kapali, Windows Bloom duvar kagidi (unattend'de de ayarlanir)
    RegSet "HKLM\INSTSW\Policies\Microsoft\Windows\CloudContent" DisableSpotlightCollectionOnDesktop 1
    RegSet "HKLM\INSTSW\Policies\Microsoft\Windows\CloudContent" DisableWindowsSpotlightFeatures 1

    # Start menusu: tanitim sabitlemeleri (Outlook, Xbox, WhatsApp, LinkedIn...) yerine temiz liste (Win11 politikasi)
    if (-not $KeepBloat -and $isWin11) {
        Log "Start menusu sabitlemeleri temizleniyor ..."
        $pins = @{ pinnedList = @(
            @{ packagedAppId = "windows.immersivecontrolpanel_cw5n1h2txyewy!microsoft.windows.immersivecontrolpanel" },
            @{ desktopAppId  = "Microsoft.Windows.Explorer" },
            @{ desktopAppId  = "MSEdge" },
            @{ packagedAppId = "Microsoft.WindowsCalculator_8wekyb3d8bbwe!App" },
            @{ packagedAppId = "Microsoft.WindowsNotepad_8wekyb3d8bbwe!App" },
            @{ packagedAppId = "Microsoft.WindowsTerminal_8wekyb3d8bbwe!App" },
            @{ packagedAppId = "Microsoft.Windows.Photos_8wekyb3d8bbwe!App" },
            @{ packagedAppId = "Microsoft.ScreenSketch_8wekyb3d8bbwe!App" },
            @{ desktopAppId  = "Microsoft.Windows.ControlPanel" }
        ) } | ConvertTo-Json -Compress -Depth 4
        $pm = "HKLM:\INSTSW\Microsoft\PolicyManager\current\device\Start"
        $null = New-Item -Path $pm -Force
        New-ItemProperty -Path $pm -Name ConfigureStartPins -Value $pins -PropertyType String -Force | Out-Null
        New-ItemProperty -Path $pm -Name ConfigureStartPins_ProviderSet -Value 1 -PropertyType DWord -Force | Out-Null
        New-ItemProperty -Path $pm -Name ConfigureStartPins_WinningProvider -Value "B5292708-1619-419B-9923-E5D9F3925E71" -PropertyType String -Force | Out-Null
        $pp = "HKLM:\INSTSW\Microsoft\PolicyManager\providers\B5292708-1619-419B-9923-E5D9F3925E71\default\Device\Start"
        $null = New-Item -Path $pp -Force
        New-ItemProperty -Path $pp -Name ConfigureStartPins -Value $pins -PropertyType String -Force | Out-Null
        New-ItemProperty -Path $pp -Name ConfigureStartPins_LastWrite -Value 1 -PropertyType DWord -Force | Out-Null
        # Varsayilan profildeki hazir Start duzeni silinir; politika listesi devreye girer
        Remove-Item "$mntInst\Users\Default\AppData\Local\Packages\Microsoft.Windows.StartMenuExperienceHost_cw5n1h2txyewy\LocalState\start*.bin" -Force -ErrorAction SilentlyContinue
    }

    # Her kullanicinin ilk oturumunda bir kez calisan kullanici ayarlari (Active Setup)
    Log "Kullanici ayar scripti (Active Setup) yaziliyor ..."
    $null = New-Item -ItemType Directory -Path "$mntInst\Windows\Setup\Scripts" -Force
    $userCmd = @"
@echo off
rem Her kullanici icin ilk oturumda bir kez calisir (Active Setup)
set A=HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced
reg add "%A%" /v TaskbarAl /t REG_DWORD /d 0 /f >nul
reg add "%A%" /v TaskbarDa /t REG_DWORD /d 0 /f >nul
reg add "%A%" /v ShowCopilotButton /t REG_DWORD /d 0 /f >nul
reg add "%A%" /v Start_IrisRecommendations /t REG_DWORD /d 0 /f >nul
reg add "%A%" /v LaunchTo /t REG_DWORD /d 1 /f >nul
reg add "%A%" /v ShowTaskViewButton /t REG_DWORD /d 0 /f >nul
reg add "HKCU\Software\Microsoft\Windows\CurrentVersion\Search" /v SearchboxTaskbarMode /t REG_DWORD /d 0 /f >nul
rem Start "En son" bolumu kapali (Baslarken karti gorunmez)
reg add "%A%" /v Start_TrackDocs /t REG_DWORD /d 0 /f >nul
rem Windows 10: Cortana dugmesi, Haberler ve ilgi alanlari, Kisiler dugmesi kapali
reg add "%A%" /v ShowCortanaButton /t REG_DWORD /d 0 /f >nul
reg add "HKCU\Software\Microsoft\Windows\CurrentVersion\Feeds" /v ShellFeedsTaskbarViewMode /t REG_DWORD /d 2 /f >nul
reg add "HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced\People" /v PeopleBand /t REG_DWORD /d 0 /f >nul
reg add "HKCU\Control Panel\Keyboard" /v PrintScreenKeyForSnippingEnabled /t REG_DWORD /d 0 /f >nul
reg add "HKCU\Control Panel\Keyboard" /v InitialKeyboardIndicators /t REG_SZ /d 2 /f >nul
reg add "HKCU\Control Panel\Desktop" /v ScreenSaveActive /t REG_SZ /d 0 /f >nul
reg add "HKCU\Control Panel\Desktop" /v WallPaper /t REG_SZ /d "C:\Windows\Web\Wallpaper\Windows\img0.jpg" /f >nul
reg add "HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\HideDesktopIcons\NewStartPanel" /v {20D04FE0-3AEA-1069-A2D8-08002B30309D} /t REG_DWORD /d 0 /f >nul
reg add "HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\HideDesktopIcons\NewStartPanel" /v {59031a47-3f72-44a7-89c5-5595fe6b30ee} /t REG_DWORD /d 0 /f >nul
set C=HKCU\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager
for %%v in (SubscribedContent-338388Enabled SubscribedContent-338389Enabled SubscribedContent-310093Enabled SubscribedContent-353694Enabled SubscribedContent-353696Enabled SystemPaneSuggestionsEnabled SilentInstalledAppsEnabled SoftLandingEnabled RotatingLockScreenOverlayEnabled OemPreInstalledAppsEnabled) do reg add "%C%" /v %%v /t REG_DWORD /d 0 /f >nul
reg add "HKCU\Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo" /v Enabled /t REG_DWORD /d 0 /f >nul
reg add "HKCU\Software\Microsoft\Windows\CurrentVersion\Privacy" /v TailoredExperiencesWithDiagnosticDataEnabled /t REG_DWORD /d 0 /f >nul
rem Windows ilk oturumda bazi ayarlari (arama kutusu) sonradan eziyor; masaustu acildiktan sonra bir kez daha uygula
reg add "HKCU\Software\Microsoft\Windows\CurrentVersion\RunOnce" /v UserSetupFix /t REG_SZ /d "wscript.exe //B //Nologo C:\Windows\Setup\Scripts\UserSetupFix.vbs" /f >nul
exit /b 0
"@
    # Active Setup, Explorer baslamadan calisir: pencere gorunmesin diye VBS ile gizli baslatilir
    $userCmd = $userCmd -replace ' >nul', ' >nul 2>&1'
    Set-Content -Path "$mntInst\Windows\Setup\Scripts\UserSetup.cmd" -Value $userCmd -Encoding ASCII
    $userVbs = 'CreateObject("WScript.Shell").Run "cmd /c """C:\Windows\Setup\Scripts\UserSetup.cmd""", 0, True'
    Set-Content -Path "$mntInst\Windows\Setup\Scripts\UserSetup.vbs" -Value $userVbs -Encoding ASCII
    $userFix = @"
@echo off
rem Masaustu acildiktan 20 sn sonra: Windows'un ezdigi ayarlari tekrar uygula
timeout /t 20 /nobreak >nul
reg add "HKCU\Software\Microsoft\Windows\CurrentVersion\Search" /v SearchboxTaskbarMode /t REG_DWORD /d 0 /f >nul
reg add "HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" /v ShowTaskViewButton /t REG_DWORD /d 0 /f >nul
reg add "HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" /v TaskbarDa /t REG_DWORD /d 0 /f >nul
reg add "HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" /v Start_TrackDocs /t REG_DWORD /d 0 /f >nul
taskkill /f /im explorer.exe >nul 2>&1
start explorer.exe
"@
    $userFix = $userFix -replace '(?m) >nul\s*$', ' >nul 2>&1'
    Set-Content -Path "$mntInst\Windows\Setup\Scripts\UserSetupFix.cmd" -Value $userFix -Encoding ASCII
    $fixVbs = 'CreateObject("WScript.Shell").Run "cmd /c """C:\Windows\Setup\Scripts\UserSetupFix.cmd""", 0, False'
    Set-Content -Path "$mntInst\Windows\Setup\Scripts\UserSetupFix.vbs" -Value $fixVbs -Encoding ASCII
    $as = "HKLM\INSTSW\Microsoft\Active Setup\Installed Components\{7A1E6C0B-5D2F-4B9A-9C3E-0D4F8E2A6B17}"
    RegSet $as Version "1,0,0,0" REG_SZ
    RegSet $as StubPath 'wscript.exe //B //Nologo "C:\Windows\Setup\Scripts\UserSetup.vbs"' REG_SZ
    RegSet $as IsInstalled 1
    Reg @("add", $as, "/ve", "/t", "REG_SZ", "/d", "WindowsIsoBuilder Kullanici Ayarlari", "/f")

    # Gorev cubugu varsayilan sabitlemeleri: sadece Dosya Gezgini ve Edge (Outlook/Store stub'lari gelmez)
    if (-not $KeepBloat) {
        $shellDir = "$mntInst\Users\Default\AppData\Local\Microsoft\Windows\Shell"
        $null = New-Item -ItemType Directory -Path $shellDir -Force
        # Windows 10: kutucuksuz (bos) Start menusu; Windows 11'de Start politikayla ayarlanir
        $startBlock = ""
        if (-not $isWin11) {
            $startBlock = "  <LayoutOptions StartTileGroupCellWidth=`"6`" />`n  <DefaultLayoutOverride>`n    <StartLayoutCollection>`n      <defaultlayout:StartLayout GroupCellWidth=`"6`" />`n    </StartLayoutCollection>`n  </DefaultLayoutOverride>"
        }
        $layout = @"
<?xml version="1.0" encoding="utf-8"?>
<LayoutModificationTemplate
    xmlns="http://schemas.microsoft.com/Start/2014/LayoutModification"
    xmlns:defaultlayout="http://schemas.microsoft.com/Start/2014/FullDefaultLayout"
    xmlns:start="http://schemas.microsoft.com/Start/2014/StartLayout"
    xmlns:taskbar="http://schemas.microsoft.com/Start/2014/TaskbarLayout"
    Version="1">
$startBlock
  <CustomTaskbarLayoutCollection PinListPlacement="Replace">
    <defaultlayout:TaskbarLayout>
      <taskbar:TaskbarPinList>
        <taskbar:DesktopApp DesktopApplicationID="Microsoft.Windows.Explorer" />
        <taskbar:DesktopApp DesktopApplicationID="MSEdge" />
      </taskbar:TaskbarPinList>
    </defaultlayout:TaskbarLayout>
  </CustomTaskbarLayoutCollection>
</LayoutModificationTemplate>
"@
        Set-Content -Path "$shellDir\LayoutModification.xml" -Value $layout -Encoding UTF8
    }

    # Edge: ilk calisma turu, hesap/senkron dayatmasi, oneri ve "varsayilan yap" uyarilari kapali
    $edge = "HKLM\INSTSW\Policies\Microsoft\Edge"
    RegSet $edge HideFirstRunExperience 1
    RegSet $edge BrowserSignin 0
    RegSet $edge SyncDisabled 1
    RegSet $edge NonRemovableProfileEnabled 0
    RegSet $edge PersonalizationReportingEnabled 0
    RegSet $edge MetricsReportingEnabled 0
    RegSet $edge DiagnosticData 0
    RegSet $edge ShowRecommendationsEnabled 0
    RegSet $edge SpotlightExperiencesAndRecommendationsEnabled 0
    RegSet $edge DefaultBrowserSettingEnabled 0
    RegSet $edge DefaultBrowserSettingsCampaignEnabled 0
    RegSet $edge EdgeShoppingAssistantEnabled 0
    RegSet $edge EdgeCollectionsEnabled 0
    RegSet $edge HubsSidebarEnabled 0
    RegSet $edge StartupBoostEnabled 0
    RegSet $edge BackgroundModeEnabled 0
    RegSet $edge NewTabPageContentEnabled 0
    RegSet $edge NewTabPageQuickLinksEnabled 0
    RegSet $edge RestoreOnStartup 5
    RegSet $edge ImportOnEachLaunch 0
    RegSet $edge AutoImportAtFirstRun 4

    # OneDrive: yeni kullanicida otomatik kurulum kaydi + kurulum dosyalari
    if (-not $KeepBloat) {
        Log "OneDrive kaldiriliyor ..."
        foreach ($hive in "HKLM\INSTDEF", "HKLM\INSTNTU") {
            foreach ($rk in "Run", "RunOnce") {
                RegQuiet @("delete", "$hive\Software\Microsoft\Windows\CurrentVersion\$rk", "/v", "OneDriveSetup", "/f")
            }
        }
        RegSet "HKLM\INSTSW\Policies\Microsoft\Windows\OneDrive" DisableFileSyncNGSC 1
        foreach ($od in "$mntInst\Windows\System32\OneDriveSetup.exe", "$mntInst\Windows\SysWOW64\OneDriveSetup.exe") {
            if (Test-Path $od) {
                Invoke-Native takeown.exe @("/F", $od, "/A") -IgnoreFailure | Out-Null
                Invoke-Native icacls.exe @($od, "/grant", "Administrators:F") -IgnoreFailure | Out-Null
                Remove-Item $od -Force -ErrorAction SilentlyContinue
            }
        }
    }

    [GC]::Collect(); [GC]::WaitForPendingFinalizers()
    foreach ($h in "HKLM\INSTSW","HKLM\INSTSYS","HKLM\INSTDEF","HKLM\INSTNTU") { Reg @("unload", $h) }

    Log "install.wim kaydediliyor ve kapatiliyor (birkac dakika surer) ..."
    Dismount-WindowsImage -Path $mntInst -Save | Out-Null

    # --- autounattend.xml ---
    if (-not $SkipUnattend) {
        Log "autounattend.xml yaziliyor ..."
        # Kullanici adi / sifredeki < > & " ' karakterleri XML'i bozmasin
        $xmlUser = [System.Security.SecurityElement]::Escape($UserName)
        $xmlPass = [System.Security.SecurityElement]::Escape($Password)
        $unattend = @"
<?xml version="1.0" encoding="utf-8"?>
<unattend xmlns="urn:schemas-microsoft-com:unattend">
  <settings pass="windowsPE">
    <component name="Microsoft-Windows-International-Core-WinPE" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <SetupUILanguage><UILanguage>$Language</UILanguage></SetupUILanguage>
      <InputLocale>$Language</InputLocale><SystemLocale>$Language</SystemLocale>
      <UILanguage>$Language</UILanguage><UserLocale>$Language</UserLocale>
    </component>
    <component name="Microsoft-Windows-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <RunSynchronous>
        <RunSynchronousCommand wcm:action="add" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State"><Order>1</Order><Path>reg add HKLM\SYSTEM\Setup\LabConfig /v BypassTPMCheck /t REG_DWORD /d 1 /f</Path></RunSynchronousCommand>
        <RunSynchronousCommand wcm:action="add" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State"><Order>2</Order><Path>reg add HKLM\SYSTEM\Setup\LabConfig /v BypassSecureBootCheck /t REG_DWORD /d 1 /f</Path></RunSynchronousCommand>
        <RunSynchronousCommand wcm:action="add" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State"><Order>3</Order><Path>reg add HKLM\SYSTEM\Setup\LabConfig /v BypassRAMCheck /t REG_DWORD /d 1 /f</Path></RunSynchronousCommand>
      </RunSynchronous>
      <UserData><AcceptEula>true</AcceptEula>$(if (-not $isWin11) { '<ProductKey><WillShowUI>OnError</WillShowUI></ProductKey>' })</UserData>
      <DynamicUpdate><Enable>false</Enable><WillShowUI>Never</WillShowUI></DynamicUpdate>
    </component>
  </settings>
  <settings pass="specialize">
    <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <Themes>
        <DesktopBackground>C:\Windows\Web\Wallpaper\Windows\img0.jpg</DesktopBackground>
        <ThemeName>Windows</ThemeName>
      </Themes>
    </component>
    <component name="Microsoft-Windows-Deployment" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <RunSynchronous>
        <RunSynchronousCommand wcm:action="add" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State"><Order>1</Order><Path>powercfg /hibernate off</Path></RunSynchronousCommand>
        <RunSynchronousCommand wcm:action="add" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State"><Order>2</Order><Path>powercfg /change standby-timeout-ac 0</Path></RunSynchronousCommand>
        <RunSynchronousCommand wcm:action="add" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State"><Order>3</Order><Path>powercfg /change standby-timeout-dc 0</Path></RunSynchronousCommand>
        <RunSynchronousCommand wcm:action="add" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State"><Order>4</Order><Path>powercfg /change monitor-timeout-ac 0</Path></RunSynchronousCommand>
        <RunSynchronousCommand wcm:action="add" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State"><Order>5</Order><Path>powercfg /change monitor-timeout-dc 0</Path></RunSynchronousCommand>
        <RunSynchronousCommand wcm:action="add" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State"><Order>6</Order><Path>powercfg /change disk-timeout-ac 0</Path></RunSynchronousCommand>
        <RunSynchronousCommand wcm:action="add" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State"><Order>7</Order><Path>powercfg /change hibernate-timeout-ac 0</Path></RunSynchronousCommand>
        <RunSynchronousCommand wcm:action="add" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State"><Order>8</Order><Path>powercfg /setacvalueindex SCHEME_CURRENT SUB_VIDEO VIDEOCONLOCK 0</Path></RunSynchronousCommand>
        <RunSynchronousCommand wcm:action="add" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State"><Order>9</Order><Path>powercfg /setactive SCHEME_CURRENT</Path></RunSynchronousCommand>
        <RunSynchronousCommand wcm:action="add" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State"><Order>10</Order><Path>reg add "HKU\.DEFAULT\Control Panel\Keyboard" /v InitialKeyboardIndicators /t REG_SZ /d 2147483650 /f</Path></RunSynchronousCommand>
      </RunSynchronous>
    </component>
  </settings>
  <settings pass="oobeSystem">
    <component name="Microsoft-Windows-International-Core" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <InputLocale>$Language</InputLocale><SystemLocale>$Language</SystemLocale>
      <UILanguage>$Language</UILanguage><UserLocale>$Language</UserLocale>
    </component>
    <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <OOBE>
        <HideEULAPage>true</HideEULAPage>
        <HideOnlineAccountScreens>true</HideOnlineAccountScreens>
        <HideWirelessSetupInOOBE>true</HideWirelessSetupInOOBE>
        <ProtectYourPC>3</ProtectYourPC>
      </OOBE>
      <UserAccounts>
        <LocalAccounts>
          <LocalAccount wcm:action="add" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
            <Name>$xmlUser</Name><Group>Administrators</Group>
            <Password><Value>$xmlPass</Value><PlainText>true</PlainText></Password>
          </LocalAccount>
        </LocalAccounts>
      </UserAccounts>
      <TimeZone>Turkey Standard Time</TimeZone>
    </component>
  </settings>
</unattend>
"@
        Set-Content -Path "$isoDir\autounattend.xml" -Value $unattend -Encoding UTF8
    }

    if ($Target -eq "Usb") {
        # --- USB diske yaz ---
        Write-Usb $isoDir
    } else {
        # --- ISO oluştur ---
        Log "ISO paketleniyor: $OutputIso"
        $bootData = "2#p0,e,b$isoDir\boot\etfsboot.com#pEF,e,b$isoDir\efi\microsoft\boot\efisys.bin"
        $null = New-Item -ItemType Directory -Path (Split-Path $OutputIso -Parent) -Force
        Invoke-Native $oscdimg @("-m", "-o", "-u2", "-udfver102", "-bootdata:$bootData", "-l$(if ($isWin11) { "WIN11" } else { "WIN10" })_CUSTOM", $isoDir, $OutputIso) |
            Where-Object { $_ -match '\S' } | ForEach-Object { Write-Host $_ }

        Log ("Tamamlandi. Boyut: {0:N0} MB" -f ((Get-Item $OutputIso).Length / 1MB))
        Write-Host "`nProxmox VM onerisi: BIOS=OVMF (UEFI) + EFI disk, TPM diski gerekmez, Disk=VirtIO SCSI, NIC=VirtIO." -ForegroundColor Green
    }
    if (Test-Path "$isoDir\virtio") { Write-Host "Kurulum sonrasi \virtio\ klasorunden guest agent MSI'ini kurun (Proxmox)." -ForegroundColor Green }
}
catch {
    Write-Host "HATA: $_" -ForegroundColor Red
    throw
}
finally {
    Cleanup
}

'@

# ---------- Yonetici haklari: yoksa kendini yukseltilmis olarak yeniden baslat ----------
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    $self = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
    if ($self -match 'powershell(_ise)?\.exe$|pwsh\.exe$') {
        Start-Process $self -Verb RunAs -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""
    } else {
        Start-Process $self -Verb RunAs
    }
    exit
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

# Gomulu builder'i gecici dosyaya yaz
$builder = Join-Path $env:TEMP "Build-WindowsIso.ps1"
[System.IO.File]::WriteAllText($builder, $BuilderSource, (New-Object System.Text.UTF8Encoding $true))

# ---------- Arayuz dili / UI language ----------
$script:UiLang = if ((Get-Culture).TwoLetterISOLanguageName -eq "tr") { "tr" } else { "en" }
if ($args -contains "-UiLang") { $i = [Array]::IndexOf($args, "-UiLang"); if ($i -ge 0 -and $i + 1 -lt $args.Count) { $script:UiLang = $args[$i + 1] } }
$script:Strings = @{
    title = @{ tr = "Windows ISO Builder (10 / 11)"; en = "Windows ISO Builder (10 / 11)" }
    err = @{ tr = "Hata"; en = "Error" }
    ok = @{ tr = "Tamam"; en = "OK" }
    done = @{ tr = "Tamamlandi"; en = "Completed" }
    adk_missing = @{ tr = "ISO olusturmak icin Windows ADK - Deployment Tools (oscdimg.exe) gerekli ve bu bilgisayarda kurulu degil.`n`nSimdi winget ile indirilip kurulsun mu? (yaklasik 100 MB indirilir, sadece Deployment Tools bileseni kurulur)`nKurulum bitince ISO olusturma otomatik baslar."; en = "Building the ISO requires Windows ADK - Deployment Tools (oscdimg.exe), which is not installed on this computer.`n`nDownload and install it now with winget? (about 100 MB download, Deployment Tools component only)`nThe ISO build starts automatically when the installation finishes." }
    adk_note = @{ tr = "Not: Windows ADK (oscdimg) kurulu degil. ISO dosyasi olusturulurken indirilip kurulacak (USB'ye yazmak icin gerekmez)."; en = "Note: Windows ADK (oscdimg) is not installed. It will be downloaded and installed when building an ISO file (not needed for USB)." }
    prereq = @{ tr = "Onkosul eksik"; en = "Prerequisite missing" }
    no_winget = @{ tr = "winget bulunamadi. Microsoft Store'dan 'App Installer' kurun ya da ADK'yi elle indirin:`nlearn.microsoft.com -> 'Download and install the Windows ADK'"; en = "winget not found. Install 'App Installer' from Microsoft Store or download the ADK manually:`nlearn.microsoft.com -> 'Download and install the Windows ADK'" }
    no_winget_t = @{ tr = "winget yok"; en = "winget missing" }
    adk_installing = @{ tr = "Windows ADK kuruluyor..."; en = "Installing Windows ADK..." }
    adk_wait = @{ tr = "winget ile Deployment Tools indiriliyor ve kuruluyor.`nBu birkac dakika surebilir, lutfen bekleyin..."; en = "Downloading and installing Deployment Tools via winget.`nThis may take a few minutes, please wait..." }
    adk_done = @{ tr = "Windows ADK Deployment Tools kuruldu."; en = "Windows ADK Deployment Tools installed." }
    adk_fail = @{ tr = "Kurulum tamamlandi ama oscdimg bulunamadi (winget cikis kodu: {0}).`nADK'yi elle kurup programi tekrar acin."; en = "Installation finished but oscdimg was not found (winget exit code: {0}).`nInstall the ADK manually and reopen the program." }
    l_win = @{ tr = "Windows ISO (10/11):"; en = "Windows ISO (10/11):" }
    l_vio = @{ tr = "VirtIO ISO (istege bagli):"; en = "VirtIO ISO (optional):" }
    l_drv = @{ tr = "Surucu klasoru (istege bagli):"; en = "Driver folder (optional):" }
    l_out = @{ tr = "Cikti ISO:"; en = "Output ISO:" }
    l_target = @{ tr = "Cikti:"; en = "Output:" }
    rb_iso = @{ tr = "ISO dosyasi"; en = "ISO file" }
    rb_usb = @{ tr = "USB disk (kurulum)"; en = "USB drive (setup)" }
    chk_raw = @{ tr = "Hazir ISO'yu degistirmeden yaz"; en = "Write the ISO as-is (no changes)" }
    l_usb = @{ tr = "USB disk:"; en = "USB drive:" }
    b_refresh = @{ tr = "Yenile"; en = "Refresh" }
    b_write = @{ tr = "USB'YE YAZ"; en = "WRITE TO USB" }
    no_usb = @{ tr = "(USB disk bulunamadi - takip Yenile'ye basin)"; en = "(no USB drive found - plug in and click Refresh)" }
    no_disk = @{ tr = "(yazilabilecek disk bulunamadi)"; en = "(no writable disk found)" }
    chk_all = @{ tr = "Tum diskler"; en = "All disks" }
    usb_internal = @{ tr = "`n`nBU BIR DAHILI DISK ({0})! Dogru diski sectiginizden emin olun."; en = "`n`nTHIS IS AN INTERNAL DISK ({0})! Make sure you selected the right disk." }
    e_srcdisk = @{ tr = "Secilen disk, kaynak ISO'yu veya calisma dizinini iceriyor. Yazma sirasinda silinecegi icin bu diske yazilamaz."; en = "The selected disk contains the source ISO or the working folder. It would be erased while writing, so it cannot be used." }
    e_usb = @{ tr = "USB disk secin."; en = "Select a USB drive." }
    usb_confirm = @{ tr = "DIKKAT: Asagidaki diskteki TUM VERILER SILINECEK:`n`n{0}`n`nDevam edilsin mi?"; en = "WARNING: ALL DATA on the following drive will be ERASED:`n`n{0}`n`nContinue?" }
    usb_ready = @{ tr = "USB disk hazir:`n"; en = "USB drive ready:`n" }
    starting_raw = @{ tr = "Baslatiliyor... (USB hizina gore 5-20 dk)"; en = "Starting... (5-20 min depending on USB speed)" }
    l_work = @{ tr = "Calisma dizini:"; en = "Working folder:" }
    l_ed = @{ tr = "Surum:"; en = "Edition:" }
    l_user = @{ tr = "Kullanici adi:"; en = "Username:" }
    l_pass = @{ tr = "Sifre:"; en = "Password:" }
    l_lang = @{ tr = "Dil:"; en = "Locale:" }
    l_feat = @{ tr = "Windows ozellikleri:"; en = "Windows features:" }
    l_ui = @{ tr = "Arayuz:"; en = "UI:" }
    b_sel = @{ tr = "Sec..."; en = "Browse..." }
    b_loc = @{ tr = "Konum..."; en = "Location..." }
    b_list = @{ tr = "ISO'daki surumleri listele"; en = "List editions in ISO" }
    b_build = @{ tr = "ISO OLUSTUR"; en = "BUILD ISO" }
    b_cancel = @{ tr = "Iptal"; en = "Cancel" }
    drv_desc = @{ tr = "Icinde .inf dosyalari olan surucu klasorunu secin (alt klasorler taranir)"; en = "Select the driver folder containing .inf files (subfolders are scanned)" }
    os_hint = @{ tr = "Algilanan: (ISO'daki surumleri listeleyin)"; en = "Detected: (list editions in ISO)" }
    os_det = @{ tr = "Algilanan: {0} (build {1})"; en = "Detected: {0} (build {1})" }
    pick_iso = @{ tr = "Once Windows ISO secin."; en = "Select the Windows ISO first." }
    editions = @{ tr = "ISO surumleri: "; en = "ISO editions: " }
    unreadable = @{ tr = "Okunamadi: "; en = "Could not read: " }
    chk_bloat = @{ tr = "Gereksiz uygulamalari kaldir (Xbox, Teams, Bing vb.)"; en = "Remove bloatware (Xbox, Teams, Bing etc.)" }
    chk_unatt = @{ tr = "Otomatik kurulum (autounattend.xml, TPM/online hesap atlatma)"; en = "Unattended setup (autounattend.xml, TPM/online account bypass)" }
    e_win = @{ tr = "Windows ISO bulunamadi: "; en = "Windows ISO not found: " }
    e_drv = @{ tr = "Surucu klasoru bulunamadi: "; en = "Driver folder not found: " }
    e_vio = @{ tr = "VirtIO ISO bulunamadi: "; en = "VirtIO ISO not found: " }
    e_pass = @{ tr = "Sifre en az 4 karakter olmali."; en = "Password must be at least 4 characters." }
    starting = @{ tr = "Baslatiliyor... (20-40 dk surebilir)"; en = "Starting... (may take 20-40 min)" }
    finished = @{ tr = "BITTI: "; en = "DONE: " }
    iso_ready = @{ tr = "ISO hazir:`n"; en = "ISO ready:`n" }
    failed = @{ tr = "HATA ile bitti (kod {0}). Log: {1}"; en = "Finished with ERROR (code {0}). Log: {1}" }
    cancelled = @{ tr = "Iptal edildi. Mount kalmis olabilir: 'dism /cleanup-wim' ve calisma dizinini silin."; en = "Cancelled. A mount may be left behind: run 'dism /cleanup-wim' and delete the working folder." }
}
function L($key) { $script:Strings[$key][$script:UiLang] }
$script:FeatEn = @{
    ".NET Framework 3.5 (2.0 ve 3.0 dahil)" = ".NET Framework 3.5 (includes 2.0 and 3.0)"
    "Hyper-V (Pro/Enterprise)" = "Hyper-V (Pro/Enterprise)"
    "Windows Sandbox" = "Windows Sandbox"
    "Sanal Makine Platformu (WSL2 icin gerekli)" = "Virtual Machine Platform (required for WSL2)"
    "Linux icin Windows Alt Sistemi (WSL)" = "Windows Subsystem for Linux (WSL)"
    "Telnet istemcisi" = "Telnet Client"
    "TFTP istemcisi" = "TFTP Client"
    "IIS Web Sunucusu" = "IIS Web Server"
    "Eski bilesenler (DirectPlay)" = "Legacy Components (DirectPlay)"
    "SMB 1.0/CIFS istemcisi" = "SMB 1.0/CIFS Client"
    "Microsoft XPS Yazici" = "Microsoft XPS Document Writer"
    "Microsoft Print to PDF" = "Microsoft Print to PDF"
    "Internet Yazdirma Istemcisi" = "Internet Printing Client"
    "Is Klasorleri Istemcisi" = "Work Folders Client"
    "Internet Explorer 11" = "Internet Explorer 11"
    "Windows Media Player" = "Windows Media Player"
    "Windows Faks ve Tarama" = "Windows Fax and Scan"
}
function Get-FeatLabel($trName) { $v = $null; if ($script:UiLang -eq "en") { $v = $script:FeatEn[$trName] }; if (-not $v) { $v = $trName }; return "$v" }

# ---------- Onkosul: oscdimg (Windows ADK Deployment Tools) ----------
function Get-OscdimgPath {
    $c = @(
        "${env:ProgramFiles(x86)}\Windows Kits\10\Assessment and Deployment Kit\Deployment Tools\amd64\Oscdimg\oscdimg.exe",
        "${env:ProgramFiles}\Windows Kits\10\Assessment and Deployment Kit\Deployment Tools\amd64\Oscdimg\oscdimg.exe"
    ) | Where-Object { Test-Path $_ } | Select-Object -First 1
    if ($c) { return $c }
    $cmd = Get-Command oscdimg.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    return $null
}

function Ensure-Oscdimg {
    if (Get-OscdimgPath) { return $true }
    $msg = (L 'adk_missing')
    $r = [System.Windows.Forms.MessageBox]::Show($msg, (L 'prereq'), "YesNo", "Question")
    if ($r -ne "Yes") { return $false }

    if (-not (Get-Command winget.exe -ErrorAction SilentlyContinue)) {
        [System.Windows.Forms.MessageBox]::Show((L 'no_winget'), (L 'no_winget_t'), "OK", "Warning") | Out-Null
        return $false
    }

    $wait = New-Object System.Windows.Forms.Form
    $wait.Text = (L 'adk_installing'); $wait.Size = New-Object System.Drawing.Size(420, 120)
    $wait.StartPosition = "CenterScreen"; $wait.FormBorderStyle = "FixedDialog"; $wait.ControlBox = $false
    $wait.ShowInTaskbar = $false; $wait.Owner = $form
    $lbl = New-Object System.Windows.Forms.Label
    $lbl.Text = (L 'adk_wait')
    $lbl.Location = New-Object System.Drawing.Point(15, 15); $lbl.AutoSize = $true
    $wait.Controls.Add($lbl)
    # Kurulum surerken ana pencere kilitli (tekrar tiklanmasin)
    $form.Enabled = $false
    $txtLog.AppendText((L 'adk_installing') + "`r`n")
    $wait.Show(); [System.Windows.Forms.Application]::DoEvents()

    $p = Start-Process winget.exe -ArgumentList @(
        "install", "--id", "Microsoft.WindowsADK", "--exact", "--silent",
        "--accept-package-agreements", "--accept-source-agreements",
        "--override", "`"/features OptionId.DeploymentTools /quiet /norestart`""
    ) -PassThru -WindowStyle Hidden
    while (-not $p.HasExited) { [System.Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 300 }
    $wait.Close()
    $form.Enabled = $true

    if (Get-OscdimgPath) {
        $txtLog.AppendText((L 'adk_done') + "`r`n")
        return $true
    }
    [System.Windows.Forms.MessageBox]::Show(((L 'adk_fail') -f $p.ExitCode), (L 'err'), "OK", "Error") | Out-Null
    return $false
}

# ---------- Form ----------
$form = New-Object System.Windows.Forms.Form
$form.Text = (L 'title')
$cmbUi = New-Object System.Windows.Forms.ComboBox
$cmbUi.Location = New-Object System.Drawing.Point(640, 12); $cmbUi.Size = New-Object System.Drawing.Size(90, 23)
$cmbUi.DropDownStyle = "DropDownList"; @("Türkçe","English") | ForEach-Object { $cmbUi.Items.Add($_) | Out-Null }
$cmbUi.SelectedIndex = if ($script:UiLang -eq "tr") { 0 } else { 1 }
$cmbUi.Add_SelectedIndexChanged({
    $new = if ($cmbUi.SelectedIndex -eq 0) { "tr" } else { "en" }
    if ($new -ne $script:UiLang) {
        $self = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
        if ($self -match 'powershell|pwsh') { Start-Process $self -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" -UiLang $new" }
        else { Start-Process $self -ArgumentList "-UiLang $new" }
        $form.Close()
    }
})
$form.Controls.Add($cmbUi)
$form.Size = New-Object System.Drawing.Size(760, 895)
$form.StartPosition = "CenterScreen"
$form.FormBorderStyle = "FixedDialog"
$form.MaximizeBox = $false
$form.Font = New-Object System.Drawing.Font("Segoe UI", 9)
try {
    $self = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
    $icoFile = Join-Path (Split-Path $self -Parent) "WindowsIsoBuilder.ico"
    if ($self -notmatch 'powershell|pwsh') { $form.Icon = [System.Drawing.Icon]::ExtractAssociatedIcon($self) }
    elseif (Test-Path $icoFile) { $form.Icon = New-Object System.Drawing.Icon($icoFile) }
} catch { }

function Add-Label($text, $x, $y) {
    $l = New-Object System.Windows.Forms.Label
    $l.Text = $text; $l.Location = New-Object System.Drawing.Point($x, $y); $l.AutoSize = $true
    $form.Controls.Add($l); return $l
}
function Add-TextBox($x, $y, $w, $default = "") {
    $t = New-Object System.Windows.Forms.TextBox
    $t.Location = New-Object System.Drawing.Point($x, $y); $t.Size = New-Object System.Drawing.Size($w, 23); $t.Text = $default
    $form.Controls.Add($t); return $t
}
function Add-Button($text, $x, $y, $w = 90) {
    $b = New-Object System.Windows.Forms.Button
    $b.Text = $text; $b.Location = New-Object System.Drawing.Point($x, $y); $b.Size = New-Object System.Drawing.Size($w, 25)
    $form.Controls.Add($b); return $b
}
function Pick-File($filter, $save = $false, $initial = "") {
    $d = if ($save) { New-Object System.Windows.Forms.SaveFileDialog } else { New-Object System.Windows.Forms.OpenFileDialog }
    $d.Filter = $filter
    if ($initial) {
        $d.FileName = Split-Path $initial -Leaf
        $dir = Split-Path $initial -Parent
        if ($dir -and (Test-Path $dir)) { $d.InitialDirectory = $dir }
    }
    if ($d.ShowDialog() -eq "OK") { return $d.FileName }
    return $null
}

$lblUi = Add-Label (L 'l_ui') 585 15
$y = 48
Add-Label (L 'l_win') 20 ($y+3) | Out-Null
$txtWin = Add-TextBox 150 $y 480
$btnWin = Add-Button (L 'b_sel') 640 ($y-1)
$btnWin.Add_Click({ $f = Pick-File "ISO (*.iso)|*.iso"; if ($f) { $txtWin.Text = $f; Detect-Iso } })

$y += 35
Add-Label (L 'l_vio') 20 ($y+3) | Out-Null
$txtVio = Add-TextBox 150 $y 480
$btnVio = Add-Button (L 'b_sel') 640 ($y-1)
$btnVio.Add_Click({ $f = Pick-File "ISO (*.iso)|*.iso"; if ($f) { $txtVio.Text = $f } })

$y += 35
Add-Label (L 'l_drv') 20 ($y+3) | Out-Null
$txtDrv = Add-TextBox 150 $y 480
$btnDrv = Add-Button (L 'b_sel') 640 ($y-1)
$btnDrv.Add_Click({
    $d = New-Object System.Windows.Forms.FolderBrowserDialog
    $d.Description = (L 'drv_desc')
    if ($d.ShowDialog() -eq "OK") { $txtDrv.Text = $d.SelectedPath }
})

$y += 35
Add-Label (L 'l_target') 20 ($y+3) | Out-Null
$rbIso = New-Object System.Windows.Forms.RadioButton
$rbIso.Text = (L 'rb_iso'); $rbIso.Location = New-Object System.Drawing.Point(150, ($y+1)); $rbIso.AutoSize = $true; $rbIso.Checked = $true
$form.Controls.Add($rbIso)
$rbUsb = New-Object System.Windows.Forms.RadioButton
$rbUsb.Text = (L 'rb_usb'); $rbUsb.Location = New-Object System.Drawing.Point(270, ($y+1)); $rbUsb.AutoSize = $true
$form.Controls.Add($rbUsb)
$chkRaw = New-Object System.Windows.Forms.CheckBox
$chkRaw.Text = (L 'chk_raw'); $chkRaw.Location = New-Object System.Drawing.Point(440, ($y+1)); $chkRaw.AutoSize = $true
$form.Controls.Add($chkRaw)
$rbUsb.Add_CheckedChanged({ if ($rbUsb.Checked -and $script:usbDisks.Count -eq 0) { Update-UsbList }; Update-TargetUi })
$chkRaw.Add_CheckedChanged({ Update-TargetUi })

$y += 35
# Ayni satir: ISO modunda cikti dosyasi, USB modunda disk listesi
$lblOut = Add-Label (L 'l_out') 20 ($y+3)
$txtOut = Add-TextBox 150 $y 480 "C:\iso\Windows-Custom.iso"
$script:autoOut = $true
$txtOut.Add_TextChanged({ if (-not $script:settingOut) { $script:autoOut = $false } })
$btnOut = Add-Button (L 'b_loc') 640 ($y-1)
$btnOut.Add_Click({ $f = Pick-File "ISO (*.iso)|*.iso" $true $txtOut.Text; if ($f) { $txtOut.Text = $f } })
$cmbUsb = New-Object System.Windows.Forms.ComboBox
$cmbUsb.Location = New-Object System.Drawing.Point(150, $y); $cmbUsb.Size = New-Object System.Drawing.Size(390, 23)
$cmbUsb.DropDownStyle = "DropDownList"; $cmbUsb.DropDownWidth = 580; $cmbUsb.Visible = $false
$form.Controls.Add($cmbUsb)
$chkAllDisks = New-Object System.Windows.Forms.CheckBox
$chkAllDisks.Text = (L 'chk_all'); $chkAllDisks.Location = New-Object System.Drawing.Point(548, ($y+2)); $chkAllDisks.AutoSize = $true
$chkAllDisks.Visible = $false
$chkAllDisks.Add_CheckedChanged({ Update-UsbList })
$form.Controls.Add($chkAllDisks)
$btnUsbRefresh = Add-Button (L 'b_refresh') 640 ($y-1)
$btnUsbRefresh.Visible = $false
$btnUsbRefresh.Add_Click({ Update-UsbList })

# Varsayilan: sadece USB/SD baglantili diskler; "Tum diskler" ile dahili diskler de listelenir.
# Windows'un kurulu oldugu disk (IsBoot/IsSystem) ve sanal diskler hicbir durumda listelenmez.
$script:usbDisks = @()
function Get-DiskSig($d) { "{0}|{1}|{2}" -f $d.FriendlyName, $d.Size, "$($d.SerialNumber)".Trim() }
function Test-UsbBus($d) { $d.BusType -in @("USB","SD","MMC") }
function Update-UsbList {
    $cmbUsb.Items.Clear()
    $script:usbDisks = @(Get-Disk -ErrorAction SilentlyContinue |
        Where-Object { -not $_.IsBoot -and -not $_.IsSystem -and $_.Size -gt 0 -and $_.BusType -ne "File Backed Virtual" -and
                       ($chkAllDisks.Checked -or (Test-UsbBus $_)) } | Sort-Object Number)
    foreach ($d in $script:usbDisks) {
        $letters = @(Get-Partition -DiskNumber $d.Number -ErrorAction SilentlyContinue |
            Where-Object { "$($_.DriveLetter)" -match '^[A-Za-z]$' } | ForEach-Object { "$($_.DriveLetter):" })
        $lt = if ($letters.Count -gt 0) { " [" + ($letters -join " ") + "]" } else { "" }
        $cmbUsb.Items.Add(("Disk {0} - {1} ({2:N1} GB, {3}){4}" -f $d.Number, $d.FriendlyName, ($d.Size / 1GB), $d.BusType, $lt)) | Out-Null
    }
    if ($script:usbDisks.Count -eq 0) { $cmbUsb.Items.Add((L $(if ($chkAllDisks.Checked) { 'no_disk' } else { 'no_usb' }))) | Out-Null }
    $cmbUsb.SelectedIndex = 0
}
# Bir dosya/klasorun bulundugu diskin numarasi (bulunamazsa -1)
function Get-PathDiskNumber($path) {
    try {
        $q = Split-Path -Qualifier ([System.IO.Path]::GetFullPath($path))
        $p = Get-Partition -DriveLetter $q.TrimEnd(':') -ErrorAction Stop
        return [int]$p.DiskNumber
    } catch { return -1 }
}

$y += 35
Add-Label (L 'l_work') 20 ($y+3) | Out-Null
$txtWork = Add-TextBox 150 $y 480 "C:\WindowsIsoBuild"

$y += 45
Add-Label (L 'l_ed') 20 ($y+3) | Out-Null
$cmbEdition = New-Object System.Windows.Forms.ComboBox
$cmbEdition.Location = New-Object System.Drawing.Point(150, $y); $cmbEdition.Size = New-Object System.Drawing.Size(220, 23)
$cmbEdition.DropDownStyle = "DropDown"
@("Windows 11 Pro", "Windows 11 Home", "Windows 11 Enterprise", "Windows 11 Education") | ForEach-Object { $cmbEdition.Items.Add($_) | Out-Null }
$cmbEdition.SelectedIndex = 0
$form.Controls.Add($cmbEdition)
$btnList = Add-Button (L 'b_list') 380 ($y-1) 180
$lblOs = Add-Label (L 'os_hint') 570 ($y+3)
$lblOs.ForeColor = [System.Drawing.Color]::Gray
$script:isWin11 = $true
function Detect-Iso {
    if (-not (Test-Path $txtWin.Text)) { [System.Windows.Forms.MessageBox]::Show((L 'pick_iso')) | Out-Null; return }
    try {
        $img = Mount-DiskImage -ImagePath $txtWin.Text -PassThru
        $letter = ($img | Get-Volume).DriveLetter
        $wim = @("${letter}:\sources\install.wim", "${letter}:\sources\install.esd") | Where-Object { Test-Path $_ } | Select-Object -First 1
        $imgs  = Get-WindowsImage -ImagePath $wim
        $names = $imgs.ImageName
        $ver   = (Get-WindowsImage -ImagePath $wim -Index $imgs[0].ImageIndex).Version
        $build = [int]($ver -split '\.')[2]
        $script:isWin11 = $build -ge 22000
        Dismount-DiskImage -ImagePath $txtWin.Text | Out-Null
        $osName = if ($script:isWin11) { "Windows 11" } else { "Windows 10" }
        $lblOs.Text = (L 'os_det') -f $osName, $build
        $lblOs.ForeColor = [System.Drawing.Color]::DarkGreen
        Update-FeatureList
        Update-OutName
        $cmbEdition.Items.Clear()
        $names | ForEach-Object { $cmbEdition.Items.Add($_) | Out-Null }
        # Varsayilan: "Windows 1x Pro" (yoksa Pro iceren ilk sürüm, o da yoksa ilk sürüm)
        $pro = $cmbEdition.Items.IndexOf(($names | Where-Object { $_ -match '^Windows 1[01] Pro$' } | Select-Object -First 1))
        if ($pro -lt 0) { $pro = [Math]::Max(0, $cmbEdition.Items.IndexOf(($names | Where-Object { $_ -match 'Pro' } | Select-Object -First 1))) }
        $cmbEdition.SelectedIndex = $pro
        $txtLog.AppendText((L 'editions') + ($names -join ', ') + "`r`n$($lblOs.Text)`r`n")
    } catch {
        Dismount-DiskImage -ImagePath $txtWin.Text -ErrorAction SilentlyContinue | Out-Null
        [System.Windows.Forms.MessageBox]::Show((L 'unreadable') + "$_", (L 'err'), "OK", "Error") | Out-Null
    }
}
$btnList.Add_Click({ Detect-Iso })
$cmbEdition.Add_SelectedIndexChanged({ Update-OutName })
function Update-OutName {
    if (-not $script:autoOut) { return }
    $os = if ($script:isWin11) { "Win11" } else { "Win10" }
    $ed = ("$($cmbEdition.Text)" -replace '^Windows 1[01]\s*', '' -replace '[^A-Za-z0-9]', '')
    if (-not $ed) { $ed = "Custom" }
    $dir = Split-Path $txtOut.Text -Parent; if (-not $dir) { $dir = "C:\iso" }
    $script:settingOut = $true
    $txtOut.Text = Join-Path $dir "$os-$ed-Custom.iso"
    $script:settingOut = $false
}

$y += 35
Add-Label (L 'l_user') 20 ($y+3) | Out-Null
$txtUser = Add-TextBox 150 $y 160 "Inversa"
Add-Label (L 'l_pass') 330 ($y+3) | Out-Null
$txtPass = Add-TextBox 380 $y 160 "1234"
Add-Label (L 'l_lang') 560 ($y+3) | Out-Null
$txtLang = Add-TextBox 600 $y 120 $(if ($script:UiLang -eq "tr") { "tr-TR" } else { "en-US" })

$y += 35
$chkBloat = New-Object System.Windows.Forms.CheckBox
$chkBloat.Text = (L 'chk_bloat')
$chkBloat.Location = New-Object System.Drawing.Point(150, $y); $chkBloat.AutoSize = $true; $chkBloat.Checked = $true
$form.Controls.Add($chkBloat)

$y += 25
$chkUnattend = New-Object System.Windows.Forms.CheckBox
$chkUnattend.Text = (L 'chk_unatt')
$chkUnattend.Location = New-Object System.Drawing.Point(150, $y); $chkUnattend.AutoSize = $true; $chkUnattend.Checked = $true
$form.Controls.Add($chkUnattend)

$y += 30
Add-Label (L 'l_feat') 20 $y | Out-Null
$y += 22
$lstFeatures = New-Object System.Windows.Forms.CheckedListBox
$lstFeatures.Location = New-Object System.Drawing.Point(20, $y)
$lstFeatures.Size = New-Object System.Drawing.Size(705, 170)
$lstFeatures.CheckOnClick = $true
$lstFeatures.MultiColumn = $true
$lstFeatures.ColumnWidth = 350
# Gorunen ad -> DISM ozellik adi
$featureMap = [ordered]@{
    ".NET Framework 3.5 (2.0 ve 3.0 dahil)"      = "NetFx3"
    "Hyper-V (Pro/Enterprise)"                    = "Microsoft-Hyper-V-All"
    "Windows Sandbox"                             = "Containers-DisposableClientVM"
    "Sanal Makine Platformu (WSL2 icin gerekli)"  = "VirtualMachinePlatform"
    "Linux icin Windows Alt Sistemi (WSL)"        = "Microsoft-Windows-Subsystem-Linux"
    "Telnet istemcisi"                            = "TelnetClient"
    "TFTP istemcisi"                              = "TFTP"
    "IIS Web Sunucusu"                            = "IIS-WebServerRole"
    "Eski bilesenler (DirectPlay)"                = "LegacyComponents"
    "SMB 1.0/CIFS istemcisi"                      = "SMB1Protocol-Client"
    "Microsoft XPS Yazici"                        = "Printing-XPSServices-Features"
    "Microsoft Print to PDF"                      = "Printing-PrintToPDFServices-Features"
    "Internet Yazdirma Istemcisi"                 = "Printing-Foundation-InternetPrinting-Client"
    "Is Klasorleri Istemcisi"                     = "WorkFolders-Client"
}
$featureMapWin10 = [ordered]@{
    "Internet Explorer 11"                        = "Internet-Explorer-Optional-amd64"
    "Windows Media Player"                        = "WindowsMediaPlayer"
    "Windows Faks ve Tarama"                      = "FaxServicesClientPackage"
}
$defaultFeatures = @("NetFx3", "Printing-PrintToPDFServices-Features")
function Update-FeatureList {
    $checked = @($lstFeatures.CheckedItems | ForEach-Object { "$_" })
    if ($checked.Count -eq 0) { $checked = @($featureMap.Keys | Where-Object { $defaultFeatures -contains $featureMap[$_] } | ForEach-Object { Get-FeatLabel $_ }) }
    $lstFeatures.Items.Clear()
    $featureMap.Keys | ForEach-Object { $lstFeatures.Items.Add((Get-FeatLabel $_), ($checked -contains (Get-FeatLabel $_))) | Out-Null }
    if (-not $script:isWin11) {
        $featureMapWin10.Keys | ForEach-Object { $lstFeatures.Items.Add((Get-FeatLabel $_), ($checked -contains (Get-FeatLabel $_))) | Out-Null }
    }
}
Update-FeatureList
$form.Controls.Add($lstFeatures)

$y += 185
$btnBuild = Add-Button (L 'b_build') 150 $y 200
$btnBuild.Font = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
$btnBuild.Height = 32
$btnCancel = Add-Button (L 'b_cancel') 360 $y 100
$btnCancel.Height = 32
$btnCancel.Enabled = $false

$y += 45
$txtLog = New-Object System.Windows.Forms.TextBox
$txtLog.Location = New-Object System.Drawing.Point(20, $y)
$txtLog.Size = New-Object System.Drawing.Size(705, 165)
$txtLog.Multiline = $true; $txtLog.ScrollBars = "Vertical"; $txtLog.ReadOnly = $true
$txtLog.Font = New-Object System.Drawing.Font("Consolas", 9)
$txtLog.BackColor = [System.Drawing.Color]::White
$form.Controls.Add($txtLog)
# ADK acilista sadece kontrol edilir; kurulum 'ISO OLUSTUR' tiklaninca yapilir
if (-not (Get-OscdimgPath)) { $txtLog.AppendText((L 'adk_note') + "`r`n") }

# ---------- Build logic ----------
$script:proc = $null
$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 500

# Degeri tek tirnakli PowerShell dizesine cevirir (icindeki ' ve tipografik tirnaklar ikilenir)
function Quote-Ps($s) { "'" + ("$s" -replace "(['\u2018\u2019\u201A\u201B])", '$1$1') + "'" }

# Cikti secimine gore alanlari goster/gizle; "hazir ISO'yu yaz" modunda duzenleme secenekleri kapanir
function Update-TargetUi {
    $usb = $rbUsb.Checked
    $raw = $usb -and $chkRaw.Checked
    $lblOut.Text = if ($usb) { L 'l_usb' } else { L 'l_out' }
    $txtOut.Visible = -not $usb; $btnOut.Visible = -not $usb
    $cmbUsb.Visible = $usb; $btnUsbRefresh.Visible = $usb; $chkAllDisks.Visible = $usb
    $chkRaw.Enabled = $usb
    $btnBuild.Text = if ($usb) { L 'b_write' } else { L 'b_build' }
    foreach ($c in @($txtVio, $btnVio, $txtDrv, $btnDrv, $cmbEdition, $btnList, $txtUser, $txtPass, $txtLang, $chkBloat, $chkUnattend, $lstFeatures)) { $c.Enabled = -not $raw }
}

function Set-Busy($busy) {
    $btnBuild.Enabled = -not $busy
    $btnCancel.Enabled = $busy
    foreach ($c in @($txtWin, $txtVio, $txtDrv, $txtOut, $txtWork, $cmbEdition, $txtUser, $txtPass, $txtLang, $chkBloat, $chkUnattend, $lstFeatures, $btnWin, $btnVio, $btnDrv, $btnOut, $btnList,
                     $rbIso, $rbUsb, $chkRaw, $cmbUsb, $chkAllDisks, $btnUsbRefresh)) { $c.Enabled = -not $busy }
    if (-not $busy) { Update-TargetUi }
}

$btnBuild.Add_Click({
    $usbMode = $rbUsb.Checked
    $raw = $usbMode -and $chkRaw.Checked
    if (-not (Test-Path $txtWin.Text)) { [System.Windows.Forms.MessageBox]::Show((L 'e_win') + $txtWin.Text, (L 'err'), "OK", "Error") | Out-Null; return }
    if (-not $raw) {
        if ($txtDrv.Text -and -not (Test-Path $txtDrv.Text)) { [System.Windows.Forms.MessageBox]::Show((L 'e_drv') + $txtDrv.Text, (L 'err'), "OK", "Error") | Out-Null; return }
        if ($txtVio.Text -and -not (Test-Path $txtVio.Text)) { [System.Windows.Forms.MessageBox]::Show((L 'e_vio') + $txtVio.Text, (L 'err'), "OK", "Error") | Out-Null; return }
        if ($txtPass.Text.Length -lt 4) { [System.Windows.Forms.MessageBox]::Show((L 'e_pass'), (L 'err'), "OK", "Error") | Out-Null; return }
    }
    if ($usbMode) {
        $i = $cmbUsb.SelectedIndex
        if ($i -lt 0 -or $i -ge $script:usbDisks.Count) { [System.Windows.Forms.MessageBox]::Show((L 'e_usb'), (L 'err'), "OK", "Error") | Out-Null; return }
        $disk = $script:usbDisks[$i]
        # Kaynak ISO veya calisma dizini bu diskteyse yazma sirasinda silinir
        $srcDisks = @((Get-PathDiskNumber $txtWin.Text), (Get-PathDiskNumber $txtWork.Text))
        if ($srcDisks -contains [int]$disk.Number) { [System.Windows.Forms.MessageBox]::Show((L 'e_srcdisk'), (L 'err'), "OK", "Error") | Out-Null; return }
        $warn = (L 'usb_confirm') -f $cmbUsb.Text
        if (-not (Test-UsbBus $disk)) { $warn += (L 'usb_internal') -f $disk.BusType }
        $r = [System.Windows.Forms.MessageBox]::Show($warn, (L 'title'),
            [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Warning, [System.Windows.Forms.MessageBoxDefaultButton]::Button2)
        if ($r -ne "Yes") { return }
        $script:targetDesc = $cmbUsb.Text
    } else {
        # ADK yoksa simdi sor, indir ve kur; kurulmazsa ISO olusturma baslamaz
        if (-not (Ensure-Oscdimg)) { return }
        $script:targetDesc = $txtOut.Text
    }

    $script:targetUsb = $usbMode
    $txtLog.Clear()
    $txtLog.AppendText((L $(if ($raw) { 'starting_raw' } else { 'starting' })) + "`r`n")

    $script:logFile = Join-Path $env:TEMP "WindowsIsoBuilder-build.log"
    Remove-Item $script:logFile -ErrorAction SilentlyContinue
    $script:logPos = 0

    if ($raw) {
        $argList = @("-WindowsIso " + (Quote-Ps $txtWin.Text), "-WorkDir " + (Quote-Ps $txtWork.Text), "-WriteOnly")
    } else {
        $argList = @(
            "-WindowsIso " + (Quote-Ps $txtWin.Text),
            "-WorkDir "    + (Quote-Ps $txtWork.Text),
            "-Edition "    + (Quote-Ps $cmbEdition.Text),
            "-UserName "   + (Quote-Ps $txtUser.Text),
            "-Password "   + (Quote-Ps $txtPass.Text),
            "-Language "   + (Quote-Ps $txtLang.Text)
        )
        if (-not $usbMode) { $argList += "-OutputIso " + (Quote-Ps $txtOut.Text) }
        if ($txtVio.Text) { $argList += "-VirtioIso " + (Quote-Ps $txtVio.Text) }
        if ($txtDrv.Text) { $argList += "-DriverDir " + (Quote-Ps $txtDrv.Text) }
        $selected = @($lstFeatures.CheckedItems | ForEach-Object {
            $n = "$_"; $tr = ($script:FeatEn.GetEnumerator() | Where-Object { $_.Value -eq $n } | Select-Object -First 1).Key
            if (-not $tr) { $tr = $n }
            if ($featureMap.Contains($tr)) { $featureMap[$tr] } else { $featureMapWin10[$tr] } })
        if ($selected.Count -gt 0) { $argList += "-Features " + (($selected | ForEach-Object { Quote-Ps $_ }) -join ",") }
        if (-not $chkBloat.Checked)    { $argList += "-KeepBloat" }
        if (-not $chkUnattend.Checked) { $argList += "-SkipUnattend" }
    }
    if ($usbMode) {
        $argList += @("-Target Usb", "-UsbDisk $($disk.Number)", "-UsbDiskSig " + (Quote-Ps (Get-DiskSig $disk)))
        if (-not (Test-UsbBus $disk)) { $argList += "-AllowAnyDisk" }
    }

    # Tum akislar (Write-Host dahil) log dosyasina; pencere dosyayi periyodik okur
    $qLog = Quote-Ps $script:logFile
    $cmd = "try { & $(Quote-Ps $builder) $($argList -join ' ') *>&1 | Out-File -FilePath $qLog -Encoding utf8; exit 0 } catch { `$_ | Out-File -FilePath $qLog -Append -Encoding utf8; exit 1 }"
    # EncodedCommand: degerlerdeki cift tirnak vb. komut satirini bozmasin
    $encoded = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($cmd))

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = "powershell.exe"
    $psi.Arguments = "-NoProfile -ExecutionPolicy Bypass -EncodedCommand $encoded"
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true

    $script:proc = New-Object System.Diagnostics.Process
    $script:proc.StartInfo = $psi
    $script:proc.Start() | Out-Null

    Set-Busy $true
    $timer.Start()
})

function Read-NewLog {
    if (-not (Test-Path $script:logFile)) { return }
    try {
        $fs = [System.IO.FileStream]::new($script:logFile, 'Open', 'Read', 'ReadWrite')
        if ($fs.Length -gt $script:logPos) {
            $fs.Seek($script:logPos, 'Begin') | Out-Null
            $buf = New-Object byte[] ($fs.Length - $script:logPos)
            $n = $fs.Read($buf, 0, $buf.Length)
            $script:logPos += $n
            $text = [System.Text.Encoding]::UTF8.GetString($buf, 0, $n) -replace "^\uFEFF", ""
            $txtLog.AppendText($text)
        }
        $fs.Close()
    } catch { }
}

$timer.Add_Tick({
    Read-NewLog
    if ($script:proc -and $script:proc.HasExited) {
        $timer.Stop()
        Start-Sleep -Milliseconds 300
        Read-NewLog
        Set-Busy $false
        if ($script:proc.ExitCode -eq 0) {
            $txtLog.AppendText("`r`n" + (L 'finished') + $script:targetDesc + "`r`n")
            $readyKey = if ($script:targetUsb) { 'usb_ready' } else { 'iso_ready' }
            [System.Windows.Forms.MessageBox]::Show((L $readyKey) + $script:targetDesc, (L 'done'), "OK", "Information") | Out-Null
        } else {
            $txtLog.AppendText("`r`n" + ((L 'failed') -f $script:proc.ExitCode, $script:logFile) + "`r`n")
        }
        $script:proc = $null
    }
})

$btnCancel.Add_Click({
    if ($script:proc -and -not $script:proc.HasExited) {
        $script:proc.Kill()
        $txtLog.AppendText("`r`n" + (L 'cancelled') + "`r`n")
    }
})

$form.Add_FormClosing({ if ($script:proc -and -not $script:proc.HasExited) { $script:proc.Kill() } })

[void]$form.ShowDialog()
