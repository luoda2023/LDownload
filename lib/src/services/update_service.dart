/// Application version injected at build time.
const _appVersion = String.fromEnvironment('APP_VERSION', defaultValue: 'dev');

/// Singleton holding the current app version and a few byte-formatting helpers.
///
/// Auto-update / automatic upgrade has been disabled; this service no longer
/// checks, downloads, or installs updates.
class UpdateService {
  UpdateService._();

  static final instance = UpdateService._();

  /// Current app version.
  String get currentVersion => _appVersion;

  /// Format bytes to human-readable string.
  static String formatBytes(int bytes) {
    if (bytes <= 0) return '0 B';
    const units = ['B', 'KB', 'MB', 'GB'];
    int i = 0;
    double size = bytes.toDouble();
    while (size >= 1024 && i < units.length - 1) {
      size /= 1024;
      i++;
    }
    return '${size.toStringAsFixed(i == 0 ? 0 : 1)} ${units[i]}';
  }

  /// Format speed to human-readable string.
  static String formatSpeed(int bytesPerSec) {
    return '${formatBytes(bytesPerSec)}/s';
  }
}
