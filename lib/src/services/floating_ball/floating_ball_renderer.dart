/// 悬浮球离屏渲染器 — 三变体 + 动态内容层（方案 A2/A7）。
///
/// 静态变体（可缓存）：idle / dragTarget；
/// 动态层：active（速度文本 + 环形进度 + 角标，数据驱动重绘）。
///
/// 输出双格式（A6）：
/// - Windows：premultiplied BGRA（UpdateLayeredWindow）
/// - macOS/Linux：straight-alpha RGBA（channel pushBitmap）
library;

import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:shadcn_ui/shadcn_ui.dart';

import '../../theme/flux_theme_tokens.dart';
import '../app_icon_service.dart';
import '../log_service.dart';
import '../native_overlay/offscreen_rasterizer.dart';

// =============================================================================
// Logo 预解码（idle 态球心图标）
// =============================================================================

/// 已解码的 logo 位图；null = 尚未加载（渲染时回退箭头图标）。
ui.Image? ballLogoImage;

/// 当前已加载的 logo 来源标识（`asset` 或 `custom#<revision>`），
/// 用于在应用图标切换后触发重载。
String? _loadedLogoKey;

/// 预解码 logo（按来源幂等）。FloatingBallService.enable() 前 await 一次；
/// 应用图标切换后再次调用即重载为新来源。
///
/// 来源跟随「设置-外观-应用图标」：自定义图标启用且预览 PNG 存在时用预览
/// （256px），内置「闪电」启用时用其打包资源，否则用内置 asset logo。
Future<void> ensureBallLogoLoaded() async {
  final iconSvc = AppIconService.instance;
  final customPath = iconSvc.isCustom ? iconSvc.previewPngPath : null;
  final String key;
  if (iconSvc.isBolt) {
    key = 'bolt';
  } else if (customPath != null) {
    key = 'custom#${iconSvc.previewRevision}';
  } else {
    key = 'asset';
  }
  if (ballLogoImage != null && _loadedLogoKey == key) return;
  try {
    final Uint8List bytes;
    if (customPath != null) {
      bytes = await File(customPath).readAsBytes();
    } else {
      final asset = iconSvc.isBolt
          ? AppIconService.builtinBoltAsset
          : 'assets/logo/ldownload_logo.png';
      final data = await rootBundle.load(asset);
      bytes = data.buffer.asUint8List();
    }
    final codec = await ui.instantiateImageCodec(
      bytes,
      // 按最大 3x DPI 预留解码尺寸，避免上采样发糊
      targetWidth: ((kBallDiameter - 10) * 3).round(),
    );
    // 旧位图不主动 dispose：在途渲染可能仍引用，交由 GC finalizer 回收
    ballLogoImage = (await codec.getNextFrame()).image;
    _loadedLogoKey = key;
  } catch (e) {
    logError('BallRenderer', 'logo decode failed, fallback icon', e);
  }
}

// =============================================================================
// 规格常量（逻辑像素）— A7
// =============================================================================

/// 球体直径
const double kBallDiameter = 44;

/// 窗口逻辑尺寸（含 6px 阴影出血 × 2）
const double kBallWindowSize = 56;

/// 阴影出血
const double kBallShadowPad = (kBallWindowSize - kBallDiameter) / 2;

/// 圆形命中半径（逻辑像素，物理侧按 DPI scale 换算）
const double kBallHitRadius = kBallDiameter / 2;

// =============================================================================
// 渲染输入 / 输出
// =============================================================================

/// 球体视觉变体
enum BallVariant { idle, active, dragTarget }

/// 单帧位图（straight-alpha RGBA + premultiplied BGRA 双份按需产出）
class BallImage {
  final int width;
  final int height;

  /// straight-alpha RGBA（macOS/Linux channel 用）
  final Uint8List rgba;

  const BallImage(this.width, this.height, this.rgba);

  /// premultiplied BGRA（Windows UpdateLayeredWindow 用）
  Uint8List toBgraPremultiplied() => rgbaToPremultipliedBgra(rgba);
}

