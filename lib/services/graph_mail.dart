import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models/message_item.dart';
import '../models/settings.dart';
import 'storage.dart';

class DeviceCodeInfo {
  DeviceCodeInfo({
    required this.deviceCode,
    required this.userCode,
    required this.verificationUri,
    required this.message,
    required this.interval,
    required this.expiresAt,
  });

  final String deviceCode;
  final String userCode;
  final String verificationUri;
  final String message;
  final int interval;
  final DateTime expiresAt;
}

class GraphAuthException implements Exception {
  GraphAuthException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Outlook（組織アカウント）の受信メールを Microsoft Graph で取得する。
///
/// 使う権限は委任アクセス許可の Mail.Read / User.Read / offline_access のみ。
/// サインインはデバイスコード方式（ブラウザでコードを入力する）。
class GraphMailService {
  GraphMailService(this._storage, this._settings);

  final Storage _storage;
  final AppSettings Function() _settings;
  static const _tokenFile = 'token_graph.json';
  static const _scope = 'offline_access User.Read Mail.Read';

  Map<String, dynamic>? _token;
  final Map<String, String> _folderIds = {};
  String? account;

  Future<void> load() async {
    _token = await _storage.readJson(_tokenFile);
    account = _token?['account'] as String?;
  }

  bool get signedIn => _token?['refresh_token'] != null;

  String get _authority {
    final t = _settings().graphTenant.trim();
    return 'https://login.microsoftonline.com/${t.isEmpty ? 'organizations' : t}/oauth2/v2.0';
  }

  String get _clientId {
    final id = _settings().graphClientId.trim();
    if (id.isEmpty) {
      throw GraphAuthException(
          '設定 → アカウント連携 で Microsoft のクライアント ID を入力してください');
    }
    return id;
  }

  Future<DeviceCodeInfo> beginDeviceLogin() async {
    final res = await http.post(Uri.parse('$_authority/devicecode'),
        body: {'client_id': _clientId, 'scope': _scope});
    final j = jsonDecode(res.body) as Map<String, dynamic>;
    if (res.statusCode != 200) {
      throw GraphAuthException(
          '${j['error'] ?? res.statusCode}: ${j['error_description'] ?? ''}');
    }
    return DeviceCodeInfo(
      deviceCode: j['device_code'] as String,
      userCode: j['user_code'] as String,
      verificationUri: j['verification_uri'] as String,
      message: (j['message'] ?? '') as String,
      interval: (j['interval'] as num?)?.toInt() ?? 5,
      expiresAt: DateTime.now()
          .add(Duration(seconds: (j['expires_in'] as num?)?.toInt() ?? 900)),
    );
  }

  /// ユーザーがブラウザでコードを入力し終えるまで待つ。
  Future<void> completeDeviceLogin(DeviceCodeInfo info,
      {bool Function()? cancelled}) async {
    var interval = info.interval;
    while (DateTime.now().isBefore(info.expiresAt)) {
      await Future<void>.delayed(Duration(seconds: interval));
      if (cancelled?.call() ?? false) {
        throw GraphAuthException('キャンセルしました');
      }
      final res = await http.post(Uri.parse('$_authority/token'), body: {
        'grant_type': 'urn:ietf:params:oauth:grant-type:device_code',
        'client_id': _clientId,
        'device_code': info.deviceCode,
      });
      final j = jsonDecode(res.body) as Map<String, dynamic>;
      if (res.statusCode == 200) {
        await _saveToken(j);
        await _fetchAccount();
        return;
      }
      final err = j['error'];
      if (err == 'authorization_pending') continue;
      if (err == 'slow_down') {
        interval += 5;
        continue;
      }
      throw GraphAuthException(
          '$err: ${j['error_description'] ?? ''}'.trim());
    }
    throw GraphAuthException('コードの有効期限が切れました。もう一度サインインしてください');
  }

  Future<void> signOut() async {
    _token = null;
    account = null;
    _folderIds.clear();
    await _storage.delete(_tokenFile);
  }

  Future<void> _saveToken(Map<String, dynamic> j) async {
    final expiresIn = (j['expires_in'] as num?)?.toInt() ?? 3600;
    _token = {
      'access_token': j['access_token'],
      'refresh_token': j['refresh_token'] ?? _token?['refresh_token'],
      'expires_at': DateTime.now()
          .add(Duration(seconds: expiresIn - 120))
          .millisecondsSinceEpoch,
      'account': account,
    };
    await _storage.writeJson(_tokenFile, _token!);
  }

  Future<void> _fetchAccount() async {
    try {
      final j = await _get('/me?\$select=mail,userPrincipalName');
      account = (j['mail'] ?? j['userPrincipalName']) as String?;
      _token?['account'] = account;
      if (_token != null) await _storage.writeJson(_tokenFile, _token!);
    } catch (_) {}
  }

