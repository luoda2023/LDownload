---
title: Installation
description: Install LDownload on Windows, macOS, or Linux and get it running for the first time.
section: getting-started
order: 1
---

LDownload ships full-featured native builds for Windows, macOS, and Linux. Every package contains the same Rust download engine and the same interface — there's no "lite" edition and no account to create.

## System Requirements

| Platform | Requirement |
|---|---|
| Windows | Windows 10 (64-bit) or later, x64 or ARM64 |
| macOS | macOS 10.15 (Catalina) or later, Apple Silicon or Intel |
| Linux | A 64-bit desktop distribution with a modern GTK3 stack |

## Windows

Grab a build from the [download page](/#download). Two options, both offered for x64 and ARM64:

- **Installer** — `LDownload-<version>-setup.exe`. Runs the standard Inno Setup wizard and installs for the current user only (no admin rights required). During setup you can optionally check boxes to create a desktop shortcut, launch LDownload at system startup, and associate `.torrent` files with LDownload — all unchecked by default.
- **Portable** — `LDownload-<version>-windows-<arch>-portable.zip`. Extract anywhere and run `ldownload.exe`. Nothing is written outside the extracted folder except whatever you opt into at first launch.

The build isn't code-signed, so Windows SmartScreen may flag it as coming from an "unknown publisher" the first time you run it. Click **More info → Run anyway** to continue.

### Scoop

If you use the [Scoop](https://scoop.sh) package manager, install LDownload from the LDownload bucket:

```powershell
scoop bucket add ldownload https://github.com/luoda2023/LDownload
scoop install ldownload/ldownload
```

This installs the portable build and keeps your `settings.json` across upgrades. Update anytime with `scoop update ldownload`.

## macOS

- **DMG** — `LDownload-<version>-macos-<arch>.dmg` (`arm64` for Apple Silicon, `x64` for Intel). Open it and drag LDownload into **Applications**.
- **Portable** — `LDownload-<version>-macos-<arch>.tar.gz`. Extract it and run the app bundle directly.

The build isn't notarized, so Gatekeeper blocks the first launch with an "unidentified developer" warning. Right-click (or Control-click) the app and choose **Open**, or approve it under **System Settings → Privacy & Security → Open Anyway**.

## Linux

All Linux packages are x64:

- **AppImage** — `LDownload-<version>-linux-x64.AppImage`. Make it executable (`chmod +x`) and run it. Distributions released in the last few years may need `libfuse2` installed for AppImages to launch.
- **deb** — `LDownload-<version>-linux-x64.deb`, for Debian/Ubuntu and derivatives: `sudo apt install ./LDownload-<version>-linux-x64.deb`.
- **Arch package** — `LDownload-<version>-linux-x64.pkg.tar.zst`: `sudo pacman -U LDownload-<version>-linux-x64.pkg.tar.zst`.
- **Portable** — `LDownload-<version>-linux-x64.tar.gz`. Extract it and run the bundled binary.

## First Launch

LDownload quietly wires itself into the OS the first time it starts, so links and files from other apps reach it without extra setup:

- **`ldownload://` protocol** — registered automatically on every startup so the browser extension and other apps can hand off downloads to LDownload.
- **Native Messaging Host** — registered automatically so the browser extension can talk to LDownload over Native Messaging (a Windows Named Pipe or a Linux/macOS Unix socket).
- **`.torrent` file association** — *not* automatic. If you didn't check the installer's association box, LDownload shows a one-time dialog on first launch asking whether to make it the default `.torrent` handler. Accept, dismiss, or change your mind later in **Settings → General → Associate .torrent Files**.

<!-- TODO(screenshot): 首次启动的 .torrent 文件关联提示对话框 -->

## Automatic Updates

Five seconds after startup, LDownload silently checks GitHub Releases for a newer version in the background (this can be turned off in **Settings → About → Auto-check for Updates**). If an update is available, a dialog shows the changelog with **Update Now** and **Remind Me Later**. You can trigger a manual check any time from **Settings → About**, or from the version indicator at the bottom of the sidebar.

## Uninstalling

- **Windows (installer)** — open **Settings → Apps → Installed apps**, find LDownload, and uninstall. For a portable install, just delete the extracted folder.
- **macOS** — drag LDownload from **Applications** to the Trash.
- **Linux** — `sudo apt remove ldownload` (deb), `sudo pacman -R ldownload` (Arch), or delete the AppImage/extracted folder.

Uninstalling only removes the application itself — files you've already downloaded stay wherever you saved them.
