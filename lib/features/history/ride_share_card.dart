// Carte de balade à partager (image PNG façon Strava) : la trace GPS stylisée
// sur fond asphalte et les grands chiffres de la balade, dessinées hors écran
// sur un Canvas (pas de tuiles de carte : rien à télécharger, rendu immédiat).
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../core/format.dart';
import '../../core/geo.dart';
import '../../core/theme.dart';
import '../../core/ui/widgets.dart';
import '../../data/models/garage.dart';
import '../../data/models/ride.dart';
import '../../services/ride/ride_stats.dart';
import 'ride_analysis.dart';

/// Taille de l'image : portrait 4:5, le format le mieux cadré par Instagram.
const rideCardSize = Size(1080, 1350);

/// Nombre maximal de points dessinés (au-delà, la trace est allégée).
const rideCardMaxPoints = 1500;

/// En dessous de cette emprise (m), la trace ne vaut pas un dessin.
const rideCardMinTraceSpanM = 100.0;

const _muted = Color(0x99FFFFFF);
const _leanLegend = ['< 15°', '15–30°', '30–40°', '40–48°', '48°+'];

// -----------------------------------------------------------------------------
// Contenu

/// Une stat de la carte : valeur déjà formatée, unité et libellé.
class CardStat {
  const CardStat(this.label, this.value, {this.unit, this.color});

  final String label;
  final String value;
  final String? unit;

  /// Couleur du chiffre (blanc par défaut).
  final Color? color;

  @override
  String toString() => '$label : $value${unit == null ? '' : ' $unit'}';
}

/// Tout ce qui est dessiné sur la carte, calculé une fois avant le dessin.
class RideCardContent {
  const RideCardContent({
    required this.overline,
    required this.title,
    this.bikeName,
    this.bikeColor,
    this.big,
    this.hero = const [],
    this.details = const [],
    this.trace = const [],
    this.leanRuns = const [],
  });

  /// « DIMANCHE 7 JUIN 2026 · 09:00 – 12:30 ».
  final String overline;
  final String title;
  final String? bikeName;
  final Color? bikeColor;

  /// Distance en très grand, à la place de la trace quand il n'y en a pas.
  final CardStat? big;

  /// Grands chiffres : distance, durée, moyenne.
  final List<CardStat> hero;

  /// Bandeau du bas : vitesse max, angles, D+, virages.
  final List<CardStat> details;

  /// Trace allégée (vide si absente ou trop courte).
  final List<GeoPoint> trace;

  /// Trace découpée par tranche d'angle (vide sans données d'angle).
  final List<ColoredRun> leanRuns;

  bool get hasTrace => trace.length >= 2;

  /// Assez de matière pour une image : une trace, ou au moins la distance.
  bool get canShare => hasTrace || big != null;
}

/// Stats de la carte : seulement celles qui existent pour cette balade.
({List<CardStat> hero, List<CardStat> details}) rideCardStats(RideStats s) {
  final moving = s.movingTimeS > 0 ? s.movingTimeS : s.totalTimeS;
  final inKm = s.distanceM >= 1000;
  Color? lean(double deg) => deg >= 1 ? CmColors.forLean(deg) : null;
  return (
    hero: [
      if (s.distanceM >= 1)
        CardStat(
          'Distance',
          inKm ? Fmt.km(s.distanceM) : Fmt.number(s.distanceM),
          unit: inKm ? 'km' : 'm',
          color: CmColors.orange,
        ),
      if (moving >= 60) CardStat('En roulant', Fmt.durationS(moving)),
      if (s.avgMovingSpeedKmh >= 1) CardStat('Moyenne', Fmt.number(s.avgMovingSpeedKmh), unit: 'km/h'),
    ],
    details: [
      if (s.maxSpeedKmh >= 1) CardStat('Vit. max', Fmt.number(s.maxSpeedKmh), unit: 'km/h'),
      // Sans téléphone calibré, pas d'angle du tout : on n'affiche pas « 0° ».
      if (s.maxLeanDeg >= 1) ...[
        CardStat('Angle G', '${s.maxLeanLeftDeg.round()}°', color: lean(s.maxLeanLeftDeg)),
        CardStat('Angle D', '${s.maxLeanRightDeg.round()}°', color: lean(s.maxLeanRightDeg)),
      ],
      if (s.elevationGainM >= 1) CardStat('D+', Fmt.number(s.elevationGainM), unit: 'm'),
      if (s.curveCount > 0) CardStat('Virages', '${s.curveCount}'),
    ],
  );
}

