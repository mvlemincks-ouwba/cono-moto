import 'dart:math' as math;

import '../../core/geo.dart';

/// Vecteur 3D minimal (repère du téléphone, unités libres).
class Vec3 {
  const Vec3(this.x, this.y, this.z);

  static const zero = Vec3(0, 0, 0);

  final double x;
  final double y;
  final double z;

  Vec3 operator +(Vec3 o) => Vec3(x + o.x, y + o.y, z + o.z);
  Vec3 operator -(Vec3 o) => Vec3(x - o.x, y - o.y, z - o.z);
  Vec3 operator *(double k) => Vec3(x * k, y * k, z * k);

  double dot(Vec3 o) => x * o.x + y * o.y + z * o.z;

  Vec3 cross(Vec3 o) => Vec3(y * o.z - z * o.y, z * o.x - x * o.z, x * o.y - y * o.x);

  double get norm => math.sqrt(dot(this));

  Vec3 normalized() {
    final n = norm;
    return n < 1e-12 ? this : this * (1 / n);
  }

  @override
  String toString() => 'Vec3(${x.toStringAsFixed(3)}, ${y.toStringAsFixed(3)}, ${z.toStringAsFixed(3)})';
}

/// Origine de l'angle publié.
enum LeanSource {
  /// Pas assez d'informations (arrêt, GPS perdu, calibrage en cours sans cap GPS).
  none,

  /// Gyroscope (vitesse de lacet) + vitesse GPS : méthode principale.
  gyroscope,

  /// Repli sans gyroscope : dérivée du cap GPS.
  gpsHeading,
}

/// Réglages de l'estimateur d'angle.
class LeanAngleConfig {
  const LeanAngleConfig({
    this.minSpeedKmh = 12,
    this.maxLeanDeg = 65,
    this.smoothingTauS = 0.4,
    this.upCalibrationTauS = 3,
    this.minCalibrationS = 1,
    this.calibrationAccelToleranceG = 0.08,
    this.calibrationMaxGyroRadS = 0.3,
    this.calibrationMaxSpeedSlopeMs2 = 0.6,
    this.gyroTimeoutS = 1,
    this.gpsStaleS = 5,
    this.maxExtrapolationS = 1,
    this.gyroBiasTauS = 3,
  });

  /// En dessous, l'angle est forcé à 0 (manœuvres, arrêt : la formule n'a plus de sens).
  final double minSpeedKmh;

  /// Borne de l'angle publié (en degrés, de chaque côté).
  final double maxLeanDeg;

  /// Constante de temps du lissage exponentiel de l'angle.
  final double smoothingTauS;

  /// Constante de temps de la moyenne de l'axe « haut de la moto ».
  final double upCalibrationTauS;

  /// Durée cumulée d'échantillons valides avant de faire confiance à l'axe « haut ».
  final double minCalibrationS;

  /// Tolérance sur |accélération| ≈ g pour retenir un échantillon de calibrage.
  final double calibrationAccelToleranceG;

  /// Rotation maximale (rad/s, filtrée) pour retenir un échantillon de calibrage.
  final double calibrationMaxGyroRadS;

  /// Variation de vitesse GPS maximale (m/s²) pour retenir un échantillon de calibrage
  /// (exclut les freinages / accélérations qui inclinent la force mesurée vers l'avant).
  final double calibrationMaxSpeedSlopeMs2;

  /// Sans échantillon gyroscope depuis ce délai, on bascule sur le cap GPS.
  final double gyroTimeoutS;

  /// Au-delà, la vitesse GPS est jugée périmée (tunnel…) : angle à 0.
  final double gpsStaleS;

  /// Horizon maximal d'extrapolation de la vitesse entre deux fixes GPS.
  final double maxExtrapolationS;

  /// Constante de temps de l'estimation du biais du gyroscope à l'arrêt.
  final double gyroBiasTauS;
}

