import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models/message_item.dart';
import '../models/settings.dart';
import '../services/graph_mail.dart';
import '../services/hub.dart';
import '../services/native_window.dart';
import '../services/layout.dart';
import '../services/system.dart';
import 'frame_panel.dart' show accentFor;

List<String> _splitList(String s) => s
    .split(RegExp(r'[,、，\n]'))
    .map((e) => e.trim())
    .where((e) => e.isNotEmpty)
    .toList();

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key, required this.hub});

  final MessageHub hub;

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  late AppSettings draft = widget.hub.settings.copy();

  MessageHub get hub => widget.hub;

  Future<void> _save({bool close = true}) async {
    // ウィンドウ位置はユーザー操作で変わっているので現在値を引き継ぐ
    draft.bounds = hub.settings.bounds;
    await hub.storage.saveSettings(draft);
    await NativeWindow.setOpacity(draft.opacity);
    await SystemIntegration.setAutostart(draft.autostart);
    hub.applySettings(draft.copy());
    if (draft.calendarEnabled) {
      await SystemIntegration.launchCalendarWindow();
    } else {
      await NativeWindow.closeByTitle(NativeWindow.calendarTitle);
    }
    if (close && mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final tabs = <(String, Widget)>[
      ('全般', _GeneralTab(draft: draft, onChanged: () => setState(() {}))),
      for (final f in draft.frames)
        (
          f.kind.label,
          _FrameTab(
            key: ValueKey('frame-${f.kind.name}'),
            frame: f,
            onChanged: () => setState(() {}),
          )
        ),
      ('予定', _CalendarTab(draft: draft, hub: hub, onChanged: () => setState(() {}))),
      (
        'アカウント連携',
        _AccountsTab(
            hub: hub,
            draft: draft,
            applyDraft: () => _save(close: false))
      ),
      ('通知元アプリ', _NotificationAppsTab(hub: hub)),
    ];

    return DefaultTabController(
      length: tabs.length,
      child: Scaffold(
        appBar: AppBar(
          toolbarHeight: 40,
          title: const Text('設定', style: TextStyle(fontSize: 15)),
          bottom: TabBar(
            isScrollable: true,
            tabAlignment: TabAlignment.start,
            tabs: [for (final t in tabs) Tab(height: 34, text: t.$1)],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('キャンセル'),
            ),
            const SizedBox(width: 4),
            FilledButton(onPressed: _save, child: const Text('保存')),
            const SizedBox(width: 10),
          ],
        ),
        body: TabBarView(children: [for (final t in tabs) t.$2]),
      ),
    );
  }
}

// ------------------------------------------------------------------ 部品

class _Section extends StatelessWidget {
  const _Section({required this.title, required this.children});

  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(title,
              style: const TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w700,
                  color: Color(0xFF3A3A3A))),
          const SizedBox(height: 8),
          ...children,
        ],
      ),
    );
  }
}

class _Field extends StatelessWidget {
  const _Field({
    required this.label,
    required this.initial,
    required this.onChanged,
    this.hint,
    this.helper,
    this.obscure = false,
    this.keyboardType,
  });

  final String label;
  final String initial;
  final ValueChanged<String> onChanged;
  final String? hint;
  final String? helper;
  final bool obscure;
  final TextInputType? keyboardType;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: TextFormField(
        initialValue: initial,
        onChanged: onChanged,
        obscureText: obscure,
        keyboardType: keyboardType,
        style: const TextStyle(fontSize: 13),
        decoration: InputDecoration(
          labelText: label,
          hintText: hint,
          helperText: helper,
          helperMaxLines: 3,
          isDense: true,
          border: const OutlineInputBorder(),
        ),
      ),
    );
  }
}

class _Switch extends StatelessWidget {
  const _Switch(
      {required this.label, required this.value, required this.onChanged, this.subtitle});

  final String label;
  final String? subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return SwitchListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      title: Text(label, style: const TextStyle(fontSize: 13)),
      subtitle: subtitle == null
          ? null
          : Text(subtitle!, style: const TextStyle(fontSize: 11.5)),
      value: value,
      onChanged: onChanged,
    );
  }
}

// ------------------------------------------------------------------ 全般

class _GeneralTab extends StatelessWidget {
  const _GeneralTab({required this.draft, required this.onChanged});

