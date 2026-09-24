import 'dart:math' as math;

/// 配置案 3「右下にまとめる」：Message Manager を右下、そのすぐ上に同じ幅で予定を置く。
///
/// 1920×1080 の画面で Message Manager 864×704、予定 574×300、余白 16 を基準にし、
/// 実際の作業領域（タスクバーを除いた範囲）の幅に合わせて拡大縮小する。
({Map<String, int> main, Map<String, int> calendar}) cornerLayout(
    Map<String, int> workArea) {
  final wx = workArea['x']!, wy = workArea['y']!;
  final ww = workArea['w']!, wh = workArea['h']!;
  final s = ww / 1920.0;
  final m = (16 * s).round();

  final mainW = (864 * s).round();
  final mainH = math.min((704 * s).round(), wh - 2 * m - 160);
  final mainX = wx + ww - m - mainW;
  final mainY = wy + wh - m - mainH;

  // 予定はメッセージのすぐ上に、同じ幅・同じ左右位置でそろえる
  final gap = (6 * s).round();
  final calW = mainW;
  final calX = mainX;
  final calY = wy + m;
  final calH = math.max(160, mainY - gap - calY);

  return (
    main: {'x': mainX, 'y': mainY, 'w': mainW, 'h': mainH},
    calendar: {'x': calX, 'y': calY, 'w': calW, 'h': calH},
  );
}
