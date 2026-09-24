import 'dart:async';
import 'dart:convert';

import 'package:googleapis_auth/auth_io.dart';
import 'package:http/http.dart' as http;

import '../models/message_item.dart';
import '../models/settings.dart';
import 'storage.dart';

/// Gmail の受信メールを Gmail API（読み取り専用）で取得する。
///
/// サインインはブラウザでの同意（ローカルループバック方式）。
/// Google Cloud で作成した「デスクトップ アプリ」の OAuth クライアントを使う。
class GmailService {
  GmailService(this._storage, this._settings);

  final Storage _storage;
  final AppSettings Function() _settings;
  static const _tokenFile = 'token_google.json';
  static const calendarScope =
      'https://www.googleapis.com/auth/calendar.readonly';
  static const _scopes = [
    'https://www.googleapis.com/auth/gmail.readonly',
    calendarScope,
  ];
  static const _api = 'https://gmail.googleapis.com/gmail/v1/users/me';

  AccessCredentials? _creds;
  AutoRefreshingAuthClient? _client;
  StreamSubscription<AccessCredentials>? _sub;
  String? account;
  Map<String, String> _labelNames = {};
  DateTime? _labelsFetched;

  Future<void> load() async {
    _resetClient();
    final j = await _storage.readJson(_tokenFile);
    if (j == null) return;
    try {
      _creds = AccessCredentials.fromJson(
          Map<String, dynamic>.from(j['credentials'] as Map));
      account = j['account'] as String?;
    } catch (_) {
      _creds = null;
    }
  }

  bool get signedIn => _creds?.refreshToken != null;

  /// カレンダーの読み取り権限つきでサインインしているか（古いサインインには無い）。
  bool get hasCalendarScope =>
      _creds?.scopes.contains(calendarScope) ?? false;

  /// 他の Google API（カレンダー）用。認証つきで GET して JSON を返す。
  Future<Map<String, dynamic>> getJson(String url,
          [Map<String, dynamic>? query]) =>
      _getJson(url, query);

  ClientId get _clientId {
    final s = _settings();
    if (s.googleClientId.trim().isEmpty) {
      throw StateError('設定 → アカウント連携 で Google のクライアント ID を入力してください');
    }
    return ClientId(s.googleClientId.trim(),
        s.googleClientSecret.trim().isEmpty ? null : s.googleClientSecret.trim());
  }

  /// ブラウザを開いて同意してもらう。[openBrowser] に同意ページの URL が渡る。
  Future<void> signIn(void Function(String url) openBrowser) async {
    final base = http.Client();
    try {
      final creds = await obtainAccessCredentialsViaUserConsent(
          _clientId, _scopes, base, openBrowser);
      _creds = creds;
      _resetClient();
      await _save();
      final profile = await _getJson('$_api/profile');
      account = profile['emailAddress'] as String?;
      await _save();
    } finally {
      base.close();
    }
  }

  Future<void> signOut() async {
    _resetClient();
    _creds = null;
    account = null;
    _labelNames = {};
    await _storage.delete(_tokenFile);
  }

  void _resetClient() {
    _sub?.cancel();
    _sub = null;
    _client?.close();
    _client = null;
  }

  Future<void> _save() async {
    final c = _creds;
    if (c == null) return;
    await _storage.writeJson(_tokenFile, {
      'credentials': c.toJson(),
      'account': account,
    });
  }

  http.Client _http() {
    final existing = _client;
    if (existing != null) return existing;
    final c = _creds;
    if (c == null || c.refreshToken == null) {
      throw StateError('Gmail にサインインしていません（設定 → アカウント連携）');
    }
    final client = autoRefreshingClient(_clientId, c, http.Client());
    _sub = client.credentialUpdates.listen((updated) {
      _creds = updated;
      _save();
    });
    _client = client;
    return client;
  }

  Future<Map<String, dynamic>> _getJson(String url,
      [Map<String, dynamic>? query]) async {
    final uri = Uri.parse(url).replace(queryParameters: query);
    final http.Response res;
    try {
      res = await _http().get(uri).timeout(const Duration(seconds: 20),
          onTimeout: () => throw StateError('Gmail API の応答がありません（20 秒でタイムアウト）'));
    } on ServerRequestFailedException catch (e) {
      // リフレッシュトークンが失効・取り消されたとき
      if (e.toString().contains('invalid_grant')) {
        await signOut();
        throw StateError('Gmail の認証が切れました。もう一度サインインしてください');
      }
      rethrow;
    } on AccessDeniedException {
      await signOut();
      throw StateError('Gmail へのアクセスが拒否されました。もう一度サインインしてください');
    }
    if (res.statusCode != 200) {
      throw StateError(
          'Gmail API ${res.statusCode} (${uri.path.split('/').last}): ${_errorText(res.body)}');
    }
    return jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
  }