  final AppSettings draft;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        _Section(title: '表示', children: [
          _Switch(
            label: 'デスクトップに貼り付ける',
            subtitle: 'オン: 常に他のウィンドウの下に表示（壁紙の上）。オフ: 通常のウィンドウ',
            value: draft.pinnedToDesktop,
            onChanged: (v) {
              draft.pinnedToDesktop = v;
              onChanged();
            },
          ),
          Row(
            children: [
              const Text('不透明度', style: TextStyle(fontSize: 13)),
              Expanded(
                child: Slider(
                  value: draft.opacity,
                  min: 0.3,
                  max: 1.0,
                  divisions: 14,
                  label: '${(draft.opacity * 100).round()}%',
                  onChanged: (v) {
                    draft.opacity = v;
                    NativeWindow.setOpacity(v); // その場でプレビュー
                    onChanged();
                  },
                ),
              ),
              Text('${(draft.opacity * 100).round()}%'),
            ],
          ),
        ]),
        _Section(title: '配置', children: [
          Row(
            children: [
              const Text('上段（Teams・Slack）の高さ', style: TextStyle(fontSize: 13)),
              Expanded(
                child: Slider(
                  value: draft.topRowRatio,
                  min: 0.2,
                  max: 0.8,
                  divisions: 12,
                  label: '${(draft.topRowRatio * 100).round()}%',
                  onChanged: (v) {
                    draft.topRowRatio = v;
                    onChanged();
                  },
                ),
              ),
              Text('${(draft.topRowRatio * 100).round()}%'),
            ],
          ),
          const SizedBox(height: 4),
          Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton.icon(
              icon: const Icon(Icons.dashboard_outlined, size: 16),
              label: const Text('おすすめの配置に並べる（右下にメッセージ、右上に予定）'),
              onPressed: () async {
                final hub = hubOf(context);
                final wa = await NativeWindow.getWorkArea();
                if (wa == null || hub == null) return;
                final l = cornerLayout(wa);
                draft.topRowRatio = 0.38;
                onChanged();
                await NativeWindow.setBounds(l.main);
                await NativeWindow.setBoundsOf(
                    NativeWindow.calendarTitle, l.calendar);
                hub.settings.bounds = l.main;
                await hub.storage.saveSettings(hub.settings);
                await hub.storage.writeJson('calendar_window.json', l.calendar);
              },
            ),
          ),
        ]),
        _Section(title: '起動', children: [
          _Switch(
            label: 'Windows へのログイン時に自動で起動する',
            value: draft.autostart,
            onChanged: (v) {
              draft.autostart = v;
              onChanged();
            },
          ),
        ]),
        _Section(title: '更新間隔（秒）', children: [
          _Field(
            label: '通知方式（Teams / Slack など）',
            initial: '${draft.notificationPollSeconds}',
            keyboardType: TextInputType.number,
            helper: '3〜600 秒',
            onChanged: (v) => draft.notificationPollSeconds =
                (int.tryParse(v) ?? 10).clamp(3, 600),
          ),
          _Field(
            label: 'API 方式（Outlook API / Gmail）',
            initial: '${draft.apiPollSeconds}',
            keyboardType: TextInputType.number,
            helper: '15〜3600 秒',
            onChanged: (v) =>
                draft.apiPollSeconds = (int.tryParse(v) ?? 60).clamp(15, 3600),
          ),
        ]),
        _Section(title: 'Outlook', children: [
          _Switch(
            label: 'Outlook(API) のメールはデスクトップ版 Outlook で開く',
            subtitle: 'オフにするとブラウザ（Outlook on the web）で開きます',
            value: draft.outlookOpenInDesktop,
            onChanged: (v) {
              draft.outlookOpenInDesktop = v;
              onChanged();
            },
          ),
          _Switch(
            label: 'PC の Outlook から本文と差出人アドレスも読む',
            subtitle: 'オンにすると本文の抜粋と Teams の投稿へのリンクが出ます。'
                'Outlook の「プログラムによるアクセス」の確認が出る場合はオフにしてください',
            value: draft.outlookReadDetails,
            onChanged: (v) {
              draft.outlookReadDetails = v;
              onChanged();
            },
          ),
        ]),
      ],
    );
  }
}

// ------------------------------------------------------------------ フレーム

class _FrameTab extends StatelessWidget {
  const _FrameTab({super.key, required this.frame, required this.onChanged});

  final FrameSettings frame;
  final VoidCallback onChanged;

  String get _contextLabel => switch (frame.kind) {
        SourceKind.teams => 'チーム名・チャンネル名',
        SourceKind.slack => 'チャンネル名',
        SourceKind.outlook =>
          frame.mode == FetchMode.notification ? 'キーワード' : '分類（カテゴリ）',
        SourceKind.gmail => 'ラベル',
      };

