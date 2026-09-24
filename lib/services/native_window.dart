import 'package:flutter/services.dart';

/// windows/runner/flutter_window.cpp と対になるウィンドウ操作。
class NativeWindow {
  NativeWindow._();

  static const _ch = MethodChannel('message_manager/window');

  /// ユーザーがウィンドウの移動・リサイズを終えたときに呼ばれる。
  static void onBoundsChanged(void Function(Map<String, int> bounds) cb) {
    _ch.setMethodCallHandler((call) async {
      if (call.method == 'boundsChanged' && call.arguments is Map) {
        final m = call.arguments as Map;
        cb({
          for (final k in ['x', 'y', 'w', 'h']) k: (m[k] as num).toInt(),
        });
      }
      return null;
    });
  }

  static Future<void> _call(String m, [Map<String, Object?>? args]) async {
    try {
      await _ch.invokeMethod<Object?>(m, args);
    } on MissingPluginException {
      // Windows 以外（テスト時など）では何もしない。
    } on PlatformException {
      // 無視（位置が不正など）
    }
  }

  /// true: 他のウィンドウの下（デスクトップに貼り付け） / false: 通常の前面表示。
  static Future<void> setPinned(bool pinned) =>
      _call('setPinned', {'pinned': pinned});

  static Future<void> setBounds(Map<String, int> b) => _call('setBounds', b);

  static Future<void> setOpacity(double v) =>
      _call('setOpacity', {'value': v});

  static Future<void> startDrag() => _call('startDrag');

  /// edge: 1=左 2=右 3=上 4=左上 5=右上 6=下 7=左下 8=右下
  static Future<void> startResize(int edge) =>
      _call('startResize', {'edge': edge});

  static Future<void> close() => _call('close');

  static const calendarTitle = 'Message Manager Calendar';

  /// このウィンドウがあるモニターの作業領域（タスクバーを除く）。物理ピクセル。
  static Future<Map<String, int>?> getWorkArea() async {
    try {
      final m = await _ch.invokeMethod<Map<Object?, Object?>>('getWorkArea');
      if (m == null) return null;
      return {for (final k in ['x', 'y', 'w', 'h']) k: (m[k] as num).toInt()};
    } catch (_) {
      return null;
    }
  }

  /// 別の Message Manager ウィンドウ（予定のウィンドウ）を動かす。
  static Future<void> setBoundsOf(String title, Map<String, int> b) =>
      _call('setBoundsOf', {'title': title, ...b});

  /// 別の Message Manager ウィンドウを閉じる。
  static Future<void> closeByTitle(String title) =>
      _call('closeByTitle', {'title': title});
}