/// Prépare la carte d'une balade. [track] : points GPS complets (pour la trace
/// colorée par l'angle) ; à défaut, l'aperçu enregistré avec la balade.
RideCardContent buildRideCardContent(Ride ride, {List<TrackPoint> track = const [], Bike? bike}) {
  // Même filtre que l'aperçu enregistré : on écarte les points GPS imprécis.
  final maxAccuracy = const RideStatsConfig().maxAccuracyM;
  final kept = [
    for (final p in track)
      if (p.accuracyM == null || p.accuracyM! <= maxAccuracy) p,
  ];
  final raw = kept.length >= 2 ? [for (final p in kept) p.point] : ride.previewPoints;
  var trace = decimateTrace(raw);
  if (trace.length < 2 || traceSpanM(trace) < rideCardMinTraceSpanM) trace = const [];
  final withLean = trace.isNotEmpty && kept.length >= 2 && kept.any((p) => p.leanDeg.abs() >= 1);
  final runs = withLean
      ? colorRuns(kept, (p) => p.leanDeg.abs(), leanBucketThresholds, maxPoints: rideCardMaxPoints)
      : const <ColoredRun>[];

  final stats = rideCardStats(ride.stats);
  var hero = stats.hero;
  CardStat? big;
  if (trace.isEmpty && ride.stats.distanceM >= 1) {
    // Pas de trace : la distance (toujours en tête) prend sa place, en très grand.
    big = hero.first;
    hero = hero.sublist(1);
  }

  final end = ride.endedAt;
  final until = end != null && end.isAfter(ride.startedAt) ? ' – ${Fmt.time(end)}' : '';
  return RideCardContent(
    overline: '${Fmt.dateLong(ride.startedAt)} · ${Fmt.time(ride.startedAt)}$until'.toUpperCase(),
    title: ride.name,
    bikeName: bike?.name,
    bikeColor: bike?.color,
    big: big,
    hero: hero,
    details: stats.details,
    trace: trace,
    leanRuns: runs,
  );
}

/// Petit texte qui accompagne l'image (WhatsApp l'affiche en légende).
String rideCardShareText(Ride ride) {
  final s = ride.stats;
  final parts = [
    ride.name,
    if (s.distanceM >= 1) Fmt.distance(s.distanceM),
    if (s.maxLeanDeg >= 1) "${s.maxLeanDeg.round()}° d'angle max",
  ];
  return '${parts.join(' · ')} — balade du ${Fmt.date(ride.startedAt)}, enregistrée avec Cono Moto';
}

// -----------------------------------------------------------------------------
// Géométrie

/// Allège une trace à [maxPoints] points au plus, régulièrement répartis.
/// Le premier et le dernier point sont toujours gardés.
List<T> decimateTrace<T>(List<T> points, {int maxPoints = rideCardMaxPoints}) {
  if (points.length <= maxPoints) return List.of(points);
  final n = math.max(2, maxPoints);
  final step = (points.length - 1) / (n - 1);
  return [for (var i = 0; i < n; i++) points[(i * step).round()]];
}

/// Diagonale (m) du rectangle qui englobe la trace.
double traceSpanM(List<GeoPoint> points) {
  final b = GeoBounds.fromPoints(points);
  if (b == null) return 0;
  return Geo.distance(GeoPoint(b.south, b.west), GeoPoint(b.north, b.east));
}

/// Projection d'une trace dans un cadre : équirectangulaire locale (longitudes
/// corrigées par cos(lat)), même échelle sur les deux axes, trace centrée.
class TraceFit {
  const TraceFit._({
    required this.west,
    required this.north,
    required this.cosLat,
    required this.scale,
    required this.origin,
  });