  String get _contextHelp => switch (frame.kind) {
        SourceKind.teams =>
          '例: 研究室, 一般 （通知に含まれるチーム名・チャンネル名で絞り込み）。空なら全件',
        SourceKind.slack => '例: #general, #random 。空なら全件',
        SourceKind.outlook => frame.mode != FetchMode.notification
            ? 'Outlook の分類名。空なら全件'
            : '通知の本文に含まれる語で絞り込み。空なら全件',
        SourceKind.gmail => '例: 研究, 就活 （Gmail のラベル名）。空なら受信トレイ',
      };

  String get _modeHelp => switch (frame.mode) {
        FetchMode.outlookApp => frame.kind == SourceKind.teams
            ? 'PC のクラシック版 Outlook に届く Teams の通知メール（不在時のアクティビティ）を表示します。'
                'PC を起動していなかった間の投稿も表示できます。Teams の 設定 → 通知とアクティビティ →'
                '「不在時のアクティビティに関するメール」を「できるだけ早く」にしてください。'
            : 'PC のクラシック版 Outlook から受信トレイを直接読みます。設定は不要で、PC を起動していなかった間のメールも表示できます。',
        FetchMode.notification =>
          'Windows の通知履歴から拾います。そのアプリが Windows の通知を出している必要があります。',
        FetchMode.api => frame.kind == SourceKind.gmail
            ? 'Gmail API で取得します（「アカウント連携」でサインインが必要）。'
            : 'Microsoft Graph で取得します（「アカウント連携」でサインインが必要。大学が許可している場合のみ）。',
      };

  @override
  Widget build(BuildContext context) {
    final modes = FrameSettings.modesFor(frame.kind);
    final accent = accentFor(frame.kind);
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        _Section(title: '基本', children: [
          _Switch(
            label: 'このフレームを表示する',
            value: frame.enabled,
            onChanged: (v) {
              frame.enabled = v;
              onChanged();
            },
          ),
          _Field(
            label: '表示名',
            initial: frame.title,
            onChanged: (v) =>
                frame.title = v.trim().isEmpty ? frame.kind.label : v.trim(),
          ),
          _Field(
            label: '最大表示件数',
            initial: '${frame.maxItems}',
            keyboardType: TextInputType.number,
            helper: '1〜200',
            onChanged: (v) =>
                frame.maxItems = (int.tryParse(v) ?? 20).clamp(1, 200),
          ),
          if (modes.length > 1) ...[
            const Text('取得方式', style: TextStyle(fontSize: 12.5)),
            const SizedBox(height: 6),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final m in modes)
                  ChoiceChip(
                    label: Text(m.labelFor(frame.kind),
                        style: const TextStyle(fontSize: 12)),
                    selected: frame.mode == m,
                    onSelected: (_) {
                      frame.mode = m;
                      onChanged();
                    },
                  ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              _modeHelp,
              style: const TextStyle(fontSize: 11.5, color: Color(0xFF6E6E6E)),
            ),
            const SizedBox(height: 12),
          ],
        ]),
        _Section(title: '表示するもの（絞り込み）', children: [
          _Field(
            label: '送信者（受信相手）',
            initial: frame.senderFilter.join(', '),
            hint: '例: 山田, tanaka@example.com',
            helper: 'カンマ区切り。いずれかを含むものだけ表示。空なら全員',
            onChanged: (v) => frame.senderFilter = _splitList(v),
          ),
          _Field(
            label: _contextLabel,
            initial: frame.contextFilter.join(', '),
            helper: 'カンマ区切り。$_contextHelp',
            onChanged: (v) => frame.contextFilter = _splitList(v),
          ),
          _Field(
            label: '除外する語',
            initial: frame.excludeWords.join(', '),
            helper: 'カンマ区切り。これらを含むものは表示しない',
            onChanged: (v) => frame.excludeWords = _splitList(v),
          ),
          _Switch(
            label: '未読のみ表示',
            subtitle: frame.mode != FetchMode.notification
                ? 'サービス側で未読のものだけ'
                : 'このアプリでまだクリックしていないものだけ',
            value: frame.unreadOnly,
            onChanged: (v) {
              frame.unreadOnly = v;
              onChanged();
            },
          ),
        ]),
        if (frame.kind == SourceKind.outlook &&
            frame.mode != FetchMode.notification)
          _Section(title: 'Outlook のフォルダ', children: [
            _Field(
              label: 'フォルダ',
              initial: frame.folder,
              helper: '"inbox" = 受信トレイ。受信トレイ直下のフォルダ名も指定できます',
              onChanged: (v) => frame.folder = v.trim().isEmpty ? 'inbox' : v.trim(),
            ),
          ]),
        if (frame.kind == SourceKind.gmail)
          _Section(title: 'Gmail', children: [
            _Field(
              label: '追加の検索条件（任意）',
              initial: frame.extraQuery,
              hint: '例: newer_than:7d -category:promotions',
              helper: 'Gmail の検索ボックスと同じ書き方',
              onChanged: (v) => frame.extraQuery = v,
            ),
          ]),
        _Section(title: 'クリックしたときに開くもの', children: [
          if (frame.mode == FetchMode.notification)
            _Field(
              label: '通知元アプリの判定キーワード',
              initial: frame.appIdKeywords.join(', '),
              helper: '通知を出したアプリの ID に含まれる語（「通知元アプリ」タブで確認できます）',
              onChanged: (v) {
                final l = _splitList(v);
                frame.appIdKeywords =
                    l.isEmpty ? FrameSettings.defaultAppKeywords(frame.kind) : l;
              },
            ),
          _Field(
            label: '既定の開き先',
            initial: frame.defaultOpenTarget,
            helper: switch (frame.kind) {
              SourceKind.teams =>
                'msteams: で Teams アプリを開きます。チャンネルのリンク（Teams で「チャンネルへのリンクを取得」）を貼ると、そのチャンネルが直接開きます',
              SourceKind.slack =>
                'slack://open で Slack アプリを開きます。slack://channel?team=T…&id=C… で特定チャンネルを開けます',
              SourceKind.outlook =>
                'outlook.exe でデスクトップ版を起動。新しい Outlook なら ms-outlook: 、Web なら https://outlook.office.com/mail/',
              SourceKind.gmail => 'メッセージ個別のリンクが取れないときに開く URL',
            },
            onChanged: (v) => frame.defaultOpenTarget = v.trim().isEmpty
                ? FrameSettings.defaultOpenFor(frame.kind)
                : v.trim(),
          ),
        ]),
        Container(height: 2, color: accent.withValues(alpha: 0.4)),
      ],
    );
  }
}

