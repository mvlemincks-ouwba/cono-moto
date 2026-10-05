import 'dart:math' as math;

import '../../core/geo.dart';
import '../../data/models/ride.dart';

/// Seuils du calcul des statistiques.
class RideStatsConfig {
  const RideStatsConfig({
    this.maxAccuracyM = 30,
    this.movingSpeedKmh = 5,
    this.maxPlausibleSpeedKmh = 320,
    this.maxIntervalS = 30,
    this.maxGapS = 1800,
    this.hardBrakeThresholdG = 0.45,
    this.hardAccelThresholdG = 0.35,
    this.minEventDurationS = 0.8,
    this.hardBrakeMinSpeedKmh = 25,
    this.hardAccelMinSpeedKmh = 5,
    this.curveEnterDeg = 15,
    this.curveExitDeg = 10,
    this.elevationHysteresisM = 3,
    this.altitudeSmoothingTauS = 5,
    this.stationaryRadiusM = 20,
  });

  /// Points moins précis ignorés.
  final double maxAccuracyM;

  /// Seuil « en mouvement ».
  final double movingSpeedKmh;

  /// Au-delà (vitesse déduite des positions), le point est une aberration GPS.
  final double maxPlausibleSpeedKmh;

  /// Intervalle maximal entre deux points pour les compter « normalement »
  /// (temps par tranche, accélérations). Au-delà : trou GPS.
  final double maxIntervalS;

  /// Trou GPS au-delà duquel on ne compte plus de temps en mouvement.
  final double maxGapS;

  /// Décélération (g) à partir de laquelle un freinage est « fort ».
  final double hardBrakeThresholdG;
  final double hardAccelThresholdG;

  /// Durée minimale d'un freinage / d'une accélération forte.
  final double minEventDurationS;

  /// Vitesse minimale au début d'un freinage pour qu'il compte.
  final double hardBrakeMinSpeedKmh;
  final double hardAccelMinSpeedKmh;

  /// Hystérésis des épisodes de virage (|angle|).
  final double curveEnterDeg;
  final double curveExitDeg;

  /// Hystérésis du dénivelé (m).
  final double elevationHysteresisM;
  final double altitudeSmoothingTauS;

  /// À l'arrêt, la distance n'avance que si on s'éloigne de plus de ce rayon.
  final double stationaryRadiusM;

  RideStatsConfig copyWith({double? hardBrakeThresholdG}) => RideStatsConfig(
    maxAccuracyM: maxAccuracyM,
    movingSpeedKmh: movingSpeedKmh,
    maxPlausibleSpeedKmh: maxPlausibleSpeedKmh,
    maxIntervalS: maxIntervalS,
    maxGapS: maxGapS,
    hardBrakeThresholdG: hardBrakeThresholdG ?? this.hardBrakeThresholdG,
    hardAccelThresholdG: hardAccelThresholdG,
    minEventDurationS: minEventDurationS,
    hardBrakeMinSpeedKmh: hardBrakeMinSpeedKmh,
    hardAccelMinSpeedKmh: hardAccelMinSpeedKmh,
    curveEnterDeg: curveEnterDeg,
    curveExitDeg: curveExitDeg,
    elevationHysteresisM: elevationHysteresisM,
    altitudeSmoothingTauS: altitudeSmoothingTauS,
    stationaryRadiusM: stationaryRadiusM,
  );
}

/// Résultat d'un calcul complet.
typedef RideStatsResult = ({RideStats stats, List<RideEvent> events});

/// Plage de pause manuelle (aucune distance ni durée comptée dedans).
typedef PauseWindow = ({DateTime start, DateTime? end});

