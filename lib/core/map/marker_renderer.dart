import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'map_models.dart';

/// Dessine les images des marqueurs (PNG) pour la carte MapLibre.
class MarkerRenderer {
  MarkerRenderer(this.pixelRatio);

  final double pixelRatio;
  final Map<String, Uint8List> _cache = {};

  Future<Uint8List> render(MapMarker m) async {
    final cached = _cache[m.imageKey];
    if (cached != null) return cached;
    final bytes = await _draw(m);
    _cache[m.imageKey] = bytes;
    return bytes;
  }

  Future<Uint8List> _draw(MapMarker m) async {
    final logicalSize = _logicalSize(m);
    final w = (logicalSize.width * pixelRatio).ceil();
    final h = (logicalSize.height * pixelRatio).ceil();
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder, Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()));
    canvas.scale(pixelRatio);
    switch (m.style) {
      case MarkerStyle.pin:
        _drawPin(canvas, m, logicalSize);
      case MarkerStyle.avatar:
        _drawAvatar(canvas, m, logicalSize);
      case MarkerStyle.dot:
        _drawDot(canvas, m, logicalSize);
      case MarkerStyle.tag:
        _drawTag(canvas, m, logicalSize);
    }
    final image = await recorder.endRecording().toImage(w, h);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    return data!.buffer.asUint8List();
  }

  Size _logicalSize(MapMarker m) {
    switch (m.style) {
      case MarkerStyle.tag:
        final tp = _text(m.text ?? '', m.size * 0.42, Colors.white, FontWeight.w800);
        final iconW = m.icon != null ? m.size * 0.5 : 0.0;
        return Size(tp.width + iconW + m.size * 0.5 + 6, m.size * 0.8 + 8);
      case MarkerStyle.dot:
        return Size(m.size * 0.5 + 6, m.size * 0.5 + 6);
      default:
        return Size(m.size + 8, m.size + 8);
    }
  }

  TextPainter _text(String text, double fontSize, Color color, FontWeight weight,
      {String? fontFamily, String? package}) {
    final tp = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          fontSize: fontSize,
          color: color,
          fontWeight: weight,
          fontFamily: fontFamily,
          package: package,
          height: 1.0,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    return tp;
  }

  void _shadow(Canvas canvas, Offset c, double r) {
    canvas.drawCircle(
      c.translate(0, 1.5),
      r,
      Paint()
        ..color = Colors.black.withValues(alpha: 0.35)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3),
    );
  }

  void _drawIcon(Canvas canvas, IconData icon, Offset center, double size, Color color) {
    final tp = _text(String.fromCharCode(icon.codePoint), size, color, FontWeight.normal,
        fontFamily: icon.fontFamily, package: icon.fontPackage);
    tp.paint(canvas, center - Offset(tp.width / 2, tp.height / 2));
  }

  void _drawPin(Canvas canvas, MapMarker m, Size s) {
    final c = Offset(s.width / 2, s.height / 2);
    final r = m.size / 2;
    _shadow(canvas, c, r);
    canvas.drawCircle(c, r, Paint()..color = Colors.white);
    canvas.drawCircle(c, r - (m.highlighted ? 3.5 : 2.5), Paint()..color = m.color);
    if (m.icon != null) {
      _drawIcon(canvas, m.icon!, c, m.size * 0.55, Colors.white);
    } else if (m.text != null) {
      final tp = _text(m.text!, m.size * 0.4, Colors.white, FontWeight.w800);
      tp.paint(canvas, c - Offset(tp.width / 2, tp.height / 2));
    }
  }

  void _drawAvatar(Canvas canvas, MapMarker m, Size s) {
    final c = Offset(s.width / 2, s.height / 2);
    final r = m.size / 2;
    _shadow(canvas, c, r);
    if (m.highlighted) {
      canvas.drawCircle(c, r + 1, Paint()..color = const Color(0xFFEF4444));
    }
    canvas.drawCircle(c, r - (m.highlighted ? 2 : 0), Paint()..color = m.color);
    canvas.drawCircle(
      c,
      r - 3,
      Paint()
        ..color = Colors.white
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2,
    );
    final text = (m.text ?? '?').toUpperCase();
    final tp = _text(text, m.size * (text.length > 2 ? 0.3 : 0.38), Colors.white, FontWeight.w800);
    tp.paint(canvas, c - Offset(tp.width / 2, tp.height / 2));
  }

  void _drawDot(Canvas canvas, MapMarker m, Size s) {
    final c = Offset(s.width / 2, s.height / 2);
    final r = m.size / 4;
    _shadow(canvas, c, r);
    canvas.drawCircle(c, r + 2, Paint()..color = Colors.white);
    canvas.drawCircle(c, r, Paint()..color = m.color);
  }

  void _drawTag(Canvas canvas, MapMarker m, Size s) {
    final rect = Rect.fromLTWH(3, 3, s.width - 6, s.height - 8);
    final rr = RRect.fromRectAndRadius(rect, Radius.circular(rect.height / 2));
    canvas.drawRRect(
      rr.shift(const Offset(0, 1.5)),
      Paint()
        ..color = Colors.black.withValues(alpha: 0.35)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3),
    );
    // Petite pointe vers le bas.
    final tip = Path()
      ..moveTo(s.width / 2 - 5, rect.bottom - 1)
      ..lineTo(s.width / 2, math.min(s.height - 1, rect.bottom + 5))
      ..lineTo(s.width / 2 + 5, rect.bottom - 1)
      ..close();
    canvas.drawPath(tip, Paint()..color = m.highlighted ? Colors.white : m.color);
    canvas.drawRRect(rr, Paint()..color = m.highlighted ? Colors.white : m.color);
    canvas.drawRRect(rr.deflate(m.highlighted ? 2.5 : 0), Paint()..color = m.color);
    var x = rect.left + m.size * 0.25;
    if (m.icon != null) {
      _drawIcon(canvas, m.icon!, Offset(x + m.size * 0.2, rect.center.dy), m.size * 0.42, Colors.white);
      x += m.size * 0.5;
    }
    final tp = _text(m.text ?? '', m.size * 0.42, Colors.white, FontWeight.w800);
    tp.paint(canvas, Offset(x, rect.center.dy - tp.height / 2));
  }
}