  Future<String> _accessToken() async {
    final t = _token;
    if (t == null || t['refresh_token'] == null) {
      throw GraphAuthException('Outlook にサインインしていません（設定 → アカウント連携）');
    }
    final exp = (t['expires_at'] as num?)?.toInt() ?? 0;
    if (t['access_token'] != null &&
        DateTime.now().millisecondsSinceEpoch < exp) {
      return t['access_token'] as String;
    }
    final res = await http.post(Uri.parse('$_authority/token'), body: {
      'grant_type': 'refresh_token',
      'client_id': _clientId,
      'refresh_token': t['refresh_token'] as String,
      'scope': _scope,
    });
    final j = jsonDecode(res.body) as Map<String, dynamic>;
    if (res.statusCode != 200) {
      if (j['error'] == 'invalid_grant') await signOut();
      throw GraphAuthException(
          'Outlook のトークン更新に失敗: ${j['error'] ?? res.statusCode}');
    }
    await _saveToken(j);
    return _token!['access_token'] as String;
  }

  Future<Map<String, dynamic>> _get(String pathAndQuery) async {
    final token = await _accessToken();
    final res = await http.get(
      Uri.parse('https://graph.microsoft.com/v1.0$pathAndQuery'),
      headers: {'Authorization': 'Bearer $token'},
    );
    final body = jsonDecode(utf8.decode(res.bodyBytes));
    if (res.statusCode != 200) {
      final err = body is Map ? body['error'] : null;
      throw GraphAuthException(
          'Graph ${res.statusCode}: ${err is Map ? err['message'] : res.body}');
    }
    return body as Map<String, dynamic>;
  }

  static const _wellKnown = {
    'inbox', 'archive', 'sentitems', 'junkemail', 'drafts', 'deleteditems'
  };

  Future<String> _folderId(String name) async {
    final n = name.trim().isEmpty ? 'inbox' : name.trim();
    if (_wellKnown.contains(n.toLowerCase())) return n.toLowerCase();
    final cached = _folderIds[n];
    if (cached != null) return cached;
    final escaped = n.replaceAll("'", "''");
    final filter = Uri.encodeComponent("displayName eq '$escaped'");
    // 最上位のフォルダ → 受信トレイ直下のフォルダ の順に探す。
    for (final base in ['/me/mailFolders', '/me/mailFolders/inbox/childFolders']) {
      final j = await _get('$base?\$filter=$filter&\$select=id,displayName');
      final list = (j['value'] as List?) ?? const [];
      if (list.isNotEmpty) {
        final id = (list.first as Map)['id'] as String;
        _folderIds[n] = id;
        return id;
      }
    }
    throw GraphAuthException('Outlook のフォルダ「$n」が見つかりません');
  }

  Future<List<MessageItem>> fetch(FrameSettings f) async {
    final folder = await _folderId(f.folder);
    final top = (f.maxItems * 4).clamp(25, 100);
    final q = <String>[
      '\$top=$top',
      '\$select=id,subject,from,receivedDateTime,bodyPreview,webLink,isRead,categories',
      '\$orderby=receivedDateTime desc',
      // PR_ENTRYID（デスクトップ版 Outlook で直接開くため）
      '\$expand=${Uri.encodeComponent("singleValueExtendedProperties(\$filter=id eq 'Binary 0x0FFF')")}',
      if (f.unreadOnly)
        '\$filter=${Uri.encodeComponent('receivedDateTime ge 1900-01-01T00:00:00Z and isRead eq false')}',
    ].join('&');
    final j = await _get('/me/mailFolders/$folder/messages?$q');
    final openInDesktop = _settings().outlookOpenInDesktop;

    final items = <MessageItem>[];
    for (final m in (j['value'] as List? ?? const [])) {
      final map = m as Map<String, dynamic>;
      final from = (map['from'] as Map?)?['emailAddress'] as Map?;
      final name = (from?['name'] ?? '') as String;
      final address = (from?['address'] ?? '') as String;
      final categories =
          ((map['categories'] as List?) ?? const []).cast<String>();

      String? entryHex;
      final props = map['singleValueExtendedProperties'] as List?;
      if (props != null && props.isNotEmpty) {
        final v = (props.first as Map)['value'] as String?;
        if (v != null) {
          try {
            entryHex = base64Decode(v)
                .map((b) => b.toRadixString(16).padLeft(2, '0'))
                .join()
                .toUpperCase();
          } catch (_) {}
        }
      }

      items.add(MessageItem(
        id: 'graph:${map['id']}',
        kind: SourceKind.outlook,
        sender: name.isNotEmpty ? '$name <$address>' : address,
        title: (map['subject'] ?? '(件名なし)') as String,
        preview: ((map['bodyPreview'] ?? '') as String)
            .replaceAll(RegExp(r'\s+'), ' ')
            .trim(),
        context: categories.join(', '),
        time: DateTime.tryParse((map['receivedDateTime'] ?? '') as String)
                ?.toLocal() ??
            DateTime.now(),
        openTarget: openInDesktop && entryHex != null
            ? 'outlook-entry:$entryHex'
            : map['webLink'] as String?,
      ));
    }
    return items;
  }
}