/// Calcul incrémental des statistiques d'une balade.
///
/// Chaque point est traité en O(1) : utilisable en direct (un appel par fix
/// GPS) comme a posteriori ([compute]). Filtres appliqués :
/// * précision > 30 m ignorée, points dans le désordre ou en double ignorés,
///   sauts aberrants (> 320 km/h déduits des positions) ignorés ;
/// * à l'arrêt, les micro-déplacements du GPS ne comptent pas (rayon de 20 m) ;
/// * vitesse max = max de la médiane glissante sur 5 points (pas de pic isolé) ;
/// * freinages / accélérations à partir de la dérivée de la vitesse GPS lissée
///   (médiane sur 3 points), sur une durée ≥ 0,8 s ;
/// * dénivelé sur l'altitude lissée (EMA) avec hystérésis de 3 m.
class RideStatsCalculator {
  RideStatsCalculator({this.config = const RideStatsConfig()});

  final RideStatsConfig config;

  TrackPoint? _first;
  TrackPoint? _last;
  TrackPoint? _anchor;
  bool _breakPending = false;
  int _acceptedCount = 0;
  int _rejectedCount = 0;

  double _distance = 0;
  double _movingS = 0;
  double _totalS = 0;

  // Vitesse max (médiane sur 5).
  final List<double> _speedWin = [];
  double _maxSpeedKmh = 0;

  // Dérivée de la vitesse (médiane sur 3).
  final List<TrackPoint> _win3 = [];
  ({DateTime t, double v, TrackPoint p})? _prevSmooth;
  _Episode? _brake;
  _Episode? _accel;
  int _brakeCount = 0;
  int _accelCount = 0;
  double _maxDecelG = 0;
  double _maxAccelG = 0;
  final List<RideEvent> _events = [];

  // Angle.
  double _maxLeft = 0;
  double _maxRight = 0;
  TrackPoint? _maxLeftAt;
  TrackPoint? _maxRightAt;
  int _curveSign = 0;
  double _curvePeak = 0;
  int _curveCount = 0;
  double _curvePeakSum = 0;

  // Altitude.
  double? _altSmooth;
  double? _altRef;
  DateTime? _altTime;
  double _gain = 0;
  double _loss = 0;
  double? _maxAlt;

  // Histogrammes (secondes, non arrondies).
  final Map<int, double> _leanHist = {};
  final Map<int, double> _speedHist = {};

  int get acceptedCount => _acceptedCount;
  int get rejectedCount => _rejectedCount;
  double get distanceM => _distance;
  double get movingTimeS => _movingS;
  TrackPoint? get firstPoint => _first;
  TrackPoint? get lastPoint => _last;

  /// Nombre de virages, épisode en cours compris.
  int get curveCount => _curveCount + (_curveSign != 0 ? 1 : 0);

  /// Freinages forts, épisode en cours compris s'il est déjà qualifié.
  int get hardBrakeCount => _brakeCount + (_qualifies(_brake, config.hardBrakeMinSpeedKmh) ? 1 : 0);

  /// Le prochain point démarre un nouveau segment (après une pause) : pas de
  /// distance ni de temps comptés entre les deux.
  void breakSegment() {
    _closeBrake();
    _closeAccel();
    _closeCurve();
    _breakPending = true;
  }

  void addAll(Iterable<TrackPoint> points) {
    for (final p in points) {
      add(p);
    }
  }