/// active 态渲染参数
class BallActiveSpec {
  /// 速度文本（如 "12.4M/s"，空串 = 不显示）
  final String speedText;

  /// 活跃任务数（角标）
  final int activeCount;

  /// 聚合进度 0..1；null = 不确定（环形显示不确定样式）
  final double? aggregateProgress;

  const BallActiveSpec({
    required this.speedText,
    required this.activeCount,
    required this.aggregateProgress,
  });

  @override
  bool operator ==(Object other) =>
      other is BallActiveSpec &&
      other.speedText == speedText &&
      other.activeCount == activeCount &&
      other.aggregateProgress == aggregateProgress;

  @override
  int get hashCode => Object.hash(speedText, activeCount, aggregateProgress);
}

// =============================================================================
// 渲染入口
// =============================================================================

/// 渲染一帧悬浮球位图。
///
/// [variant]=active 时必须提供 [activeSpec]。
/// `scale` 为目标显示器 DPI/96（Windows）或 backingScaleFactor（macOS）。
Future<BallImage> renderBallImage({
  required BallVariant variant,
  required FluxThemeTokens tokens,
  required double scale,
  BallActiveSpec? activeSpec,
  double wavePhase = 0,
  double waveLevel = 0,
}) async {
  assert(
    variant != BallVariant.active || activeSpec != null,
    'active variant requires activeSpec',
  );
  final (w, h, rgba) = await rasterizeWidgetRgba(
    _BallWidget(
      variant: variant,
      tokens: tokens,
      activeSpec: activeSpec,
      wavePhase: wavePhase,
      waveLevel: waveLevel,
    ),
    logicalSize: const Size(kBallWindowSize, kBallWindowSize),
    scale: scale,
  );
  return BallImage(w, h, rgba);
}

// =============================================================================
// 球体 widget
// =============================================================================

class _BallWidget extends StatelessWidget {
  final BallVariant variant;
  final FluxThemeTokens tokens;
  final BallActiveSpec? activeSpec;
  final double wavePhase;
  final double waveLevel;

  const _BallWidget({
    required this.variant,
    required this.tokens,
    this.activeSpec,
    this.wavePhase = 0,
    this.waveLevel = 0,
  });

