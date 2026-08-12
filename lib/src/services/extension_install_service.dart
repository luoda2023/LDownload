import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:archive/archive_io.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import 'platform_utils.dart';

/// 浏览器扩展内置安装服务。
///
/// 将 Chrome/Edge/Firefox 扩展包内置到 App assets 中，用户在「关于」页点击
/// 对应按钮即可一键释放扩展并唤起浏览器完成安装，无需跳转网页下载。
/// 若当前构建未内嵌扩展包（如本地开发），返回 [InstallResult.assetMissing]，
/// UI 应提示用户去 GitHub Release 手动下载或先放置资源文件。
class ExtensionInstallService {
  static const String _chromeAsset = 'assets/extensions/ldownload-chrome.zip';
  static const String _firefoxAsset = 'assets/extensions/ldownload-firefox.xpi';

  static const String _chromeId = 'meleenglfggcmcajknpeeeiobnpfmahc';
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

  /// 安装 Firefox 扩展（侧载 XPI）。
  static Future<InstallResult> installFirefox() async {
    if (!Platform.isWindows && !Platform.isMacOS && !Platform.isLinux) {
      return InstallResult.notSupported;
    }

    final bytes = await _loadAssetBytes(_firefoxAsset);
    if (bytes == null) return InstallResult.assetMissing;

    final dataDir = resolveDataDir();
    final extDir = Directory(p.join(dataDir, 'extensions'));
    await extDir.create(recursive: true);

    final xpiPath = p.join(extDir.path, 'ldownload-firefox.xpi');
    await File(xpiPath).writeAsBytes(bytes);

    final firefoxExe = await _findBrowserExe('firefox');
    if (firefoxExe == null) {
      return InstallResult.browserNotFound;
    }

    // Firefox 打开 file:///*.xpi 会触发安装提示。
    await Process.run(firefoxExe, [Uri.file(xpiPath).toString()]);
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
    // 若浏览器已运行，可能无法重新加载；此时提示用户关闭浏览器再点一次。
    await Process.run(exe, ['--load-extension=$loadDir']);
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
