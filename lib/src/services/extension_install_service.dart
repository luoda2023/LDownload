import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import '../bindings/bindings.dart';
import 'log_service.dart';
import 'platform_utils.dart';

/// 浏览器扩展内置安装服务。
///
/// **为什么不是「一键装好」**：Chrome 137+（2025-06）已移除
/// `--load-extension` 命令行侧载，Firefox 也移除了 `file://*.xpi` 直开安装。
/// 因此本服务的「安装」实为「解压 + 引导」四步：
///
/// 1. 把内嵌扩展包解压到应用数据目录的稳定路径；
/// 2. 打开浏览器的扩展管理页（chrome://extensions / edge://extensions /
///    about:debugging#/runtime/this-firefox）——Chrome 137+ 唯一可靠入口；
/// 3. 同时在系统文件管理器里打开解压目录，让用户「加载已解压的扩展程序 /
///    临时加载附加组件」时一步选到（无需手动翻路径）；
/// 4. 触发 [RepairNmhRegistration] 信号注册 Native Messaging Host（NMH），
///    否则扩展即使装上也无法与桌面端通信（此前「装上了但连不上」的根因）。
///
/// 若当前构建未内嵌扩展包（如本地开发 / CI 未注入），返回
/// [InstallResult.assetMissing]，UI 应展示 [ExtensionInstallService.releaseUrl]
/// 让用户去 GitHub Release 手动下载扩展包。
class ExtensionInstallService {
  static const String _chromeAsset = 'assets/extensions/ldownload-chrome.zip';
  static const String _firefoxAsset = 'assets/extensions/ldownload-firefox.xpi';

  /// 官方发布页（内置包缺失时引导用户手动下载扩展包）。
  static const String releaseUrl =
      'https://github.com/luoda2023/LDownload/releases';

  // Chrome 扩展固定 ID：meleenglfggcmcajknpeeeiobnpfmahc（侧载含 key，ID 稳定）
  // Firefox 扩展 ID：ldownload@ldownload.app
  // 两 ID 均硬编码于 native/hub/src/nmh_registry.rs 的 allowed_origins /
  // allowed_extensions，勿改此处值（此处仅为文档性常量，不参与安装逻辑）。
  // ignore: unused_field
  static const String _chromeId = 'meleenglfggcmcajknpeeeiobnpfmahc';
  // ignore: unused_field
  static const String _firefoxId = 'ldownload@ldownload.app';

  /// 安装 Chrome 扩展（引导式侧载）。
  static Future<InstallResult> installChrome() async {
    return _installChromium('chrome', 'Chrome', 'chrome://extensions');
  }

  /// 安装 Edge 扩展（引导式侧载）。
  /// Edge 商店包剔除了 key，侧载无法固定 ID；因此复用 Chrome 包（含 key），
  /// 其扩展 ID 已列入 NMH allowed_origins，Native Messaging 可正常通信。
  static Future<InstallResult> installEdge() async {
    return _installChromium('edge', 'Edge', 'edge://extensions');
  }

  /// 安装 Firefox 扩展（引导式临时加载）。
  ///
  /// Firefox 109+ 已移除 `file://*.xpi` 直开安装；未签名 XPI 只能经
  /// `about:debugging#/runtime/this-firefox`「临时加载附加组件」加载。
  /// 解压目录稳定在 `dataDir/extensions/firefox-mv2/`。
  static Future<InstallResult> installFirefox() async {
    if (!Platform.isWindows && !Platform.isMacOS && !Platform.isLinux) {
      return InstallResult.notSupported;
    }

    // 读取内嵌 XPI；缺失直接返回 assetMissing（空目录无法临时加载）。
    final bytes = await _loadAssetBytes(_firefoxAsset);
    if (bytes == null) return InstallResult.assetMissing;

    final dataDir = resolveDataDir();
    final extRoot = Directory(p.join(dataDir, 'extensions', 'firefox-mv2'));
    await extRoot.create(recursive: true);
    await _clearDirectory(extRoot);

    // XPI 本质是 zip：解压为目录供 about:debugging 临时加载。
    try {
      final archive = ZipDecoder().decodeBytes(bytes);
      extractArchiveToDisk(archive, extRoot.path);
    } catch (e) {
      logInfo('extension_install', 'Firefox XPI 解压失败: $e');
      return InstallResult.assetMissing;
    }

    final firefoxExe = await _findBrowserExe('firefox');
    if (firefoxExe == null) {
      return InstallResult.browserNotFound;
    }

    // 注册 NMH：扩展 ↔ 桌面端通信的前置条件（幂等，hub 侧按浏览器补齐）。
    RepairNmhRegistration().sendSignalToRust();

    // 打开 about:debugging 临时加载页 + 文件管理器里的解压目录。
    await Process.run(firefoxExe, ['about:debugging#/runtime/this-firefox']);
    await _revealDirectory(extRoot.path);
    return InstallResult.success;
  }

