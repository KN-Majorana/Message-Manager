import 'package:flutter/material.dart';

import '../models/message_item.dart';
import '../models/settings.dart';
import '../services/hub.dart';

/// サービスの色（未読の点など）。
Color accentFor(SourceKind k) => switch (k) {
      SourceKind.teams => const Color(0xFF5B5FC7),
      SourceKind.slack => const Color(0xFFE01E5A),
      SourceKind.outlook => const Color(0xFF0F6CBD),
      SourceKind.gmail => const Color(0xFFD93025),
    };

/// 見出しの文字色（白地で読めるよう少し濃くしたサービスの色）。
Color inkFor(SourceKind k) => switch (k) {
      SourceKind.teams => const Color(0xFF4448A8),
      SourceKind.slack => const Color(0xFFB3174A),
      SourceKind.outlook => const Color(0xFF0B5A9E),
      SourceKind.gmail => const Color(0xFFB3261E),
    };

const _textPrimary = Color(0xFF141414);
const _textSecondary = Color(0xFF6E6E6E);
const _textMuted = Color(0xFFA0A0A0);
const _rowLine = Color(0xFFF4F4F4);

String formatTime(DateTime t) {
  final now = DateTime.now();
  String two(int v) => v.toString().padLeft(2, '0');
  final hm = '${two(t.hour)}:${two(t.minute)}';
  if (t.year == now.year && t.month == now.month && t.day == now.day) {
    return hm;
  }
  final yesterday = now.subtract(const Duration(days: 1));
  if (t.year == yesterday.year &&
      t.month == yesterday.month &&
      t.day == yesterday.day) {
    return '昨日';
  }
  if (t.year == now.year) return '${t.month}/${t.day}';
  return '${t.year}/${t.month}/${t.day}';
}

/// 4 分割のうちの 1 フレーム（案 A-2「カラーラベル」）。
class FramePanel extends StatelessWidget {
  const FramePanel({
    super.key,
    required this.hub,
    required this.frame,
    required this.state,
  });

  final MessageHub hub;
  final FrameSettings frame;
  final FrameState state;

  @override
  Widget build(BuildContext context) {
    final accent = accentFor(frame.kind);
    final ink = inkFor(frame.kind);
    final unread = hub.unreadCount(frame.kind);
    return Container(
      color: Colors.white,
      padding: const EdgeInsets.fromLTRB(16, 10, 10, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            height: 28,
            child: Row(
              children: [
                Flexible(
                  child: Text(
                    frame.title,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: 14, fontWeight: FontWeight.w700, color: ink),
                  ),
                ),
                const SizedBox(width: 8),
                if (state.loading)
                  const SizedBox(
                    width: 10,
                    height: 10,
                    child: CircularProgressIndicator(
                        strokeWidth: 1.5, color: _textMuted),
                  ),
                const Spacer(),
                if (unread > 0) ...[
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 1),
                    decoration: BoxDecoration(
                      color: const Color(0xFFF2F2F2),
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: Text('新着 $unread',
                        style: const TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w500,
                            color: Color(0xFF3A3A3A))),
                  ),
                  IconButton(
                    icon: const Icon(Icons.done_all, size: 15),
                    tooltip: 'すべて既読にする',
                    color: _textMuted,
                    onPressed: () => hub.markAllRead(frame.kind),
                    padding: EdgeInsets.zero,
                    constraints:
                        const BoxConstraints.tightFor(width: 26, height: 24),
                  ),
                ],
              ],
            ),
          ),
          if (state.error != null)
            Container(
              margin: const EdgeInsets.only(top: 4, right: 6),
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
              decoration: BoxDecoration(
                color: const Color(0xFFFDECEC),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(
                state.error!,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 11, color: Color(0xFFB42318)),
              ),
            ),
          Expanded(
            child: state.items.isEmpty
                ? Center(
                    child: Text(
                      state.updatedAt == null ? '読み込み中…' : '表示するメッセージはありません',
                      style: const TextStyle(fontSize: 11.5, color: _textMuted),
                    ),
                  )
                : ListView.builder(
                    padding: const EdgeInsets.only(right: 6),
                    itemCount: state.items.length,
                    itemBuilder: (context, i) {
                      final m = state.items[i];
                      return MessageTile(
                        item: m,
                        unread: hub.isUnread(m),
                        accent: accent,
                        onTap: () => hub.open(m),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

class MessageTile extends StatelessWidget {
  const MessageTile({
    super.key,
    required this.item,
    required this.unread,
    required this.accent,
    required this.onTap,
  });

  final MessageItem item;
  final bool unread;
  final Color accent;
  final VoidCallback onTap;

  static String _initial(String s) {
    final t = s.replaceAll(RegExp(r'^[#"\s【\[（(]+'), '').trim();
    return t.isEmpty ? '?' : String.fromCharCode(t.runes.first);
  }

  @override
  Widget build(BuildContext context) {
    final headline = item.sender.isNotEmpty ? item.sender : item.title;
    final second = item.title != headline ? item.title : '';
    // 2 行目：件名があれば件名、なければ本文の抜粋
    final line2 = second.isNotEmpty
        ? (item.preview.isNotEmpty ? '$second　${item.preview}' : second)
        : item.preview;
    final tooltip = [
      headline,
      if (second.isNotEmpty) second,
      if (item.context.isNotEmpty) '[${item.context}]',
      if (item.preview.isNotEmpty) item.preview,
    ].join('\n');

    return Tooltip(
      message: tooltip.length > 600 ? '${tooltip.substring(0, 600)}…' : tooltip,
      waitDuration: const Duration(milliseconds: 900),
      child: InkWell(
        onTap: onTap,
        hoverColor: const Color(0xFFF7F7F7),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 7),
          decoration: const BoxDecoration(
            border: Border(bottom: BorderSide(color: _rowLine)),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 26,
                height: 26,
                alignment: Alignment.center,
                decoration: const BoxDecoration(
                  color: Color(0xFFF1F1F1),
                  shape: BoxShape.circle,
                ),
                child: Text(
                  _initial(headline),
                  style: const TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w500,
                      color: Color(0xFF555555)),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            headline,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 12.5,
                              color: _textPrimary,
                              fontWeight:
                                  unread ? FontWeight.w700 : FontWeight.w400,
                            ),
                          ),
                        ),
                        const SizedBox(width: 6),
                        Text(formatTime(item.time),
                            style: const TextStyle(
                                fontSize: 10.5, color: _textMuted)),
                        const SizedBox(width: 6),
                        Container(
                          width: 6,
                          height: 6,
                          decoration: BoxDecoration(
                            color: unread ? accent : Colors.transparent,
                            shape: BoxShape.circle,
                          ),
                        ),
                      ],
                    ),
                    if (line2.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 1),
                        child: Text(
                          line2,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              fontSize: 11.5, color: _textSecondary),
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