  @override
  Widget build(BuildContext context) {
    final accent = tokens.accent;
    final bg = tokens.surface1;
    final isDragTarget = variant == BallVariant.dragTarget;
    final spec = activeSpec;
    final logo = ballLogoImage;
    // idle 态且 logo 可用：logo 直接铺满整球（无底色圈/边框）
    final logoFillsBall = variant == BallVariant.idle && logo != null;

    return Center(
      child: SizedBox(
        width: kBallDiameter,
        height: kBallDiameter,
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            // ── 球体主体 ──
            Container(
              width: kBallDiameter,
              height: kBallDiameter,
              decoration: BoxDecoration(
                color: logoFillsBall
                    ? null
                    : (isDragTarget ? accent.withValues(alpha: 0.92) : bg),
                shape: BoxShape.circle,
                border: logoFillsBall
                    ? null
                    : Border.all(
                        color: isDragTarget
                            ? accent
                            : tokens.border.withValues(alpha: 0.8),
                        width: isDragTarget ? 2 : 1,
                      ),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.25),
                    blurRadius: 8,
                    offset: const Offset(0, 2),
                  ),
                ],
              ),
              child: _ballBody(
                logoFillsBall: logoFillsBall,
                logo: logo,
                isDragTarget: isDragTarget,
                accent: accent,
                spec: spec,
              ),
            ),
            // ── 活跃数角标 ──
            if (variant == BallVariant.active && (spec?.activeCount ?? 0) > 0)
              Positioned(
                top: -4,
                right: -4,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 5,
                    vertical: 1,
                  ),
                  decoration: BoxDecoration(
                    color: accent,
                    borderRadius: BorderRadius.circular(9),
                    border: Border.all(color: bg, width: 1.5),
                  ),
                  constraints: const BoxConstraints(minWidth: 18),
                  child: Text(
                    '${spec!.activeCount > 99 ? '99+' : spec.activeCount}',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontFamily: 'MiSans',
                      fontSize: 10,
                      fontWeight: FontWeight.w600,
                      color: _contrastOn(accent),
                      height: 1.3,
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// 球体主体内容：idle=铺满 logo；active=波浪进度 + 速度文本；其余=图标。
  Widget _ballBody({
    required bool logoFillsBall,
    required ui.Image? logo,
    required bool isDragTarget,
    required Color accent,
    required BallActiveSpec? spec,
  }) {
    if (logoFillsBall) {
      return ClipOval(
        child: RawImage(
          image: logo,
          width: kBallDiameter,
          height: kBallDiameter,
          fit: BoxFit.cover,
          filterQuality: FilterQuality.medium,
        ),
      );
    }
    if (variant == BallVariant.active && spec != null) {
      return ClipOval(
        child: Stack(
          fit: StackFit.expand,
          children: [
            CustomPaint(
              painter: _WaveProgressPainter(
                level: waveLevel,
                phase: wavePhase,
                color: accent,
              ),
            ),
            _buildContent(isDragTarget, accent),
          ],
        ),
      );
    }
    return _buildContent(isDragTarget, accent);
  }

  Widget _buildContent(bool isDragTarget, Color accent) {
    if (isDragTarget) {
      return Icon(
        LucideIcons.plus,
        size: 20,
        color: _contrastOn(accent),
      );
    }
    final spec = activeSpec;
    if (variant == BallVariant.active && spec != null) {
      // 速度文本居中（形如 "12.4M"，去掉 "/s" 省空间）
      final compact = spec.speedText
          .replaceAll('/s', '')
          .replaceAll(' ', '')
          .replaceAll('B', '');
      return Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(
              compact,
              maxLines: 1,
              style: TextStyle(
                fontFamily: 'MiSans',
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: tokens.textPrimary,
                height: 1.0,
              ),
            ),
          ),
        ),
      );
    }
    // idle 无 logo 时走兜底（logo 可用时已在 build 里整球填充，不进本方法）
    // logo 未就绪的兜底（首帧竞态）
    return Icon(
      LucideIcons.arrowDownToLine,
      size: 18,
      color: tokens.textMuted,
    );
  }

  /// 强调色上的对比前景色
  static Color _contrastOn(Color c) =>
      c.computeLuminance() > 0.5 ? const Color(0xFF18181B) : Colors.white;
}

/// 迅雷风格波浪进度画笔 — 水位随进度自底上浮，双层正弦波持续波动。
///
/// 画布为球体外接方形，由父级 [ClipOval] 裁成圆形；[level] 0..1 为水位高度，
/// [phase] 为动画相位（弧度，由服务层计时器持续推进）。
class _WaveProgressPainter extends CustomPainter {
  final double level;
  final double phase;
  final Color color;

  _WaveProgressPainter({
    required this.level,
    required this.phase,
    required this.color,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    final lv = level.clamp(0.0, 1.0);
    final baseY = h * (1 - lv);
    // 振幅在满/空两端收窄，避免越界抖动
    final amp = 2.4 * math.sin(math.pi * lv) + 0.6;
    _paintWave(
      canvas, w, h, baseY, amp, phase, 1.1,
      color.withValues(alpha: 0.36),
    );
    _paintWave(
      canvas, w, h, baseY - 1.0, amp * 0.78, phase + math.pi * 0.85, 1.6,
      color.withValues(alpha: 0.60),
    );
  }

  void _paintWave(
    Canvas canvas,
    double w,
    double h,
    double baseY,
    double amp,
    double phase,
    double freq,
    Color c,
  ) {
    final k = 2 * math.pi * freq / w;
    final path = Path()..moveTo(0, baseY + amp * math.sin(phase));
    for (var x = 1.5; x <= w; x += 1.5) {
      path.lineTo(x, baseY + amp * math.sin(k * x + phase));
    }
    path
      ..lineTo(w, h)
      ..lineTo(0, h)
      ..close();
    canvas.drawPath(path, Paint()..color = c);
  }

  @override
  bool shouldRepaint(_WaveProgressPainter old) =>
      old.level != level || old.phase != phase || old.color != color;
}