// ------------------------------------------------------------------ アカウント

class _AccountsTab extends StatefulWidget {
  const _AccountsTab(
      {required this.hub, required this.draft, required this.applyDraft});

  final MessageHub hub;
  final AppSettings draft;
  final Future<void> Function() applyDraft;

  @override
  State<_AccountsTab> createState() => _AccountsTabState();
}

class _AccountsTabState extends State<_AccountsTab> {
  bool _busy = false;

  MessageHub get hub => widget.hub;

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<void> _msSignIn() async {
    setState(() => _busy = true);
    try {
      await widget.applyDraft(); // 入力したクライアント ID を反映してから
      final info = await hub.graph.beginDeviceLogin();
      if (!mounted) return;
      var cancelled = false;
      BuildContext? dialogCtx;
      final done = hub.graph
          .completeDeviceLogin(info, cancelled: () => cancelled);
      // 完了・失敗したらダイアログを閉じる（登録は 1 回だけ）
      unawaited(done.then((_) {
        final c = dialogCtx;
        if (c != null && c.mounted) Navigator.of(c).pop(true);
      }, onError: (Object e) {
        final c = dialogCtx;
        if (c != null && c.mounted) Navigator.of(c).pop(false);
        if (!cancelled) _snack('サインインに失敗しました: $e');
      }));
      final ok = await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (ctx) {
          dialogCtx = ctx;
          return AlertDialog(
            title: const Text('Microsoft にサインイン'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('ブラウザで下のページを開き、このコードを入力してください。'),
                const SizedBox(height: 12),
                SelectableText(info.userCode,
                    style: const TextStyle(
                        fontSize: 26,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 3)),
                const SizedBox(height: 4),
                SelectableText(info.verificationUri,
                    style: const TextStyle(fontSize: 12)),
                const SizedBox(height: 12),
                const Row(children: [
                  SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2)),
                  SizedBox(width: 8),
                  Text('サインインの完了を待っています…',
                      style: TextStyle(fontSize: 12)),
                ]),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () {
                  cancelled = true;
                  Navigator.of(ctx).pop(false);
                },
                child: const Text('キャンセル'),
              ),
              FilledButton.icon(
                icon: const Icon(Icons.open_in_new, size: 16),
                label: const Text('コードをコピーしてブラウザを開く'),
                onPressed: () {
                  Clipboard.setData(ClipboardData(text: info.userCode));
                  launchUrl(Uri.parse(info.verificationUri),
                      mode: LaunchMode.externalApplication);
                },
              ),
            ],
          );
        },
      );
      if (ok == true) {
        _snack('Outlook にサインインしました: ${hub.graph.account ?? ''}');
        unawaited(hub.refreshApis());
      }
    } on GraphAuthException catch (e) {
      _snack(e.message);
    } catch (e) {
      _snack('エラー: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _googleSignIn() async {
    setState(() => _busy = true);
    try {
      await widget.applyDraft();
      _snack('ブラウザで Google アカウントへのアクセスを許可してください');
      await hub.gmail
          .signIn((url) => launchUrl(Uri.parse(url),
              mode: LaunchMode.externalApplication))
          .timeout(const Duration(minutes: 5));
      _snack('Gmail にサインインしました: ${hub.gmail.account ?? ''}');
      unawaited(hub.refreshApis());
    } on TimeoutException {
      _snack('時間切れになりました。もう一度お試しください');
    } catch (e) {
      _snack('Gmail のサインインに失敗しました: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final d = widget.draft;
    return AbsorbPointer(
      absorbing: _busy,
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _Section(title: 'Microsoft（Outlook の API 方式で使用）', children: [
            const Text(
              'Outlook フレームの取得方式を「Microsoft Graph API」にした場合だけ必要です。'
              '手順は README の「Outlook を API 方式にする」を参照してください。',
              style: TextStyle(fontSize: 11.5, color: Color(0xFF6E6E6E)),
            ),
            const SizedBox(height: 10),
            _Field(
              label: 'アプリケーション（クライアント）ID',
              initial: d.graphClientId,
              onChanged: (v) => d.graphClientId = v.trim(),
            ),
            _Field(
              label: 'テナント',
              initial: d.graphTenant,
              helper: 'アプリ登録の概要ページにある「ディレクトリ (テナント) ID」。空欄なら organizations',
              onChanged: (v) => d.graphTenant = v.trim(),
            ),
            _AccountRow(
              signedIn: hub.graph.signedIn,
              account: hub.graph.account,
              onSignIn: _msSignIn,
              onSignOut: () async {
                await hub.graph.signOut();
                setState(() {});
              },
            ),
          ]),
          _Section(title: 'Google（Gmail で使用）', children: [
            const Text(
              'Google Cloud で作成した「デスクトップ アプリ」の OAuth クライアント ID とシークレットを入力します。'
              '手順は README の「Gmail の準備」を参照してください。',
              style: TextStyle(fontSize: 11.5, color: Color(0xFF6E6E6E)),
            ),
            const SizedBox(height: 10),
            _Field(
              label: 'クライアント ID',
              initial: d.googleClientId,
              onChanged: (v) => d.googleClientId = v.trim(),
            ),
            _Field(
              label: 'クライアント シークレット',
              initial: d.googleClientSecret,
              obscure: true,
              onChanged: (v) => d.googleClientSecret = v.trim(),
            ),
            _AccountRow(
              signedIn: hub.gmail.signedIn,
              account: hub.gmail.account,
              onSignIn: _googleSignIn,
              onSignOut: () async {
                await hub.gmail.signOut();
                setState(() {});
              },
            ),
          ]),
          if (_busy) const LinearProgressIndicator(),
        ],
      ),
    );
  }
}

