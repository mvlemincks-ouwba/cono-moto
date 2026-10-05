import 'dart:math' as math;

import '../../core/geo.dart';

/// Calculs pour le téléchargement de cartes hors-ligne (logique pure).
class OfflineTiles {
  OfflineTiles._();

  static const minZoom = 6.0;

  /// Zoom max téléchargé : les tuiles vectorielles OpenFreeMap vont jusqu'au
  /// zoom 14, au-delà la carte est sur-zoomée sans nouveau téléchargement.
  static const maxZoom = 14.0;

  /// Taille moyenne observée d'une tuile vectorielle (octets) pour l'estimation.
  static const avgTileBytes = 28 * 1024;

  static int _lngToX(double lng, int z) => ((lng + 180) / 360 * (1 << z)).floor().clamp(0, (1 << z) - 1);

  static int _latToY(double lat, int z) {
    final r = lat.clamp(-85.0511, 85.0511) * math.pi / 180;
    final y = (1 - math.log(math.tan(r) + 1 / math.cos(r)) / math.pi) / 2 * (1 << z);
    return y.floor().clamp(0, (1 << z) - 1);
  }

  /// Nombre de tuiles couvrant [b] entre [minZ] et [maxZ] inclus.
  static int tileCount(GeoBounds b, {double minZ = minZoom, double maxZ = maxZoom}) {
    var total = 0;
    for (var z = minZ.floor(); z <= maxZ.floor(); z++) {
      final x1 = _lngToX(b.west, z), x2 = _lngToX(b.east, z);
      final y1 = _latToY(b.north, z), y2 = _latToY(b.south, z);
      total += (x2 - x1 + 1) * (y2 - y1 + 1);
    }
    return total;
  }

  /// Estimation de la taille en Mo.
  static double estimatedMb(GeoBounds b, {double minZ = minZoom, double maxZ = maxZoom}) =>
      tileCount(b, minZ: minZ, maxZ: maxZ) * avgTileBytes / (1024 * 1024);

  /// Zone à télécharger pour un itinéraire (marge de 5 km).
  static GeoBounds? forRoute(List<GeoPoint> points) => GeoBounds.fromPoints(points)?.expand(5000);
}
