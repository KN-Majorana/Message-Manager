import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../models/settings.dart';

/// 設定・トークン・通知履歴を %APPDATA% 配下の JSON に保存する。
class Storage {
  Storage._(this.dir);

  final Directory dir;

  static Future<Storage> open() async {
    final base = await getApplicationSupportDirectory();
    final dir = Directory(base.path);
    if (!dir.existsSync()) dir.createSync(recursive: true);
    return Storage._(dir);
  }

  File _file(String name) => File(p.join(dir.path, name));

  Future<Map<String, dynamic>?> readJson(String name) async {
    final f = _file(name);
    if (!await f.exists()) return null;
    try {
      final v = jsonDecode(await f.readAsString());
      return v is Map<String, dynamic> ? v : null;
    } catch (_) {
      return null;
    }
  }

  /// 一時ファイルに書いてから置き換える（書き込み途中で落ちても壊れないように）。
  Future<void> writeJson(String name, Map<String, dynamic> data) {
    // 同じファイルへの書き込みは順番に行う。
    final prev = _pending[name] ?? Future<void>.value();
    final next = prev.catchError((_) {}).then((_) => _write(name, data));
    _pending[name] = next;
    return next;
  }

  final Map<String, Future<void>> _pending = {};

  Future<void> _write(String name, Map<String, dynamic> data) async {
    final f = _file(name);
    final tmp = File('${f.path}.tmp');
    await tmp.writeAsString(
        const JsonEncoder.withIndent('  ').convert(data),
        flush: true);
    if (await f.exists()) await f.delete();
    await tmp.rename(f.path);
  }

  Future<void> delete(String name) async {
    final f = _file(name);
    if (await f.exists()) await f.delete();
  }

  Future<AppSettings> loadSettings() async {
    final j = await readJson('settings.json');
    return j == null ? AppSettings() : AppSettings.fromJson(j);
  }

  Future<void> saveSettings(AppSettings s) =>
      writeJson('settings.json', s.toJson());
}
