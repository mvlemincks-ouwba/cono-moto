import 'package:flutter/material.dart';

import '../geo.dart';

/// Ligne à tracer sur la carte (itinéraire, trace GPS, incident…).
@immutable
class MapLine {
  const MapLine({
    required this.id,
    required this.points,
    this.color = const Color(0xFFFF6B1A),
    this.width = 5,
    this.opacity = 1,
    this.dashed = false,
    this.casing = true,
  });

  final String id;
  final List<GeoPoint> points;
  final Color color;
  final double width;
  final double opacity;
  final bool dashed;

  /// Liseré sombre autour de la ligne pour la lisibilité.
  final bool casing;
}

/// Apparence d'un marqueur.
enum MarkerStyle {
  /// Pastille ronde avec une icône.
  pin,

  /// Avatar rond avec initiales (potes).
  avatar,

  /// Petit point.
  dot,

  /// Étiquette rectangulaire avec un texte court (ex : prix « 1,84 »).
  tag,
}

/// Marqueur ponctuel sur la carte.
@immutable
class MapMarker {
  const MapMarker({
    required this.id,
    required this.position,
    this.style = MarkerStyle.pin,
    this.icon,
    this.text,
    this.color = const Color(0xFFFF6B1A),
    this.label,
    this.size = 36,
    this.zIndex = 0,
    this.highlighted = false,
    this.payload,
  });

  final String id;
  final GeoPoint position;
  final MarkerStyle style;
  final IconData? icon;

  /// Texte dans le marqueur (initiales pour un avatar, prix pour un tag).
  final String? text;
  final Color color;

  /// Texte affiché sous le marqueur.
  final String? label;

  /// Taille logique en pixels.
  final double size;

  /// Ordre d'empilement : les plus grands au-dessus.
  final int zIndex;

  /// Contour accentué (ex : moins cher, alerte SOS).
  final bool highlighted;

  /// Donnée libre renvoyée au tap.
  final Object? payload;

  /// Clé unique de l'image générée pour ce marqueur.
  String get imageKey =>
      'cm-${style.name}-${icon?.codePoint ?? 0}-${text ?? ''}-${color.toARGB32().toRadixString(16)}-${size.round()}-${highlighted ? 1 : 0}';
}

/// Mode de suivi de la position par la caméra.
enum FollowMode { none, follow, heading }