  /// Null si [points] est vide. Un point seul (ou des points confondus) est
  /// placé au centre du cadre.
  static TraceFit? fit(Iterable<GeoPoint> points, Rect frame) {
    final b = GeoBounds.fromPoints(points);
    if (b == null) return null;
    final cosLat = math.cos(b.center.lat * math.pi / 180).abs().clamp(0.01, 1.0);
    // Largeur et hauteur en « degrés de latitude » (mêmes mètres sur les deux axes).
    final w = (b.east - b.west) * cosLat;
    final h = b.north - b.south;
    final sx = w > 0 ? frame.width / w : double.infinity;
    final sy = h > 0 ? frame.height / h : double.infinity;
    var scale = math.min(sx, sy);
    if (!scale.isFinite) scale = 0;
    return TraceFit._(
      west: b.west,
      north: b.north,
      cosLat: cosLat,
      scale: scale,
      origin: Offset(frame.left + (frame.width - w * scale) / 2, frame.top + (frame.height - h * scale) / 2),
    );
  }

  final double west;
  final double north;
  final double cosLat;

  /// Pixels par degré de latitude.
  final double scale;

  /// Coin haut-gauche de la trace projetée.
  final Offset origin;

  Offset map(GeoPoint p) =>
      Offset(origin.dx + (p.lng - west) * cosLat * scale, origin.dy + (north - p.lat) * scale);
}

// -----------------------------------------------------------------------------
// Dessin

/// Dessine la carte et l'encode en PNG ([rideCardSize]).
Future<Uint8List> renderRideCardPng(RideCardContent content) async {
  await _fontsReady();
  final recorder = ui.PictureRecorder();
  paintRideCard(Canvas(recorder, Offset.zero & rideCardSize), content);
  final picture = recorder.endRecording();
  final image = await picture.toImage(rideCardSize.width.round(), rideCardSize.height.round());
  try {
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    if (data == null) throw StateError('encodage PNG impossible');
    return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
  } finally {
    image.dispose();
    picture.dispose();
  }
}

/// Les polices Google se chargent en asynchrone (déjà prêtes après le premier
/// écran) : on les demande, on attend un peu, sinon police de repli.
Future<void> _fontsReady() async {
  _numbers(10);
  _numbers(10, weight: FontWeight.w600);
  for (final weight in const [FontWeight.w600, FontWeight.w700, FontWeight.w800]) {
    _text(10, weight: weight);
  }
  try {
    await GoogleFonts.pendingFonts().timeout(const Duration(seconds: 2));
  } catch (_) {}
}

TextStyle _numbers(double size, {FontWeight weight = FontWeight.w700, Color color = Colors.white}) =>
    CmTheme.numbers(size: size, weight: weight, color: color);

TextStyle _text(double size, {FontWeight weight = FontWeight.w600, Color color = Colors.white, double spacing = 0}) =>
    GoogleFonts.barlow(fontSize: size, fontWeight: weight, color: color, letterSpacing: spacing);

