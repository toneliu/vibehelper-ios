/// Compile-time client metadata supplied via `--dart-define` with safe defaults.
class AppBuildInfo {
  AppBuildInfo._();

  static const String appVersion =
      String.fromEnvironment('VH_APP_VERSION', defaultValue: '0.7.0');
  static const int buildNumber =
      int.fromEnvironment('VH_BUILD_NUMBER', defaultValue: 7);
  static const int nativeVersion =
      int.fromEnvironment('VH_NATIVE_VERSION', defaultValue: 8);
  static const String nativeFingerprint =
      String.fromEnvironment('VH_NATIVE_FP', defaultValue: '');
  static const String dartFingerprint =
      String.fromEnvironment('VH_DART_FP', defaultValue: '');
  static const String buildId =
      String.fromEnvironment('VH_BUILD_ID', defaultValue: 'local');
}