/// Estimation de l'angle d'inclinaison de la moto, téléphone fixé sur le guidon.
///
/// ## Pourquoi pas l'accéléromètre seul ?
/// En virage stabilisé, la moto s'incline justement pour que la résultante
/// (pesanteur + force centrifuge) reste dans son plan de symétrie : un
/// accéléromètre solidaire de la moto mesure alors une force dirigée selon
/// l'axe « haut » de la moto (d'intensité g/cos φ), exactement comme en ligne
/// droite. Il ne voit donc pas l'angle. En revanche, cette propriété permet de
/// **calibrer l'axe « haut » de la moto** dans le repère du téléphone, quelle
/// que soit l'orientation du support.
///
/// ## Méthode
/// En virage stabilisé (moto ponctuelle, sans glisse) : `tan φ = v·ω / g`, avec
/// `v` la vitesse et `ω` la vitesse de lacet (rotation autour de la verticale).
///
/// * `v` : vitesse GPS (Doppler), extrapolée linéairement entre deux fixes
///   (1 Hz) à partir de la pente des deux derniers, sur 1 s au plus.
/// * Axe « haut » `u` : moyenne glissante de la direction de l'accéléromètre
///   quand |a| ≈ g, rotation faible et vitesse GPS stable (arrêt, ligne droite,
///   virage établi), après retrait du biais du gyroscope.
/// * Le gyroscope mesure, dans le repère de la moto inclinée de φ,
///   `ω·(sin φ · axe gauche + cos φ · axe haut) + roulis·axe avant`.
///   Sa projection sur l'axe haut vaut donc `ω·cos φ`, et
///   `tan φ = v·ω/g` devient `sin φ = v·(gyro·u)/g` : forme fermée qui
///   n'a besoin ni de l'axe avant ni d'itération, et qui **rejette exactement**
///   les rotations de roulis (mises sur l'angle) et de tangage (bosses,
///   plongée au freinage), orthogonales à `u`. C'est plus robuste au bruit
///   que la norme du gyroscope (dont le tangage fausse l'amplitude en ligne
///   droite) ; le signe vient naturellement de la projection.
/// * Repli sans gyroscope (ou avant calibrage) : `ω` = dérivée du cap GPS.
/// * Lissage exponentiel (τ ≈ 0,4 s), angle forcé à 0 sous 12 km/h, borné à ±65°.
///
/// ## Hypothèses et limites
/// * Téléphone rigidement fixé au guidon. La rotation du guidon (quelques
///   degrés à vitesse normale) est négligée ; les à-coups de direction
///   (contre-braquage) sont atténués par le lissage.
/// * Virage « stabilisé » : pendant les transitions rapides, l'angle a un léger
///   retard (lissage + vitesse GPS). Pas de prise en compte de la largeur du
///   pneu (l'angle réel du motard est un peu supérieur, de 1 à 3°).
/// * Une erreur ε sur l'axe « haut » donne une erreur d'angle du même ordre.
/// * Le biais du gyroscope est ré-estimé à chaque arrêt (vitesse GPS nulle).
///
/// Convention : **négatif = gauche, positif = droite** (degrés).
/// Toutes les dates doivent provenir de la même horloge (celle du système).
class LeanAngleEstimator {
  LeanAngleEstimator({this.config = const LeanAngleConfig()});

  final LeanAngleConfig config;

  static const double _g = Geo.g;
  static const double _rad2deg = 180 / math.pi;

  // --- GPS ---
  int? _gpsT1; // µs
  int? _gpsT0;
  double _v1 = 0;
  double _v0 = 0;
  double _speedSlope = 0; // m/s², lissée
  double? _heading1;
  GeoPoint? _pos1;

  // --- Capteurs ---
  Vec3? _up;
  double _upWeightS = 0;
  Vec3 _gyroBias = Vec3.zero;
  Vec3 _gyroLp = Vec3.zero;
  Vec3? _accLp;
  int? _lastGyroUs;
  int? _lastAccUs;

  // --- Sortie ---
  double _lean = 0;
  double _rawLean = 0;
  int? _leanUs;
  LeanSource _source = LeanSource.none;

  /// Angle lissé signé (degrés, négatif = gauche).
  double get leanDeg => _lean;

  /// Dernier angle brut (non lissé) calculé.
  double get rawLeanDeg => _rawLean;

  LeanSource get source => _source;

  /// L'axe « haut » de la moto est-il connu (gyroscope exploitable) ?
  bool get calibrated => _up != null && _upWeightS >= config.minCalibrationS;

  /// Progression du calibrage (0..1), pour l'affichage.
  double get calibrationProgress => (_upWeightS / config.minCalibrationS).clamp(0.0, 1.0);