/// Dessine la carte sur [canvas] (repère de [rideCardSize]).
void paintRideCard(Canvas canvas, RideCardContent c) {
  final w = rideCardSize.width;
  final h = rideCardSize.height;
  const m = 72.0;

  // Fond asphalte en dégradé + quadrillage discret (comme l'aperçu du récap).
  canvas.drawRect(
    Offset.zero & rideCardSize,
    Paint()
      ..shader = ui.Gradient.linear(
        Offset.zero,
        Offset(w, h),
        const [CmColors.asphalt600, CmColors.asphalt800, CmColors.asphalt900],
        const [0, 0.55, 1],
      ),
  );
  final grid = Paint()
    ..color = Colors.white.withValues(alpha: 0.035)
    ..strokeWidth = 2;
  for (var x = 60.0; x < w; x += 60) {
    canvas.drawLine(Offset(x, 0), Offset(x, h), grid);
  }
  for (var y = 60.0; y < h; y += 60) {
    canvas.drawLine(Offset(0, y), Offset(w, y), grid);
  }

  // En-tête : date, nom de la balade, moto.
  var y = m;
  final overline = _layout(
    TextSpan(text: c.overline, style: _text(30, weight: FontWeight.w800, color: CmColors.orange, spacing: 3)),
    maxWidth: w - 2 * m,
    maxLines: 1,
  );
  overline.paint(canvas, Offset(m, y));
  y += overline.height + 10;
  overline.dispose();
  final title = _layout(
    TextSpan(text: c.title, style: _numbers(88)),
    maxWidth: w - 2 * m,
    maxLines: 2,
  );
  title.paint(canvas, Offset(m, y));
  y += title.height + 20;
  title.dispose();
  final bike = c.bikeName;
  if (bike != null && bike.trim().isNotEmpty) {
    y += _paintBikePill(canvas, Offset(m, y), bike, c.bikeColor ?? CmColors.orange) + 16;
  }
  final top = y + 4;

  // Bas de la carte, de bas en haut : signature, bandeau, grands chiffres.
  final footer = Rect.fromLTWH(m, h - 64 - 44, w - 2 * m, 44);
  _paintFooter(canvas, footer);
  var bottom = footer.top - 36;
  if (c.details.isNotEmpty) {
    final panel = Rect.fromLTRB(m, bottom - 140, w - m, bottom);
    canvas.drawRRect(
      RRect.fromRectAndRadius(panel, const Radius.circular(32)),
      Paint()..color = Colors.white.withValues(alpha: 0.05),
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(panel.deflate(1), const Radius.circular(31)),
      Paint()
        ..color = Colors.white.withValues(alpha: 0.08)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2,
    );
    _paintColumns(canvas, panel, c.details, valueSize: 62, unitSize: 28, labelSize: 21, dividers: true);
    bottom = panel.top - 32;
  }
  if (c.hero.isNotEmpty) {
    final row = Rect.fromLTRB(m, bottom - 156, w - m, bottom);
    _paintColumns(canvas, row, c.hero, valueSize: 120, unitSize: 44, labelSize: 25);
    bottom = row.top - 28;
  }

  // Au milieu : la trace, ou la distance en très grand.
  final zone = Rect.fromLTRB(m, top, w - m, math.max(top + 120, bottom));
  if (c.hasTrace) {
    _paintTrace(canvas, zone, c);
  } else if (c.big != null) {
    _paintBig(canvas, zone, c.big!);
  }
}

/// Mise en page d'un texte (avec points de suspension au-delà de [maxLines]).
TextPainter _layout(InlineSpan span, {double maxWidth = double.infinity, int? maxLines}) => TextPainter(
  text: span,
  textDirection: TextDirection.ltr,
  maxLines: maxLines,
  ellipsis: maxLines == null ? null : '…',
)..layout(maxWidth: maxWidth);

/// Mise en page sur une ligne, réduite si besoin pour tenir dans [maxWidth]
/// (façon FittedBox).
TextPainter _fitted(InlineSpan span, double maxWidth) {
  final tp = _layout(span);
  if (tp.width <= maxWidth) return tp;
  final factor = maxWidth / tp.width;
  tp.dispose();
  return TextPainter(text: span, textDirection: TextDirection.ltr, textScaler: TextScaler.linear(factor))..layout();
}

/// Colonnes centrées « grand chiffre + unité / libellé ».
void _paintColumns(
  Canvas canvas,
  Rect area,
  List<CardStat> stats, {
  required double valueSize,
  required double unitSize,
  required double labelSize,
  bool dividers = false,
}) {
  final colW = area.width / stats.length;
  for (var i = 0; i < stats.length; i++) {
    final s = stats[i];
    final cx = area.left + colW * (i + 0.5);
    final value = _fitted(
      TextSpan(
        children: [
          TextSpan(text: s.value, style: _numbers(valueSize, color: s.color ?? Colors.white)),
          if (s.unit != null)
            TextSpan(text: ' ${s.unit}', style: _numbers(unitSize, weight: FontWeight.w600, color: _muted)),
        ],
      ),
      colW - 20,
    );
    final label = _fitted(
      TextSpan(
        text: s.label.toUpperCase(),
        style: _text(labelSize, weight: FontWeight.w800, color: _muted, spacing: 2),
      ),
      colW - 20,
    );
    final blockH = value.height + 12 + label.height;
    final y0 = area.center.dy - blockH / 2;
    value.paint(canvas, Offset(cx - value.width / 2, y0));
    label.paint(canvas, Offset(cx - label.width / 2, y0 + value.height + 12));
    value.dispose();
    label.dispose();
    if (dividers && i > 0) {
      final x = area.left + colW * i;
      canvas.drawLine(
        Offset(x, area.top + 28),
        Offset(x, area.bottom - 28),
        Paint()
          ..color = Colors.white.withValues(alpha: 0.08)
          ..strokeWidth = 2,
      );
    }
  }
}