  /// Chromium（Chrome/Edge）统一引导流。
  static Future<InstallResult> _installChromium(
    String browserKey,
    String browserName,
    String extensionsUrl,
  ) async {
    if (!Platform.isWindows && !Platform.isMacOS && !Platform.isLinux) {
      return InstallResult.notSupported;
    }

    final zipBytes = await _loadAssetBytes(_chromeAsset);
    if (zipBytes == null) return InstallResult.assetMissing;

    final dataDir = resolveDataDir();
    final extRoot = Directory(p.join(dataDir, 'extensions', 'chrome-mv3'));
    await extRoot.create(recursive: true);

    // 清空旧扩展目录。
    await _clearDirectory(extRoot);

    // 解压到 chrome-mv3/，Load unpacked 需要指向 manifest.json 所在目录。
    try {
      final archive = ZipDecoder().decodeBytes(zipBytes);
      extractArchiveToDisk(archive, extRoot.path);
    } catch (e) {
      logInfo('extension_install', '$browserName 扩展解压失败: $e');
      return InstallResult.assetMissing;
    }

    // CI 打包的是 chrome-mv3/ 子目录，所以实际 manifest 在
    // chrome-mv3/chrome-mv3/ 下。优先尝试子目录，否则用 extRoot 本身。
    final nestedDir = Directory(p.join(extRoot.path, 'chrome-mv3'));
    final loadDir = await nestedDir.exists() ? nestedDir.path : extRoot.path;

    final exe = await _findBrowserExe(browserKey);
    if (exe == null) {
      return InstallResult.browserNotFound;
    }

    // 注册 NMH：扩展 ↔ 桌面端通信的前置条件。
    RepairNmhRegistration().sendSignalToRust();

    // Chrome 137+ 移除 --load-extension，别再传该参数（会产生
    // "unsupported command-line flag" 黄条且无效）。只打开扩展管理页 +
    // 文件管理器目录，由用户在页面内「开发者模式 → 加载已解压的扩展程序」
    // 选择 loadDir —— 这是新版本 Chrome/Edge 唯一可靠路径。
    await Process.run(exe, [extensionsUrl]);
    await _revealDirectory(loadDir);
    return InstallResult.success;
  }

  /// 在系统文件管理器中打开目录（Explorer / Finder / Nautilus）。
  static Future<void> _revealDirectory(String path) async {
    try {
      if (Platform.isWindows) {
        await Process.run('explorer.exe', [path]);
      } else if (Platform.isMacOS) {
        await Process.run('open', [path]);
      } else if (Platform.isLinux) {
        await Process.run('xdg-open', [path]);
      }
    } catch (e) {
      logInfo('extension_install', '打开目录失败: $e');
    }
  }

  /// 从 Flutter assets 加载文件。
  static Future<List<int>?> _loadAssetBytes(String assetPath) async {
    try {
      final data = await rootBundle.load(assetPath);
      return data.buffer.asUint8List();
    } on MissingPluginException catch (_) {
      rethrow;
    } catch (_) {
      return null;
    }
  }

  /// 清理目录内容（保留目录本身）。
  static Future<void> _clearDirectory(Directory dir) async {
    if (!await dir.exists()) return;
    await for (final entity in dir.list()) {
      await entity.delete(recursive: true);
    }
  }

  /// 查找浏览器可执行文件路径（Windows 优先读注册表 App Paths）。
  static Future<String?> _findBrowserExe(String browser) async {
    if (Platform.isWindows) {
      final key = _browserRegKey(browser);
      final result = await Process.run('reg', [
        'query',
        key,
        '/ve',
      ]);
      if (result.exitCode == 0) {
        final path = _parseRegDefault(result.stdout.toString());
        if (path.isNotEmpty && await File(path).exists()) {
          return path;
        }
      }
    }

    // 跨平台兜底：常见安装路径。
    final candidates = _browserDefaultPaths(browser);
    for (final candidate in candidates) {
      if (await File(candidate).exists()) {
        return candidate;
      }
    }
    return null;
  }

  static String _browserRegKey(String browser) {
    final exe = switch (browser) {
      'chrome' => 'chrome.exe',
      'edge' => 'msedge.exe',
      'firefox' => 'firefox.exe',
      _ => '$browser.exe',
    };
    return 'HKLM\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\App Paths\\$exe';
  }

  static List<String> _browserDefaultPaths(String browser) {
    if (Platform.isWindows) {
      final pf = Platform.environment['ProgramFiles'] ?? r'C:\Program Files';
      final pf86 =
          Platform.environment['ProgramFiles(x86)'] ?? r'C:\Program Files (x86)';
      return switch (browser) {
        'chrome' => [
          p.join(pf, r'Google\Chrome\Application\chrome.exe'),
          p.join(pf86, r'Google\Chrome\Application\chrome.exe'),
          p.join(
            Platform.environment['LOCALAPPDATA'] ?? '',
            r'Google\Chrome\Application\chrome.exe',
          ),
        ],
        'edge' => [
          p.join(pf, r'Microsoft\Edge\Application\msedge.exe'),
          p.join(pf86, r'Microsoft\Edge\Application\msedge.exe'),
        ],
        'firefox' => [
          p.join(pf, r'Mozilla Firefox\firefox.exe'),
          p.join(pf86, r'Mozilla Firefox\firefox.exe'),
        ],
        _ => <String>[],
      };
    }
    if (Platform.isMacOS) {
      return switch (browser) {
        'chrome' => ['/Applications/Google Chrome.app/Contents/MacOS/Google Chrome'],
        'edge' => ['/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge'],
        'firefox' => ['/Applications/Firefox.app/Contents/MacOS/firefox'],
        _ => <String>[],
      };
    }
    if (Platform.isLinux) {
      return switch (browser) {
        'chrome' => ['/usr/bin/google-chrome', '/usr/bin/google-chrome-stable'],
        'edge' => ['/usr/bin/microsoft-edge', '/usr/bin/microsoft-edge-stable'],
        'firefox' => ['/usr/bin/firefox'],
        _ => <String>[],
      };
    }
    return <String>[];
  }

  static String _parseRegDefault(String output) {
    final lines = LineSplitter.split(output);
    for (final line in lines) {
      final trimmed = line.trim();
      if (trimmed.startsWith('(Default)') && trimmed.contains('REG_SZ')) {
        final idx = trimmed.lastIndexOf('REG_SZ');
        if (idx != -1) {
          return trimmed.substring(idx + 'REG_SZ'.length).trim();
        }
      }
    }
    return '';
  }
}

enum InstallResult {
  success,
  browserNotFound,
  assetMissing,
  notSupported,
}
