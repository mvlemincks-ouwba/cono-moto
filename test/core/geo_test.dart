import 'package:cono_moto/core/geo.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const paris = GeoPoint(48.8566, 2.3522);
  const lyon = GeoPoint(45.7640, 4.8357);

  test('distance Paris-Lyon ~392 km', () {
    expect(Geo.distance(paris, lyon) / 1000, closeTo(392, 3));
  });

  test('cap et destination sont cohérents', () {
    final b = Geo.bearing(paris, lyon);
    final d = Geo.distance(paris, lyon);
    final dest = Geo.destination(paris, b, d);
    expect(Geo.distance(dest, lyon), lessThan(500));
  });

  test('headingDelta gère le passage par le nord', () {
    expect(Geo.headingDelta(350, 10), closeTo(20, 1e-9));
    expect(Geo.headingDelta(10, 350), closeTo(-20, 1e-9));
  });

  test('polyline encode/decode aller-retour', () {
    final pts = [paris, lyon, const GeoPoint(43.2965, 5.3698)];
    for (final precision in [5, 6]) {
      final decoded = Geo.decodePolyline(Geo.encodePolyline(pts, precision: precision), precision: precision);
      expect(decoded.length, pts.length);
      for (var i = 0; i < pts.length; i++) {
        expect(decoded[i].lat, closeTo(pts[i].lat, 1e-5));
        expect(decoded[i].lng, closeTo(pts[i].lng, 1e-5));
      }
    }
  });

  test('décodage d\'un exemple Google connu', () {
    final pts = Geo.decodePolyline('_p~iF~ps|U_ulLnnqC_mqNvxq`@');
    expect(pts.length, 3);
    expect(pts[0].lat, closeTo(38.5, 1e-6));
    expect(pts[0].lng, closeTo(-120.2, 1e-6));
    expect(pts[2].lat, closeTo(43.252, 1e-6));
    expect(pts[2].lng, closeTo(-126.453, 1e-6));
  });

  test('projection sur une ligne', () {
    final line = [const GeoPoint(45.0, 5.0), const GeoPoint(45.0, 5.1)];
    final p = Geo.project(const GeoPoint(45.001, 5.05), line)!;
    expect(p.distanceFromLineM, closeTo(111, 2));
    expect(p.distanceAlongM, closeTo(Geo.length(line) / 2, 50));
  });

  test('simplify réduit une ligne droite à 2 points', () {
    final line = [for (var i = 0; i <= 50; i++) GeoPoint(45.0, 5.0 + i * 0.001)];
    expect(Geo.simplify(line, 5).length, 2);
  });

  test('pointAtDistance au milieu', () {
    final line = [const GeoPoint(45.0, 5.0), const GeoPoint(45.0, 5.1)];
    final mid = Geo.pointAtDistance(line, Geo.length(line) / 2);
    expect(mid.lng, closeTo(5.05, 1e-6));
  });
}
