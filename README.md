# Windows ISO Builder (10 / 11)

**English** | [Türkçe](README.tr.md)

A GUI tool that turns an original Windows 10 or Windows 11 ISO into a **debloated, driver-injected, unattended-install** ISO, or writes it directly to a **USB drive**. It can also write any existing ISO to USB as-is, like Rufus. Originally designed for **Proxmox** virtual machines (VirtIO drivers), but the result works on regular PCs too.

It is a single PowerShell file and can optionally be compiled to an `.exe`.

**Download:** get the ready-to-run `WindowsIsoBuilder.exe` from the [Releases](https://github.com/inversa-bilisim/windows-iso-builder/releases) page.

---

## Files

| File | Description |
|---|---|
| `WindowsIsoBuilder.ps1` | The program itself (GUI + build engine in one file) |
| `Build-EXE.cmd` | Builds `WindowsIsoBuilder.exe` with `ps2exe` |
| `WindowsIsoBuilder.ico` | Program icon |

## Requirements

- Windows 10 or 11 (the machine running the program)
- Administrator rights — if started without them, the program relaunches itself elevated
- **Windows ADK – Deployment Tools** (`oscdimg.exe`) — **only needed to build an ISO file**; if missing, clicking "BUILD ISO" offers to install it via winget (~100 MB). Not needed for writing to USB
- **~15 GB free space** for the working folder (when writing an existing ISO, only about the size of install.wim, ~6 GB)
- Duration: **20–40 minutes** depending on disk speed (writing an existing ISO to USB: 5–20 minutes)

## Running

**Ready-made EXE:** download `WindowsIsoBuilder.exe` from the [Releases](https://github.com/inversa-bilisim/windows-iso-builder/releases) page and run it.

**Build the EXE yourself:** double-click `Build-EXE.cmd`. It installs the `ps2exe` module if needed and creates `WindowsIsoBuilder.exe` in the same folder.

**Run the script directly:**
```powershell
powershell -ExecutionPolicy Bypass -File .\WindowsIsoBuilder.ps1
```

The interface language follows the Windows language (Turkish / English) and can be switched from the list at the top right.

---

## Interface

| Field | Description |
|---|---|
| **Windows ISO** | Source Windows 10/11 ISO. When selected, its editions are read and Win10/Win11 is detected automatically |
| **VirtIO ISO** *(optional)* | `virtio-win.iso` — Proxmox drivers are taken from here |
| **Driver folder** *(optional)* | Any driver folder containing `.inf` files (subfolders are scanned) |
| **Output** | **ISO file** or **USB drive (setup)**. With USB selected, checking **"Write the ISO as-is (no changes)"** writes the chosen ISO without any modification (customization options are disabled) |
| **Output ISO** | *(ISO mode)* Path of the ISO to create. Named automatically after the selected edition (e.g. `Win11-Pro-Custom.iso`) |
| **USB drive** | *(USB mode)* Target drive. By default only USB/SD drives are listed; check **All disks** to also show internal disks (SATA, NVMe etc.). Use **Refresh** after plugging in a drive |
| **Working folder** | Temporary files (default `C:\WindowsIsoBuild`). Cleaned on every run |
| **Edition** | One of the editions in the ISO; *Pro* is selected by default. Only this edition is kept in the result |
| **Username / Password** | Local administrator account to create automatically (password at least 4 characters) |
| **Locale** | Setup and system language (e.g. `en-US`, `tr-TR`) |
| **Remove bloatware** | Turns the cleanup steps below on/off |
| **Unattended setup** | Adds `autounattend.xml` |
| **Windows features** | Optional features to enable in the image |

The main button reads **BUILD ISO** or **WRITE TO USB** depending on the output. Progress is shown live in the log area at the bottom; **Cancel** stops the job. Full log: `%TEMP%\WindowsIsoBuilder-build.log`

---

## Features

### Drivers
- Windows 11 (or Windows 10) amd64 drivers are taken from the VirtIO ISO: `viostor`, `vioscsi`, `NetKVM`, `Balloon`, `vioserial`, `vioinput`, `viorng`, `pvpanic`, `viofs`, `viogpudo`, `qxldod`, `fwcfg`, `smbus`
- Drivers are added both to the **setup environment** (`boot.wim` — disks and network are visible during setup) and to the **installed system** (`install.wim`)
- MSI packages from the VirtIO ISO (including the guest agent) are copied to the `\virtio\` folder of the result
- Drivers from the optional driver folder are added as well

### Hardware checks
- TPM, Secure Boot, RAM, CPU and storage checks are bypassed — Windows 11 installs on unsupported hardware / VMs without TPM
- The internet / Microsoft account requirement is removed (`BypassNRO`)

### Windows 10 support
- Win10 setup continues without asking for a product key (`ei.cfg`)
- Extra Win10-only features are listed: Internet Explorer 11, Windows Media Player, Windows Fax and Scan

### Windows features (optional)
.NET Framework 3.5, Hyper-V, Windows Sandbox, Virtual Machine Platform, WSL, Telnet, TFTP, IIS, DirectPlay, SMB 1.0, XPS Document Writer, Microsoft Print to PDF, Internet Printing, Work Folders.
Selected by default: **.NET Framework 3.5** and **Microsoft Print to PDF**.

### Bloatware removal
*(when "Remove bloatware" is checked)*
- Removed apps: Xbox apps, Teams, Outlook (new), Copilot, Clipchamp, Bing News/Weather/Search, Office Hub, Solitaire, People, Power Automate, To Do, Feedback Hub, Maps, Phone Link, Groove/Movies & TV, Dev Home, Cortana, Quick Assist, Alarms, Sticky Notes, plus Win10-only Skype, 3D Viewer, Paint 3D, Mixed Reality etc.
- **OneDrive** is removed and prevented from reinstalling
- **Start menu** (Win11): promoted pins are replaced with Settings, File Explorer, Edge, Calculator, Notepad, Terminal, Photos, Snipping Tool, Control Panel
- **Start menu** (Win10): empty layout without tiles
- **Taskbar**: only File Explorer and Edge pinned

### Privacy and ads
- Telemetry, error reporting, CEIP and advertising ID disabled
- Start menu suggestions, lock screen ads and silent app installs disabled
- Windows Copilot, News and Interests / Widgets and search box suggestions disabled
- Windows Spotlight disabled

### Desktop and taskbar
- Taskbar aligned **left**; search box, Task View, Widgets and Copilot buttons hidden
- **This PC** and **user folder** icons on the desktop
- File Explorer opens to **This PC**
- "Recently added / recommended" in Start disabled
- Print Screen key does not open the Snipping Tool
- Screen saver off, default Windows wallpaper
- These settings are also applied at every new user's first sign-in (Active Setup)

### Microsoft Edge
First-run experience, sign-in / sync prompts, "make default browser" nags, shopping assistant, sidebar, new tab content, background mode and telemetry are disabled.

### Power and keyboard
- Hibernation and **Fast Startup** disabled
- Sleep, display off and disk off: **never**
- **NumLock** is **on** at the sign-in screen; within a session it remembers the user's last state

### Unattended setup (`autounattend.xml`)
*(when "Unattended setup" is checked)*
- Keyboard and region follow the selected locale; time zone is fixed to **Turkey** (`Turkey Standard Time`)
- License agreement, online account and wireless setup screens are skipped
- A **local administrator account** is created with the given username and password
- The privacy settings screen is not shown (all off)
- No updates are downloaded during setup
- **Disk selection is manual** — setup asks which disk to install to

### Writing to USB
- The drive is **completely erased**; confirmation with the drive name and size is required before writing (default answer *No*)
- The disk Windows is running from is **never** listed; internal disks only appear when **All disks** is checked, with an extra warning in the confirmation
- The disk holding the source ISO or the working folder cannot be selected (it would be erased while writing)
- If the drive changes after selection (unplugged and another one inserted), writing is cancelled
- Layout: **MBR + a single FAT32 partition** → boots on **UEFI** (including with Secure Boot on) and **legacy BIOS**
- `install.wim` larger than 4 GB is automatically split into `install.swm` parts because of the FAT32 limit (supported by Windows Setup)
- Windows can format FAT32 up to 32 GB, so on larger drives the partition is 32 GB and the rest is left unallocated
- USB NVMe enclosures and external SSDs are supported
- Unlike Rufus: the `autounattend.xml` in the ISO is preserved and no extra bootloader (UEFI:NTFS) is needed

---

## Recommended Proxmox VM settings

| Setting | Value |
|---|---|
| BIOS | OVMF (UEFI) + EFI disk |
| TPM | Not required |
| Disk | VirtIO SCSI |
| Network | VirtIO |

After installation, install the **guest agent** MSI from the `\virtio\` folder on the ISO.

---

## Notes

- The unattended password is stored in **plain text** in `autounattend.xml` inside the ISO. Change it after installation if you share the ISO.
- Default username is `Inversa`, password `1234` — change them in the interface.
- If writing to USB is interrupted, the drive may be left unusable; simply start the write again.
- If a build is interrupted (cancel, power loss etc.), leftover mounts are cleaned up automatically on the next run. If that fails, run `dism /cleanup-wim` in an elevated command prompt and delete the working folder, or restart the computer.
- Headless use: while the program runs, the engine is written to `%TEMP%\Build-WindowsIso.ps1`; it can also be run directly with parameters:
  ```powershell
  .\Build-WindowsIso.ps1 -WindowsIso C:\iso\Win11.iso -VirtioIso C:\iso\virtio-win.iso `
      -OutputIso C:\iso\Win11-Proxmox.iso -Edition "Windows 11 Pro" -UserName User -Password "Pass123" `
      -Features NetFx3 [-KeepBloat] [-SkipUnattend]
  ```
  The USB parameters (`-Target Usb`, `-WriteOnly`, `-UsbDisk`, `-UsbDiskSig`) require disk verification, so using them through the interface is recommended.

---

## License

[MIT](LICENSE) — free to use, modify and distribute in personal and commercial projects, open or closed source. The only condition is keeping the copyright and license notice. The software is provided "as is"; the authors are not liable for any consequences of its use, including disk erasure.