/// Pastille de la moto (icône + nom) ; renvoie sa hauteur.
double _paintBikePill(Canvas canvas, Offset at, String name, Color color) {
  // Une moto noire sur fond asphalte serait invisible : on éclaircit.
  final accent = color.computeLuminance() < 0.06 ? Colors.white : color;
  const icon = Icons.two_wheeler_rounded;
  final glyph = _layout(
    TextSpan(
      text: String.fromCharCode(icon.codePoint),
      style: TextStyle(fontFamily: icon.fontFamily, package: icon.fontPackage, fontSize: 30, color: accent),
    ),
  );
  final label = _layout(TextSpan(text: name, style: _text(28, weight: FontWeight.w700)), maxWidth: 640, maxLines: 1);
  const padH = 22.0, gap = 12.0, height = 54.0;
  final pill = Rect.fromLTWH(at.dx, at.dy, padH + glyph.width + gap + label.width + padH, height);
  canvas.drawRRect(
    RRect.fromRectAndRadius(pill, const Radius.circular(height / 2)),
    Paint()..color = accent.withValues(alpha: 0.16),
  );
  glyph.paint(canvas, Offset(pill.left + padH, pill.center.dy - glyph.height / 2));
  label.paint(canvas, Offset(pill.left + padH + glyph.width + gap, pill.center.dy - label.height / 2));
  glyph.dispose();
  label.dispose();
  return height;
}

/// Couleur d'une tranche d'angle (mêmes seuils que la carte du détail).
Color _leanBucketColor(int bucket) => CmColors.forLean(bucket == 0 ? 0 : leanBucketThresholds[bucket - 1]);

Paint _stroke(Color color, double width, {StrokeCap cap = StrokeCap.round}) => Paint()
  ..color = color
  ..style = PaintingStyle.stroke
  ..strokeWidth = width
  ..strokeCap = cap
  ..strokeJoin = StrokeJoin.round;

void _paintTrace(Canvas canvas, Rect zone, RideCardContent c) {
  final legend = c.leanRuns.isNotEmpty;
  final frame = Rect.fromLTRB(zone.left + 28, zone.top + 28, zone.right - 28, zone.bottom - (legend ? 76 : 28));
  final lines = legend ? [for (final r in c.leanRuns) r.points] : [c.trace];
  final fit = TraceFit.fit([for (final l in lines) ...l, c.trace.first, c.trace.last], frame)!;

  // Halo orange derrière la trace.
  canvas.drawCircle(
    frame.center,
    frame.longestSide * 0.62,
    Paint()
      ..shader = ui.Gradient.radial(frame.center, frame.longestSide * 0.62, [
        CmColors.orange.withValues(alpha: 0.16),
        CmColors.orange.withValues(alpha: 0),
      ]),
  );

  Path pathOf(List<GeoPoint> points) {
    final first = fit.map(points.first);
    final path = Path()..moveTo(first.dx, first.dy);
    for (var i = 1; i < points.length; i++) {
      final o = fit.map(points[i]);
      path.lineTo(o.dx, o.dy);
    }
    return path;
  }

  final whole = Path();
  for (final l in lines) {
    whole.addPath(pathOf(l), Offset.zero);
  }
  // Lueur + liseré sombre pour détacher la ligne du fond.
  canvas.drawPath(
    whole,
    _stroke(CmColors.orange.withValues(alpha: 0.4), 30)..maskFilter = const MaskFilter.blur(BlurStyle.normal, 14),
  );
  canvas.drawPath(whole, _stroke(Colors.black.withValues(alpha: 0.55), 18));
  if (legend) {
    // Bouts plats : des bouts ronds feraient un chapelet de perles quand
    // l'angle change souvent.
    for (final r in c.leanRuns) {
      canvas.drawPath(pathOf(r.points), _stroke(_leanBucketColor(r.bucket), 10, cap: StrokeCap.butt));
    }
  } else {
    canvas.drawPath(
      whole,
      _stroke(CmColors.orange, 10)
        ..shader = ui.Gradient.linear(frame.topLeft, frame.bottomRight, const [
          CmColors.amber,
          CmColors.orange,
          CmColors.orangeDeep,
        ], const [0, 0.5, 1]),
    );
  }

  // Départ (vert) et arrivée (damier) ; une boucle n'a que le départ.
  if (Geo.distance(c.trace.first, c.trace.last) > 80) _paintFinish(canvas, fit.map(c.trace.last));
  _paintStart(canvas, fit.map(c.trace.first));

  if (legend) _paintLeanLegend(canvas, Offset(zone.left + 28, zone.bottom - 40));
}

