import 'dart:io';

import 'package:url_launcher/url_launcher.dart';

/// Windows のログイン時自動起動（HKCU\...\Run への登録）と、外部アプリの起動。
class SystemIntegration {
  SystemIntegration._();

  static const _runKey = r'HKCU\Software\Microsoft\Windows\CurrentVersion\Run';
  static const _valueName = 'MessageManager';

  static Future<void> setAutostart(bool enabled) async {
    if (!Platform.isWindows) return;
    try {
      if (enabled) {
        final exe = Platform.resolvedExecutable;
        await _detached('reg', [
          'add', _runKey, '/v', _valueName, '/t', 'REG_SZ', //
          '/d', '"$exe"', '/f',
        ]);
      } else {
        await _detached('reg', ['delete', _runKey, '/v', _valueName, '/f']);
      }
    } catch (_) {}
  }

  /// 予定のウィンドウ（同じ exe を --calendar 付きで）を起動する。
  /// すでに起動していれば、exe 側の多重起動防止で何も起きない。
  static Future<void> launchCalendarWindow() async {
    if (!Platform.isWindows) return;
    try {
      await Process.start(Platform.resolvedExecutable, ['--calendar'],
          mode: ProcessStartMode.detached);
    } catch (_) {}
  }

  /// Notion カレンダーのアプリを起動する（スタートメニューかデスクトップの
  /// ショートカットを探す）。見つからなければ false。
  static Future<bool> openNotionCalendar() async {
    final env = Platform.environment;
    final dirs = <String>[
      if (env['APPDATA'] != null)
        '${env['APPDATA']}\\Microsoft\\Windows\\Start Menu\\Programs',
      if (env['ProgramData'] != null)
        '${env['ProgramData']}\\Microsoft\\Windows\\Start Menu\\Programs',
      if (env['USERPROFILE'] != null) '${env['USERPROFILE']}\\Desktop',
      if (env['USERPROFILE'] != null) '${env['USERPROFILE']}\\OneDrive\\Desktop',
      if (env['USERPROFILE'] != null) '${env['USERPROFILE']}\\OneDrive\\デスクトップ',
    ];
    for (final d in dirs) {
      final dir = Directory(d);
      if (!dir.existsSync()) continue;
      try {
        for (final f in dir.listSync(recursive: true, followLinks: false)) {
          final name = f.path.split('\\').last.toLowerCase();
          if (f is File &&
              name.endsWith('.lnk') &&
              name.startsWith('notion calendar')) {
            await _detached('explorer.exe', [f.path]);
            return true;
          }
        }
      } catch (_) {}
    }
    return false;
  }

  static final _exeName = RegExp(r'^[A-Za-z0-9._-]+\.exe$');
  static final _hex = RegExp(r'^[0-9A-Fa-f]+$');

  /// メッセージの開き先を起動する。
  /// - "outlook-entry:<16進>" … デスクトップ版 Outlook で該当メールを開く
  /// - "xxx.exe"               … そのアプリを起動する
  /// - それ以外                 … URL / プロトコル（https:, msteams:, slack:// など）
  static Future<bool> open(String target) async {
    try {
      if (target.startsWith('outlook-entry:')) {
        final hex = target.substring('outlook-entry:'.length);
        if (!_hex.hasMatch(hex)) return false;
        return _startProcess('outlook.exe', ['/select', 'outlook:$hex']);
      }
      if (_exeName.hasMatch(target)) {
        return _startProcess(target, const []);
      }
      final uri = Uri.tryParse(target);
      if (uri == null || uri.scheme.isEmpty) return false;
      return launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {
      return false;
    }
  }

  /// Start-Process は「App Paths」も見るので、PATH に無い outlook.exe も起動できる。
  static Future<bool> _startProcess(String exe, List<String> args) async {
    final argList = args.isEmpty
        ? ''
        : ' -ArgumentList ${args.map((a) => "'${a.replaceAll("'", "''")}'").join(',')}';
    await _detached('powershell', [
      '-NoProfile', '-WindowStyle', 'Hidden', '-Command', //
      "Start-Process '$exe'$argList",
    ]);
    return true;
  }

  /// コンソールを持たない子プロセスとして起動する（黒い窓が一瞬出るのを防ぐ）。
  static Future<void> _detached(String exe, List<String> args) =>
      Process.start(exe, args, mode: ProcessStartMode.detached);
}