  /// Ajoute un point. Retourne false s'il a été écarté (bruit).
  bool add(TrackPoint p) {
    if (!p.lat.isFinite || !p.lng.isFinite || (p.lat == 0 && p.lng == 0)) return _reject();
    final acc = p.accuracyM;
    if (acc != null && acc > config.maxAccuracyM) return _reject();

    final last = _last;
    if (last == null || _breakPending) {
      if (last != null && !p.time.isAfter(last.time)) return _reject();
      _startSegment(p);
      return true;
    }
    final dt = p.time.difference(last.time).inMicroseconds / 1e6;
    if (dt <= 0) return _reject();

    final d = Geo.distance(last.point, p.point);
    final implied = d / dt;
    if (dt < config.maxIntervalS && implied * 3.6 > config.maxPlausibleSpeedKmh) return _reject();

    _acceptedCount++;
    final gap = dt > config.maxIntervalS;
    final moveMs = config.movingSpeedKmh / 3.6;
    final meanSpeed = (_speedOf(p) + _speedOf(last)) / 2;
    final bool moving;
    if (gap) {
      moving = implied >= moveMs && dt <= config.maxGapS;
    } else {
      // Sans vitesse Doppler (0 sur les deux points), on se rabat sur la
      // vitesse déduite des positions, avec une marge contre le bruit.
      final noDoppler = p.speedMs <= 0 && last.speedMs <= 0;
      moving = meanSpeed >= moveMs || (noDoppler && implied >= moveMs * 1.8 && d > math.max(2 * (acc ?? 10), 15));
    }

    // Distance.
    final anchor = _anchor ?? last;
    if (moving) {
      _distance += Geo.distance(anchor.point, p.point);
      _anchor = p;
    } else {
      final da = Geo.distance(anchor.point, p.point);
      if (da > math.max(config.stationaryRadiusM, 2 * (acc ?? 0))) {
        _distance += da;
        _anchor = p;
      }
    }

    // Durées et histogrammes.
    _totalS += dt;
    if (moving) _movingS += dt;
    if (moving && !gap) {
      final leanKey = math.min(60, (last.leanDeg.abs() ~/ 10) * 10);
      _leanHist[leanKey] = (_leanHist[leanKey] ?? 0) + dt;
      final speedKey = ((meanSpeed * 3.6) ~/ 20) * 20;
      _speedHist[speedKey] = (_speedHist[speedKey] ?? 0) + dt;
    }

    // Vitesse max lissée.
    _pushSpeed(_speedOf(p, implied: dt <= 5 ? implied : null));

    // Accélérations.
    if (gap) {
      _closeBrake();
      _closeAccel();
      _win3.clear();
      _prevSmooth = null;
    }
    _pushForAccel(p);

    _processLean(p);
    _processAltitude(p);
    _last = p;
    return true;
  }

  bool _reject() {
    _rejectedCount++;
    return false;
  }

  void _startSegment(TrackPoint p) {
    _acceptedCount++;
    _first ??= p;
    _last = p;
    _anchor = p;
    _breakPending = false;
    _win3.clear();
    _prevSmooth = null;
    _pushSpeed(_speedOf(p));
    _pushForAccel(p);
    _processLean(p);
    _processAltitude(p);
  }

  /// Vitesse d'un point (m/s). Si le GPS annonce une vitesse très supérieure à
  /// celle déduite des positions, on prend la plus faible.
  double _speedOf(TrackPoint p, {double? implied}) {
    final v = p.speedMs.isFinite && p.speedMs > 0 ? p.speedMs : 0.0;
    if (implied != null && v > implied * 2 + 8) return implied;
    return v;
  }

  void _pushSpeed(double v) {
    _speedWin.add(v);
    if (_speedWin.length > 5) _speedWin.removeAt(0);
    final sorted = List.of(_speedWin)..sort();
    final median = sorted[(sorted.length - 1) ~/ 2];
    _maxSpeedKmh = math.max(_maxSpeedKmh, median * 3.6);
  }

  void _pushForAccel(TrackPoint p) {
    _win3.add(p);
    if (_win3.length > 3) _win3.removeAt(0);
    if (_win3.length < 3) return;
    final mid = _win3[1];
    final speeds = [for (final q in _win3) _speedOf(q)]..sort();
    final smoothed = speeds[1];
    final prev = _prevSmooth;
    _prevSmooth = (t: mid.time, v: smoothed, p: mid);
    if (prev == null) return;
    final dt = mid.time.difference(prev.t).inMicroseconds / 1e6;
    if (dt <= 0 || dt > 3) {
      _closeBrake();
      _closeAccel();
      return;
    }
    final a = (smoothed - prev.v) / dt;
    final aG = a / Geo.g;

    // Freinage.
    if (prev.v * 3.6 > 10) _maxDecelG = math.max(_maxDecelG, -aG);
    final brakeThr = config.hardBrakeThresholdG;
    if (-aG >= brakeThr) {
      final ep = _brake ??= _Episode(startSpeedMs: prev.v);
      ep.durationS += dt;
      if (-aG > ep.peakG) {
        ep.peakG = -aG;
        ep.at = mid;
      }
    } else if (-aG < brakeThr * 0.7) {
      _closeBrake();
    }

    // Accélération.
    if (prev.v * 3.6 > config.hardAccelMinSpeedKmh) _maxAccelG = math.max(_maxAccelG, aG);
    final accelThr = config.hardAccelThresholdG;
    if (aG >= accelThr) {
      final ep = _accel ??= _Episode(startSpeedMs: prev.v);
      ep.durationS += dt;
      if (aG > ep.peakG) {
        ep.peakG = aG;
        ep.at = mid;
      }
    } else if (aG < accelThr * 0.7) {
      _closeAccel();
    }
  }