void _paintStart(Canvas canvas, Offset at) {
  canvas.drawCircle(at, 25, Paint()..color = Colors.black.withValues(alpha: 0.45));
  canvas.drawCircle(at, 20, Paint()..color = Colors.white);
  canvas.drawCircle(at, 14, Paint()..color = CmColors.green);
}

void _paintFinish(Canvas canvas, Offset at) {
  const r = 20.0;
  final box = Rect.fromCircle(center: at, radius: r);
  canvas.drawCircle(at, r + 5, Paint()..color = Colors.black.withValues(alpha: 0.45));
  canvas.save();
  canvas.clipPath(Path()..addOval(box));
  canvas.drawRect(box, Paint()..color = Colors.white);
  const n = 4;
  const cell = 2 * r / n;
  final dark = Paint()..color = CmColors.asphalt900;
  for (var i = 0; i < n; i++) {
    for (var j = 0; j < n; j++) {
      if ((i + j).isOdd) canvas.drawRect(Rect.fromLTWH(box.left + i * cell, box.top + j * cell, cell, cell), dark);
    }
  }
  canvas.restore();
  canvas.drawCircle(at, r, _stroke(Colors.white, 4));
}

/// Légende des couleurs d'angle, sur une ligne.
void _paintLeanLegend(Canvas canvas, Offset at) {
  final title = _layout(
    TextSpan(text: 'ANGLE', style: _text(21, weight: FontWeight.w800, color: _muted, spacing: 2)),
  );
  title.paint(canvas, Offset(at.dx, at.dy - title.height / 2));
  var x = at.dx + title.width + 22;
  title.dispose();
  for (var i = 0; i < _leanLegend.length; i++) {
    canvas.drawCircle(Offset(x + 8, at.dy), 8, Paint()..color = _leanBucketColor(i));
    final label = _layout(TextSpan(text: _leanLegend[i], style: _text(22, color: _muted)));
    label.paint(canvas, Offset(x + 24, at.dy - label.height / 2));
    x += 24 + label.width + 22;
    label.dispose();
  }
}

/// Distance en très grand quand il n'y a pas de trace à dessiner.
void _paintBig(Canvas canvas, Rect zone, CardStat big) {
  canvas.drawCircle(
    zone.center,
    zone.shortestSide * 0.7,
    Paint()
      ..shader = ui.Gradient.radial(zone.center, zone.shortestSide * 0.7, [
        CmColors.orange.withValues(alpha: 0.16),
        CmColors.orange.withValues(alpha: 0),
      ]),
  );
  final value = _fitted(
    TextSpan(
      children: [
        TextSpan(text: big.value, style: _numbers(280, color: big.color ?? CmColors.orange)),
        if (big.unit != null)
          TextSpan(text: ' ${big.unit}', style: _numbers(96, weight: FontWeight.w600, color: _muted)),
      ],
    ),
    zone.width,
  );
  final label = _layout(
    TextSpan(text: big.label.toUpperCase(), style: _text(30, weight: FontWeight.w800, color: _muted, spacing: 3)),
  );
  final y0 = zone.center.dy - (value.height + 18 + label.height) / 2;
  value.paint(canvas, Offset(zone.center.dx - value.width / 2, y0));
  label.paint(canvas, Offset(zone.center.dx - label.width / 2, y0 + value.height + 18));
  value.dispose();
  label.dispose();
}