  Future<void> _ensureLabels() async {
    if (_labelsFetched != null &&
        DateTime.now().difference(_labelsFetched!) < const Duration(hours: 1)) {
      return;
    }
    final j = await _getJson('$_api/labels');
    _labelNames = {
      for (final l in (j['labels'] as List? ?? const []))
        if ((l as Map)['type'] == 'user') l['id'] as String: l['name'] as String
    };
    _labelsFetched = DateTime.now();
  }

  /// Gmail の検索式を組み立てる。
  String buildQuery(FrameSettings f) {
    String quote(String s) => s.contains(' ') ? '"$s"' : s;
    final parts = <String>[];
    final extra = f.extraQuery.trim();
    if (f.contextFilter.isNotEmpty) {
      final labels = f.contextFilter
          .map((l) => 'label:${l.trim().replaceAll(RegExp(r'[\s/]+'), '-')}')
          .join(' ');
      parts.add('{$labels}');
    } else if (!extra.contains('in:') && !extra.contains('label:')) {
      parts.add('in:inbox');
    }
    if (f.senderFilter.isNotEmpty) {
      parts.add('{${f.senderFilter.map((s) => 'from:${quote(s.trim())}').join(' ')}}');
    }
    if (f.unreadOnly) parts.add('is:unread');
    if (extra.isNotEmpty) parts.add(extra);
    return parts.join(' ');
  }

  Future<List<MessageItem>> fetch(FrameSettings f) async {
    await _ensureLabels();
    final list = await _getJson('$_api/messages', {
      'q': buildQuery(f),
      'maxResults': '${f.maxItems.clamp(1, 100)}',
    });
    final ids = [
      for (final m in (list['messages'] as List? ?? const []))
        (m as Map)['id'] as String
    ];
    // 1 通ずつの詳細取得は 5 件ずつ並列で行い、失敗したものは 1 回だけやり直す。
    // それでも失敗したものは飛ばして、取れた分だけ表示する。
    final details = <Map<String, dynamic>>[];
    Object? firstError;
    Future<Map<String, dynamic>?> getOne(String id) async {
      for (var attempt = 0; attempt < 2; attempt++) {
        try {
          return await _getJson('$_api/messages/$id', {
            'format': 'metadata',
            'metadataHeaders': ['From', 'Subject'],
          });
        } catch (e) {
          firstError ??= e;
          if (attempt == 0) {
            await Future<void>.delayed(const Duration(milliseconds: 400));
          }
        }
      }
      return null;
    }

    for (var i = 0; i < ids.length; i += 5) {
      final chunk = ids.sublist(i, (i + 5).clamp(0, ids.length));
      final got = await Future.wait(chunk.map(getOne));
      details.addAll(got.whereType<Map<String, dynamic>>());
    }
    if (details.isEmpty && ids.isNotEmpty && firstError != null) {
      throw firstError!;
    }

    // /mail/u/<アドレス>/ 形式は環境によって 404 になるので authuser= で指定する
    final user = account ?? '0';
    return [
      for (final d in details) _toItem(d, user),
    ];
  }

  MessageItem _toItem(Map<String, dynamic> d, String user) {
    String header(String name) {
      final hs = (d['payload'] as Map?)?['headers'] as List? ?? const [];
      for (final h in hs) {
        if ((h as Map)['name'].toString().toLowerCase() == name.toLowerCase()) {
          return (h['value'] ?? '').toString();
        }
      }
      return '';
    }

    final labels = ((d['labelIds'] as List?) ?? const [])
        .map((id) => _labelNames[id])
        .whereType<String>()
        .toList();
    final ms = int.tryParse('${d['internalDate']}');
    final threadId = (d['threadId'] ?? d['id']) as String;
    return MessageItem(
      id: 'gmail:${d['id']}',
      kind: SourceKind.gmail,
      sender: header('From'),
      title: header('Subject').isEmpty ? '(件名なし)' : header('Subject'),
      preview: _unescape((d['snippet'] ?? '') as String),
      context: labels.join(', '),
      time: ms != null
          ? DateTime.fromMillisecondsSinceEpoch(ms)
          : DateTime.now(),
      openTarget:
          'https://mail.google.com/mail/?authuser=${Uri.encodeQueryComponent(user)}#all/$threadId',
    );
  }

  /// エラー応答（JSON または HTML）から読める部分だけを取り出す。
  static String _errorText(String body) {
    try {
      final j = jsonDecode(body);
      if (j is Map && j['error'] is Map) {
        return '${j['error']['message'] ?? j['error']}';
      }
    } catch (_) {}
    final title = RegExp(r'<title>(.*?)</title>', dotAll: true)
        .firstMatch(body)
        ?.group(1)
        ?.trim();
    final text = body
        .replaceAll(RegExp(r'<(script|style)[^>]*>.*?</\1>', dotAll: true), ' ')
        .replaceAll(RegExp(r'<[^>]+>'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    final summary = [if (title != null && title.isNotEmpty) title, text]
        .join(' / ');
    return summary.length > 160 ? '${summary.substring(0, 160)}…' : summary;
  }

  static String _unescape(String s) => s
      .replaceAll('&#39;', "'")
      .replaceAll('&quot;', '"')
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&amp;', '&');
}