class _AccountRow extends StatelessWidget {
  const _AccountRow({
    required this.signedIn,
    required this.account,
    required this.onSignIn,
    required this.onSignOut,
  });

  final bool signedIn;
  final String? account;
  final VoidCallback onSignIn;
  final VoidCallback onSignOut;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(signedIn ? Icons.check_circle : Icons.error_outline,
            size: 16,
            color: signedIn ? const Color(0xFF46A758) : Color(0xFFA0A0A0)),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            signedIn ? 'サインイン済み ${account ?? ''}' : '未サインイン',
            style: const TextStyle(fontSize: 12.5),
          ),
        ),
        if (signedIn)
          TextButton(onPressed: onSignOut, child: const Text('サインアウト')),
        FilledButton.tonal(
          onPressed: onSignIn,
          child: Text(signedIn ? '再サインイン' : 'サインイン'),
        ),
      ],
    );
  }
}

// ------------------------------------------------------------------ 通知元アプリ

class _NotificationAppsTab extends StatefulWidget {
  const _NotificationAppsTab({required this.hub});

  final MessageHub hub;

  @override
  State<_NotificationAppsTab> createState() => _NotificationAppsTabState();
}

class _NotificationAppsTabState extends State<_NotificationAppsTab> {
  List<MapEntry<String, int>>? _apps;
  String? _error;