/// Signature : cône + « CONO MOTO », et la devise à droite.
void _paintFooter(Canvas canvas, Rect r) {
  _paintCone(canvas, Offset(r.left + 22, r.bottom - 4), 40);
  final brand = _layout(
    TextSpan(
      text: 'CONO MOTO',
      style: GoogleFonts.barlowCondensed(
        fontSize: 38,
        fontWeight: FontWeight.w700,
        color: Colors.white,
        letterSpacing: 2,
        height: 1.0,
      ),
    ),
  );
  brand.paint(canvas, Offset(r.left + 60, r.center.dy - brand.height / 2));
  brand.dispose();
  final tagline = _layout(TextSpan(text: 'Balades moto entre potes', style: _text(26, color: _muted)));
  tagline.paint(canvas, Offset(r.right - tagline.width, r.center.dy - tagline.height / 2));
  tagline.dispose();
}

/// Le cône de l'icône de l'app (corps orange, bande blanche, socle), penché
/// vers la gauche. [base] : centre du socle ; [height] : hauteur du cône.
void _paintCone(Canvas canvas, Offset base, double height) {
  final k = height / 104;
  double half(double y) => 34 + (4.5 - 34) * y / 104;
  canvas.save();
  canvas.translate(base.dx, base.dy);
  canvas.rotate(-15.5 * math.pi / 180);
  final body = Path()
    ..moveTo(-34 * k, 0)
    ..lineTo(34 * k, 0)
    ..lineTo(4.5 * k, -104 * k)
    ..arcToPoint(Offset(-4.5 * k, -104 * k), radius: Radius.circular(4.5 * k), clockwise: false)
    ..close();
  canvas.drawPath(body, Paint()..color = CmColors.orange);
  const lo = 52.0, hi = 65.5;
  final stripe = Path()
    ..moveTo(-half(lo) * k, -lo * k)
    ..lineTo(half(lo) * k, -lo * k)
    ..lineTo(half(hi) * k, -hi * k)
    ..lineTo(-half(hi) * k, -hi * k)
    ..close();
  canvas.drawPath(stripe, Paint()..color = Colors.white);
  canvas.drawRRect(
    RRect.fromLTRBR(-50 * k, -2.3 * k, 50 * k, 9.3 * k, Radius.circular(5.8 * k)),
    Paint()..color = CmColors.orangeDeep,
  );
  canvas.restore();
}

// -----------------------------------------------------------------------------
// Partage

/// Crée l'image de la balade et ouvre la feuille de partage (WhatsApp,
/// Instagram…). [track] : points GPS complets si on les a déjà.
Future<void> shareRideCard(
  BuildContext context, {
  required Ride ride,
  List<TrackPoint> track = const [],
  Bike? bike,
}) async {
  final box = context.findRenderObject() as RenderBox?;
  final origin = box == null || !box.hasSize ? null : box.localToGlobal(Offset.zero) & box.size;
  final content = buildRideCardContent(ride, track: track, bike: bike);
  if (!content.canShare) {
    showCmSnack(context, 'Balade trop courte pour en faire une image : roule encore un peu !');
    return;
  }
  try {
    final png = await renderRideCardPng(content);
    final dir = await getTemporaryDirectory();
    final name = '${safeFileName(ride.name)}.png';
    final file = File('${dir.path}/$name');
    await file.writeAsBytes(png, flush: true);
    await SharePlus.instance.share(
      ShareParams(
        files: [XFile(file.path, mimeType: 'image/png', name: name)],
        subject: 'Balade « ${ride.name} »',
        text: rideCardShareText(ride),
        sharePositionOrigin: origin,
      ),
    );
  } catch (e) {
    if (context.mounted) showCmSnack(context, "Impossible de créer l'image : $e", error: true);
  }
}
