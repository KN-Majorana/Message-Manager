import 'package:flutter/material.dart';

import '../services/native_window.dart';

/// タイトルバーの無いウィンドウの縁をつかんでリサイズできるようにする。
class ResizeFrame extends StatelessWidget {
  const ResizeFrame({super.key, required this.child, this.thickness = 5});

  final Widget child;
  final double thickness;

  Widget _edge({
    double? left,
    double? top,
    double? right,
    double? bottom,
    double? width,
    double? height,
    required MouseCursor cursor,
    required int edge,
  }) {
    return Positioned(
      left: left,
      top: top,
      right: right,
      bottom: bottom,
      width: width,
      height: height,
      child: MouseRegion(
        cursor: cursor,
        child: GestureDetector(
          behavior: HitTestBehavior.translucent,
          onPanStart: (_) => NativeWindow.startResize(edge),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = thickness;
    final c = t * 2; // 角は少し広めに
    return Stack(
      children: [
        Positioned.fill(child: child),
        // 辺  (WMSZ_LEFT=1, RIGHT=2, TOP=3, BOTTOM=6)
        _edge(left: 0, top: c, bottom: c, width: t,
            cursor: SystemMouseCursors.resizeLeftRight, edge: 1),
        _edge(right: 0, top: c, bottom: c, width: t,
            cursor: SystemMouseCursors.resizeLeftRight, edge: 2),
        _edge(left: c, right: c, top: 0, height: t,
            cursor: SystemMouseCursors.resizeUpDown, edge: 3),
        _edge(left: c, right: c, bottom: 0, height: t,
            cursor: SystemMouseCursors.resizeUpDown, edge: 6),
        // 角  (TOPLEFT=4, TOPRIGHT=5, BOTTOMLEFT=7, BOTTOMRIGHT=8)
        _edge(left: 0, top: 0, width: c, height: c,
            cursor: SystemMouseCursors.resizeUpLeftDownRight, edge: 4),
        _edge(right: 0, top: 0, width: c, height: c,
            cursor: SystemMouseCursors.resizeUpRightDownLeft, edge: 5),
        _edge(left: 0, bottom: 0, width: c, height: c,
            cursor: SystemMouseCursors.resizeUpRightDownLeft, edge: 7),
        _edge(right: 0, bottom: 0, width: c, height: c,
            cursor: SystemMouseCursors.resizeUpLeftDownRight, edge: 8),
      ],
    );
  }
}
