import 'dart:async';

import 'package:flutter/widgets.dart';

import '../bindings/bindings.dart';
import '../i18n/locale_provider.dart';
import '../models/download_controller.dart';
import '../models/settings_provider.dart';
import '../theme/app_colors.dart';
import '../theme/app_metrics.dart';
import '../theme/theme_provider.dart';
import 'screens/mobile_settings_screen.dart';
import 'services/mobile_storage_service.dart';
import 'screens/mobile_tasks_screen.dart';
import 'services/share_intent_service.dart';
import 'mobile_ui.dart';
import 'sheets/mobile_new_download_sheet.dart';

/// 移动端根壳：任务列表主屏 + 右上角设置入口（push 路由进入设置页）
class MobileShell extends StatefulWidget {
  final ThemeProvider themeProvider;
  final LocaleNotifier localeNotifier;

  const MobileShell({
    super.key,
    required this.themeProvider,
    required this.localeNotifier,
  });

  @override
  State<MobileShell> createState() => _MobileShellState();
}

class _MobileShellState extends State<MobileShell> with WidgetsBindingObserver {
  final _controller = DownloadController();
  final _settings = SettingsProvider(enableFileAssoc: false);
  bool _sheetOpen = false;

  /// 新建下载弹层是否正在展示（区别于更新提示等其他弹层）。
  /// 弹层可见期间到达的分享 / 协议 URL 经 [_shareAppendCtrl] 合入表单，
  /// 支撑扩展批量协议唤起（逐条 VIEW intent，间隔 800ms）。
  bool _downloadSheetOpen = false;
  final _shareAppendCtrl = StreamController<String>.broadcast();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _settings.requestConfig();
    _ensureAndroidSaveDir();
    // 系统分享 / URL scheme 接入：收到链接切到下载页并弹新建下载弹层
    ShareIntentService.init(_onShared);
  }

  /// 收到系统分享 / URL scheme 唤起的链接：切到下载页，弹新建下载弹层
  /// 并预填 URL（ldownload:// 协议携带的建议文件名一并预填）。
  /// 新建下载弹层已打开时把 URL 追加进现有表单（批量协议唤起逐条到达）；
  /// 其他弹层（更新提示等）打开时忽略，避免叠层。
  Future<void> _onShared(String url, String filename) async {
    if (!mounted) return;
    if (_downloadSheetOpen) {
      _shareAppendCtrl.add(url);
      return;
    }
    if (_sheetOpen) return;
    // 若正在设置页，先回到任务列表
    Navigator.of(context).popUntil((r) => r.isFirst);
    _sheetOpen = true;
    _downloadSheetOpen = true;
    try {
      await showMobileNewDownloadSheet(
        context,
        controller: _controller,
        settings: _settings,
        initialUrl: url,
        initialFileName: filename,
        appendUrls: _shareAppendCtrl.stream,
      );
    } finally {
      _sheetOpen = false;
      _downloadSheetOpen = false;
    }
  }

  /// Android：让 framework 创建应用专属外部下载目录
  /// （`Android/data` 层禁止应用自建子树，Rust 引擎写入前必须初始化），
  /// 并在用户未自定义时把默认保存目录同步为 framework 返回的真实路径
  /// （多用户 / 特殊分区场景下与硬编码路径可能不同）。
  Future<void> _ensureAndroidSaveDir() async {
    final dir = await MobileStorageService.appExternalDownloadDir();
    if (dir == null || dir.isEmpty || !mounted) return;
    if (_settings.defaultSaveDir == SettingsProvider.platformDefaultSaveDir &&
        _settings.defaultSaveDir != dir) {
      _settings.setDefaultSaveDir(dir);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    ShareIntentService.shutdown();
    _shareAppendCtrl.close();
    _controller.dispose();
    _settings.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // 文件跟踪：回到前台时用户可能刚在文件管理器删/移了文件，触发一次重扫。
    if (state == AppLifecycleState.resumed) {
      RescanFiles().sendSignalToRust();
    }
  }

  void _openSettings() {
    Navigator.of(context).push(
      PageRouteBuilder<void>(
        transitionDuration: const Duration(milliseconds: 280),
        reverseTransitionDuration: const Duration(milliseconds: 240),
        pageBuilder: (_, _, _) => MobileSettingsScreen(
          settings: _settings,
          themeProvider: widget.themeProvider,
          localeNotifier: widget.localeNotifier,
        ),
        transitionsBuilder: (_, anim, _, child) {
          final curved = CurvedAnimation(
            parent: anim,
            curve: const Cubic(0.32, 0.72, 0.32, 1),
          );
          return SlideTransition(
            position: Tween<Offset>(
              begin: const Offset(1, 0),
              end: Offset.zero,
            ).animate(curved),
            child: child,
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);

    return Container(
      color: c.bg,
      child: Stack(
        children: [
          // 背景氛围光斑（品牌蓝，极低透明度）
          Positioned(
            top: -60,
            right: -40,
            child: _AmbientGlow(color: c.accent, size: 300),
          ),
          Positioned(
            bottom: -80,
            left: -60,
            child: _AmbientGlow(color: c.accent, size: 340),
          ),

          Positioned.fill(
            child: MobileTasksScreen(
              controller: _controller,
              settings: _settings,
              onOpenSettings: _openSettings,
            ),
          ),
        ],
      ),
    );
  }
}

/// 背景氛围光斑
class _AmbientGlow extends StatelessWidget {
  final Color color;
  final double size;

  const _AmbientGlow({required this.color, required this.size});

  @override
  Widget build(BuildContext context) {
    final m = AppMetrics.of(context);
    return IgnorePointer(
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: RadialGradient(
            colors: [m.soft(color), color.withValues(alpha: 0.0)],
          ),
        ),
      ),
    );
  }
}