  bool _qualifies(_Episode? ep, double minSpeedKmh) =>
      ep != null && ep.durationS >= config.minEventDurationS && ep.startSpeedMs * 3.6 > minSpeedKmh;

  void _closeBrake() {
    final ep = _brake;
    _brake = null;
    if (_qualifies(ep, config.hardBrakeMinSpeedKmh)) {
      _brakeCount++;
      _events.add(_eventOf('hard_brake', ep!));
    }
  }

  void _closeAccel() {
    final ep = _accel;
    _accel = null;
    if (_qualifies(ep, config.hardAccelMinSpeedKmh)) {
      _accelCount++;
      _events.add(_eventOf('hard_accel', ep!));
    }
  }

  RideEvent _eventOf(String type, _Episode ep) => RideEvent(
    type: type,
    time: ep.at!.time,
    lat: ep.at!.lat,
    lng: ep.at!.lng,
    value: double.parse(ep.peakG.toStringAsFixed(2)),
  );

  void _processLean(TrackPoint p) {
    final lean = p.leanDeg.isFinite ? p.leanDeg : 0.0;
    if (lean < 0 && -lean > _maxLeft) {
      _maxLeft = -lean;
      _maxLeftAt = p;
    } else if (lean > 0 && lean > _maxRight) {
      _maxRight = lean;
      _maxRightAt = p;
    }
    final abs = lean.abs();
    final sign = lean < 0 ? -1 : 1;
    if (_curveSign != 0) {
      if (abs < config.curveExitDeg || sign != _curveSign) {
        _closeCurve();
      } else {
        _curvePeak = math.max(_curvePeak, abs);
      }
    }
    if (_curveSign == 0 && abs >= config.curveEnterDeg) {
      _curveSign = sign;
      _curvePeak = abs;
    }
  }

  void _closeCurve() {
    if (_curveSign == 0) return;
    _curveCount++;
    _curvePeakSum += _curvePeak;
    _curveSign = 0;
    _curvePeak = 0;
  }

  void _processAltitude(TrackPoint p) {
    final alt = p.altitude;
    if (alt == null || !alt.isFinite) return;
    final s = _altSmooth;
    final prevT = _altTime;
    if (s == null || prevT == null) {
      _altSmooth = alt;
      _altRef = alt;
      _altTime = p.time;
      _maxAlt = math.max(_maxAlt ?? alt, alt);
      return;
    }
    final dt = p.time.difference(prevT).inMicroseconds / 1e6;
    if (dt <= 0) return;
    // Saut vertical aberrant.
    if ((alt - s).abs() > 40 + 15 * dt) return;
    final alpha = 1 - math.exp(-dt / config.altitudeSmoothingTauS);
    final next = dt > config.maxIntervalS ? alt : s + (alt - s) * alpha;
    _altSmooth = next;
    _altTime = p.time;
    _maxAlt = math.max(_maxAlt ?? next, next);
    final ref = _altRef ?? next;
    final h = config.elevationHysteresisM;
    if (next - ref >= h) {
      _gain += next - ref;
      _altRef = next;
    } else if (ref - next >= h) {
      _loss += ref - next;
      _altRef = next;
    }
  }