  /// Axe « haut » estimé dans le repère du téléphone (unitaire), ou null.
  Vec3? get upAxis => _up;

  /// Biais estimé du gyroscope (rad/s).
  Vec3 get gyroBias => _gyroBias;

  /// Variation de vitesse GPS lissée (m/s²) : positive = accélération.
  double get speedSlopeMs2 => _speedSlope;

  /// Le gyroscope a-t-il émis récemment ?
  bool gyroActiveAt(DateTime t) => _gyroActive(t.microsecondsSinceEpoch);

  /// Angle à l'instant [t] : 0 si aucune mise à jour récente (GPS perdu…).
  double leanAt(DateTime t) {
    final last = _leanUs;
    if (last == null) return 0;
    final age = (t.microsecondsSinceEpoch - last) / 1e6;
    return age > config.gpsStaleS ? 0 : _lean;
  }

  void reset() {
    _gpsT1 = _gpsT0 = null;
    _v1 = _v0 = 0;
    _speedSlope = 0;
    _heading1 = null;
    _pos1 = null;
    _up = null;
    _upWeightS = 0;
    _gyroBias = Vec3.zero;
    _gyroLp = Vec3.zero;
    _accLp = null;
    _lastGyroUs = _lastAccUs = null;
    _lean = _rawLean = 0;
    _leanUs = null;
    _source = LeanSource.none;
  }

  /// Vitesse (m/s) estimée à l'instant [t] (µs) à partir des derniers fixes.
  double speedAtUs(int us) {
    final t1 = _gpsT1;
    if (t1 == null) return 0;
    final age = (us - t1) / 1e6;
    if (age > config.gpsStaleS) return 0;
    var slope = 0.0;
    final t0 = _gpsT0;
    if (t0 != null) {
      final dt = (t1 - t0) / 1e6;
      if (dt > 0 && dt <= 3) slope = ((_v1 - _v0) / dt).clamp(-10.0, 10.0);
    }
    final h = age.clamp(0.0, config.maxExtrapolationS);
    return math.max(0, _v1 + slope * h);
  }

  double speedAt(DateTime t) => speedAtUs(t.microsecondsSinceEpoch);

  /// Nouveau fix GPS. [headingDeg] : cap GPS (0 = nord, horaire) ; à défaut il
  /// est déduit de [position] et du fix précédent.
  void addGps(DateTime t, double speedMs, {double? headingDeg, GeoPoint? position}) {
    final us = t.microsecondsSinceEpoch;
    final t1 = _gpsT1;
    if (t1 != null && us <= t1) return;
    final v = speedMs.isFinite && speedMs > 0 ? speedMs : 0.0;
    final dt = t1 == null ? null : (us - t1) / 1e6;

    if (dt != null && dt < 5) {
      final raw = (v - _v1) / dt;
      _speedSlope += (raw - _speedSlope) * _alpha(dt, 1.0);
    } else {
      _speedSlope = 0;
    }

    var heading = headingDeg;
    final prevPos = _pos1;
    if (heading == null && position != null && prevPos != null && Geo.distance(prevPos, position) > 4) {
      heading = Geo.bearing(prevPos, position);
    }
    double? headingRateDegS;
    final prevHeading = _heading1;
    if (heading != null && prevHeading != null && dt != null && dt > 0 && dt <= 3) {
      headingRateDegS = Geo.headingDelta(prevHeading, heading) / dt;
    }

    _gpsT0 = t1;
    _v0 = _v1;
    _gpsT1 = us;
    _v1 = v;
    if (heading != null) _heading1 = heading;
    if (position != null) _pos1 = position;

    // Repli : pas de gyroscope exploitable → dérivée du cap GPS.
    if (!_gyroActive(us) || !calibrated) {
      if (v * 3.6 < config.minSpeedKmh) {
        _publish(us, 0, LeanSource.gpsHeading, smooth: false);
      } else if (headingRateDegS != null) {
        final omega = headingRateDegS / _rad2deg; // rad/s, horaire positif = droite
        final raw = math.atan(v * omega / _g) * _rad2deg;
        _publish(us, raw, LeanSource.gpsHeading, dtOverride: dt);
      }
    }
  }

