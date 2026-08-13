import 'dart:io';

/// 全局字体族：用户明确要求宋体（原 MiSans 黑体「有点怪」）。
///
/// 按平台选**系统已安装**的宋体/衬线中文字体，不捆绑字体资产（SimSun 属
/// 微软版权，不能随包分发；Noto Serif CJK 是 OFL 开源但体积大，走系统回退
/// 更轻量）：
///
/// - Windows → `SimSun`（宋体）
/// - macOS → `Songti SC`（宋体-简）
/// - Linux → `Noto Serif CJK SC`（开源衬线中文字体，主流发行版可选安装）
///
/// 目标平台未命中时回退 `SimSun`（Windows 是主目标；Flutter 对不存在的
/// 字体名会静默回退默认字体，不会崩溃）。
///
/// 注：主窗口（app_theme）、悬浮球、Win32 toast 三处渲染统一引用本 getter，
/// 保证「全部宋体」在应用各处一致。
String get appFontFamily {
  if (Platform.isWindows) {
    return 'SimSun';
  }
  if (Platform.isMacOS) {
    return 'Songti SC';
  }
  if (Platform.isLinux) {
    return 'Noto Serif CJK SC';
  }
  return 'SimSun';
}