  /// Statistiques à l'instant (épisodes en cours inclus).
  RideStats get stats {
    final curves = curveCount;
    final peakSum = _curvePeakSum + (_curveSign != 0 ? _curvePeak : 0);
    final pendingAccel = _qualifies(_accel, config.hardAccelMinSpeedKmh) ? 1 : 0;
    return RideStats(
      distanceM: _distance,
      movingTimeS: _movingS.round(),
      totalTimeS: _totalS.round(),
      maxSpeedKmh: _maxSpeedKmh,
      maxLeanLeftDeg: _maxLeft,
      maxLeanRightDeg: _maxRight,
      avgLeanInCurvesDeg: curves == 0 ? 0 : peakSum / curves,
      hardBrakeCount: hardBrakeCount,
      hardAccelCount: _accelCount + pendingAccel,
      maxDecelG: math.max(0, _maxDecelG),
      maxAccelG: math.max(0, _maxAccelG),
      elevationGainM: _gain,
      elevationLossM: _loss,
      maxAltitudeM: _maxAlt,
      curveCount: curves,
      leanHistogram: _round(_leanHist),
      speedHistogram: _round(_speedHist),
    );
  }

  /// Évènements détectés (freinages, accélérations, angles max), triés par date.
  List<RideEvent> get events {
    final out = List<RideEvent>.of(_events);
    if (_qualifies(_brake, config.hardBrakeMinSpeedKmh)) out.add(_eventOf('hard_brake', _brake!));
    if (_qualifies(_accel, config.hardAccelMinSpeedKmh)) out.add(_eventOf('hard_accel', _accel!));
    for (final at in [_maxLeftAt, _maxRightAt]) {
      if (at == null) continue;
      out.add(
        RideEvent(
          type: 'max_lean',
          time: at.time,
          lat: at.lat,
          lng: at.lng,
          value: double.parse(at.leanDeg.toStringAsFixed(1)),
        ),
      );
    }
    out.sort((a, b) => a.time.compareTo(b.time));
    return out;
  }

  static Map<int, int> _round(Map<int, double> m) {
    final keys = m.keys.toList()..sort();
    return {
      for (final k in keys)
        if (m[k]!.round() > 0) k: m[k]!.round(),
    };
  }

  /// Calcul complet a posteriori (fin de balade, reprise après plantage).
  static RideStatsResult compute(
    List<TrackPoint> points, {
    RideStatsConfig config = const RideStatsConfig(),
    List<PauseWindow> pauses = const [],
  }) {
    final calc = RideStatsCalculator(config: config);
    final sorted = List<TrackPoint>.of(points)..sort((a, b) => a.time.compareTo(b.time));
    TrackPoint? prev;
    for (final p in sorted) {
      final pv = prev;
      if (pv != null && _pauseBetween(pauses, pv.time, p.time)) calc.breakSegment();
      if (_inPause(pauses, p.time)) continue;
      calc.add(p);
      prev = p;
    }
    return (stats: calc.stats, events: calc.events);
  }

  static bool _pauseBetween(List<PauseWindow> pauses, DateTime a, DateTime b) {
    for (final w in pauses) {
      if (!w.start.isBefore(a) && w.start.isBefore(b)) return true;
    }
    return false;
  }

  static bool _inPause(List<PauseWindow> pauses, DateTime t) {
    for (final w in pauses) {
      final end = w.end;
      // Un point pile au début de la pause appartient encore au segment d'avant.
      if (t.isAfter(w.start) && (end == null || t.isBefore(end))) return true;
    }
    return false;
  }

  /// Plages de pause à partir des évènements 'pause' (valeur = durée en s,
  /// 0 = pause non terminée).
  static List<PauseWindow> pausesFromEvents(Iterable<RideEvent> events) => [
    for (final e in events)
      if (e.type == 'pause')
        (start: e.time, end: e.value > 0 ? e.time.add(Duration(milliseconds: (e.value * 1000).round())) : null),
  ];
}

class _Episode {
  _Episode({required this.startSpeedMs});

  final double startSpeedMs;
  double durationS = 0;
  double peakG = 0;
  TrackPoint? at;
}