  /// Échantillon d'accéléromètre (m/s², gravité incluse, repère du téléphone).
  void addAccelerometer(DateTime t, double x, double y, double z) {
    final us = t.microsecondsSinceEpoch;
    final a = Vec3(x, y, z);
    final last = _lastAccUs;
    final dt = last == null ? 0.02 : ((us - last) / 1e6).clamp(0.0, 0.2);
    if (last != null && us < last) return;
    _lastAccUs = us;

    final lp = _accLp;
    _accLp = lp == null ? a : lp + (a - lp) * _alpha(dt, 0.15);
    final acc = _accLp!;
    final n = acc.norm;
    if (n < 1e-6) return;

    final gyroMag = _gyroActive(us) ? _gyroLp.norm : 0.0;
    final v = speedAtUs(us);
    final gpsFresh = _gpsT1 != null && (us - _gpsT1!) / 1e6 <= config.gpsStaleS;
    final stableSpeed = !gpsFresh || _speedSlope.abs() <= config.calibrationMaxSpeedSlopeMs2 || v < 0.5;

    if ((n - _g).abs() <= config.calibrationAccelToleranceG * _g &&
        gyroMag <= config.calibrationMaxGyroRadS &&
        stableSpeed &&
        dt > 0) {
      final dir = acc * (1 / n);
      final up = _up;
      if (up == null) {
        _up = dir;
      } else {
        _up = (up + (dir - up) * _alpha(dt, config.upCalibrationTauS)).normalized();
      }
      _upWeightS += dt;
    }
  }

  /// Échantillon de gyroscope (rad/s, repère du téléphone, règle de la main droite).
  void addGyroscope(DateTime t, double x, double y, double z) {
    final us = t.microsecondsSinceEpoch;
    final last = _lastGyroUs;
    if (last != null && us < last) return;
    final dt = last == null ? 0.02 : ((us - last) / 1e6).clamp(0.0, 0.2);
    _lastGyroUs = us;

    final raw = Vec3(x, y, z);
    final w = raw - _gyroBias;
    _gyroLp = _gyroLp + (w - _gyroLp) * _alpha(dt, 0.15);

    final v = speedAtUs(us);
    final gpsFresh = _gpsT1 != null && (us - _gpsT1!) / 1e6 <= config.gpsStaleS;

    // Biais : moto à l'arrêt (GPS), téléphone immobile.
    final acc = _accLp;
    if (gpsFresh && v < 0.3 && acc != null && (acc.norm - _g).abs() < 0.05 * _g && _gyroLp.norm < 0.06 && dt > 0) {
      final b = _gyroBias + (raw - _gyroBias) * _alpha(dt, config.gyroBiasTauS);
      _gyroBias = b.norm > 0.05 ? b.normalized() * 0.05 : b;
    }

    final up = _up;
    if (up == null || !calibrated) return;

    if (!gpsFresh || v * 3.6 < config.minSpeedKmh) {
      _publish(us, 0, gpsFresh ? LeanSource.gyroscope : LeanSource.none, smooth: false);
      return;
    }
    // sin φ = v·(ω·u)/g ; lacet positif (anti-horaire vu de dessus) = virage à
    // gauche = angle négatif.
    final s = (-v * w.dot(up) / _g).clamp(-1.0, 1.0);
    final rawLean = math.asin(s) * _rad2deg;
    _publish(us, rawLean, LeanSource.gyroscope, dtOverride: dt);
  }

  bool _gyroActive(int us) {
    final last = _lastGyroUs;
    return last != null && (us - last) / 1e6 <= config.gyroTimeoutS;
  }

  void _publish(int us, double rawDeg, LeanSource source, {bool smooth = true, double? dtOverride}) {
    final clamped = rawDeg.clamp(-config.maxLeanDeg, config.maxLeanDeg).toDouble();
    _rawLean = clamped;
    _source = source;
    final last = _leanUs;
    if (!smooth || last == null) {
      _lean = clamped;
    } else {
      final dt = dtOverride ?? ((us - last) / 1e6);
      if (dt > 0) _lean += (clamped - _lean) * _alpha(dt, config.smoothingTauS);
    }
    _leanUs = us;
  }

  static double _alpha(double dt, double tau) => tau <= 0 ? 1 : 1 - math.exp(-dt / tau);
}
