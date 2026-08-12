import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import 'platform_utils.dart';
import 'log_service.dart';

/// 浏览器扩展内置安装服务。
///
/// 将 Chrome/Edge/Firefox 扩展包内置到 App assets 中，用户在「关于」页点击
/// 对应按钮即可一键释放扩展并唤起浏览器完成安装，无需跳转网页下载。
/// 若当前构建未内嵌扩展包（如本地开发），返回 [InstallResult.assetMissing]，
/// UI 应提示用户去 GitHub Release 手动下载或先放置资源文件。
class ExtensionInstallService {
  static const String _chromeAsset = 'assets/extensions/ldownload-chrome.zip';
  static const String _firefoxAsset = 'assets/extensions/ldownload-firefox.xpi';

  // Chrome 扩展固定 ID：meleenglfggcmcajknpeeeiobnpfmahc（侧载含 key，ID 稳定）
  // Firefox 扩展 ID：ldownload@ldownload.app
  // 两 ID 均硬编码于 native/hub/src/nmh_registry.rs 的 allowed_origins /
  // allowed_extensions，勿改此处值（此处仅为文档性常量，不参与安装逻辑）。
  // ignore: unused_field
  static const String _chromeId = 'meleenglfggcmcajknpeeeiobnpfmahc';
  // ignore: unused_field
  static const String _firefoxId = 'ldownload@ldownload.app';

  /// 安装 Chrome 扩展（侧载）。
  static Future<InstallResult> installChrome() async {
    return _installChromium('chrome', 'Chrome');
  }

  /// 安装 Edge 扩展（侧载）。
  /// Edge 商店包剔除了 key，侧载无法固定 ID；因此复用 Chrome 包（含 key），
  /// 其扩展 ID 已列入 NMH allowed_origins，Native Messaging 可正常通信。
  static Future<InstallResult> installEdge() async {
    return _installChromium('edge', 'Edge');
  }

  /// 安装 Firefox 扩展。
  ///
  /// 双路线：
  /// 1. 若 assets 内嵌了签名 XPI（CI 正常产出时）→ 解压到目录，打开
  ///    `about:debugging` 引导「临时加载附加组件」（Firefox 109+ 仍支持
  ///    about:debugging 临时加载未签名扩展；`file://*.xpi` 直开安装已被
  ///    Firefox 移除，旧实现不可用）。
  /// 2. 若 XPI 缺失（AMO 签名凭据失效导致 CI 未产出，v10.0.3/v10.0.4 实际
  ///    如此）→ 返回 [InstallResult.assetMissing] 并提示去 GitHub Release
  ///    手动下载。**注意**：缺失时绝不能让用户去 about:debugging 加载空目录
  ///    （旧实现假成功：目录是空的却返回 success）。
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
      // 解压失败视为资源损坏。
      return InstallResult.assetMissing;
    }

    final firefoxExe = await _findBrowserExe('firefox');
    if (firefoxExe == null) {
      return InstallResult.browserNotFound;
    }

    // 打开 about:debugging，用户在 UI 引导下点「临时加载附加组件」→ 选择
    // 解压目录（含 manifest.json）。比 file://*.xpi 可靠（后者已被移除）。
    await Process.run(firefoxExe, ['about:debugging']);
    return InstallResult.success;
  }

  static Future<InstallResult> _installChromium(
    String browserKey,
    String browserName,
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

    // 解压到 chrome-mv3/，load-extension 需要指向 manifest.json 所在目录。
    final archive = ZipDecoder().decodeBytes(zipBytes);
    extractArchiveToDisk(archive, extRoot.path);

    // CI 打包的是 chrome-mv3/ 子目录，所以实际 manifest 在 chrome-mv3/chrome-mv3/ 下。
    // 优先尝试 chrome-mv3/ 子目录，否则用 extRoot 本身。
    final nestedDir = Directory(p.join(extRoot.path, 'chrome-mv3'));
    final loadDir = await nestedDir.exists() ? nestedDir.path : extRoot.path;

    final exe = await _findBrowserExe(browserKey);
    if (exe == null) {
      return InstallResult.browserNotFound;
    }

    // 启动浏览器并加载扩展。
    // 注意：Chrome 137+ 移除了 `--load-extension` 命令行侧载（2025-06），
    // 该参数在旧版仍有效。因此双管齐下：
    //   1) 传 --load-extension（旧版 Chrome / 部分 Edge 分支生效）
    //   2) 同时打开 chrome://extensions，引导用户开启「开发者模式」手动
    //      「加载已解压的扩展程序」——新版本 Chrome/Edge 的唯一可靠路径。
    // 若浏览器已运行，新进程参数可能被忽略；引导页仍会打开。
    await Process.run(exe, ['--load-extension=$loadDir']);
    await Process.run(exe, [browserKey == 'edge' ? 'edge://extensions' : 'chrome://extensions']);
    return InstallResult.success;
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
      final pf86 = Platform.environment['ProgramFiles(x86)'] ?? r'C:\Program Files (x86)';
      return switch (browser) {
        'chrome' => [
          p.join(pf, r'Google\Chrome\Application\chrome.exe'),
          p.join(pf86, r'Google\Chrome\Application\chrome.exe'),
          p.join(Platform.environment['LOCALAPPDATA'] ?? '', r'Google\Chrome\Application\chrome.exe'),
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