  Future<void> _load() async {
    try {
      final apps = await widget.hub.notifications.listApps();
      setState(() {
        _apps = apps;
        _error = null;
      });
    } catch (e) {
      setState(() => _error = '$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const Text(
          'Windows の通知履歴に記録されているアプリの ID です。Teams / Slack / Outlook の通知が拾えないときは、'
          'ここで該当アプリの ID を確認し、各フレームの「通知元アプリの判定キーワード」に ID の一部を入れてください。',
          style: TextStyle(fontSize: 12, color: Color(0xFF3A3A3A)),
        ),
        const SizedBox(height: 10),
        Align(
          alignment: Alignment.centerLeft,
          child: FilledButton.tonalIcon(
            icon: const Icon(Icons.search, size: 16),
            label: const Text('通知履歴を調べる'),
            onPressed: _load,
          ),
        ),
        const SizedBox(height: 10),
        if (_error != null)
          Text(_error!, style: const TextStyle(color: Color(0xFFB42318))),
        if (_apps != null && _apps!.isEmpty)
          const Text('通知の記録が見つかりませんでした'),
        for (final a in _apps ?? const <MapEntry<String, int>>[])
          ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            title: SelectableText(a.key, style: const TextStyle(fontSize: 12.5)),
            trailing: Text('${a.value} 件',
                style: const TextStyle(fontSize: 12, color: Color(0xFF6E6E6E))),
          ),
      ],
    );
  }
}


/// 設定画面の中から MessageHub を取り出す（全般タブ用）。
MessageHub? hubOf(BuildContext context) =>
    context.findAncestorStateOfType<_SettingsPageState>()?.hub;

// ------------------------------------------------------------------ 予定

class _CalendarTab extends StatelessWidget {
  const _CalendarTab(
      {required this.draft, required this.hub, required this.onChanged});

  final AppSettings draft;
  final MessageHub hub;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    final g = hub.gmail;
    final needsResign = g.signedIn && !g.hasCalendarScope;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        _Section(title: '予定のウィンドウ', children: [
          _Switch(
            label: '予定（Google カレンダー）のウィンドウを表示する',
            subtitle: 'Notion カレンダーにつないでいる Google カレンダーの予定を、別の小さなウィンドウに表示します',
            value: draft.calendarEnabled,
            onChanged: (v) {
              draft.calendarEnabled = v;
              onChanged();
            },
          ),
          _Field(
            label: '表示する日数（今日から）',
            initial: '${draft.calendarDays}',
            keyboardType: TextInputType.number,
            helper: '1〜21 日',
            onChanged: (v) =>
                draft.calendarDays = (int.tryParse(v) ?? 2).clamp(1, 21),
          ),
          const Text('予定をクリックしたときに開くもの',
              style: TextStyle(fontSize: 12.5)),
          const SizedBox(height: 6),
          Wrap(spacing: 6, children: [
            ChoiceChip(
              label: const Text('Notion カレンダー', style: TextStyle(fontSize: 12)),
              selected: draft.calendarOpenTarget == 'notion',
              onSelected: (_) {
                draft.calendarOpenTarget = 'notion';
                onChanged();
              },
            ),
            ChoiceChip(
              label: const Text('ブラウザの Google カレンダー',
                  style: TextStyle(fontSize: 12)),
              selected: draft.calendarOpenTarget == 'google',
              onSelected: (_) {
                draft.calendarOpenTarget = 'google';
                onChanged();
              },
            ),
          ]),
        ]),
        _Section(title: 'Google カレンダーとの連携', children: [
          Text(
            !g.signedIn
                ? '「アカウント連携」タブで Google にサインインしてください。'
                : needsResign
                    ? 'カレンダーを読む権限がまだありません。Google Cloud で「Google Calendar API」を有効にしてから、「アカウント連携」タブで Google に「再サインイン」してください。'
                    : 'カレンダーの読み取りが有効です。',
            style: TextStyle(
                fontSize: 12,
                color: needsResign || !g.signedIn
                    ? const Color(0xFFB42318)
                    : const Color(0xFF3A3A3A)),
          ),
        ]),
      ],
    );
  }
}
