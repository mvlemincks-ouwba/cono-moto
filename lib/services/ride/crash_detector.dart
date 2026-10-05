import 'dart:math' as math;

import '../../core/geo.dart';

/// Étapes de la détection de chute.
enum CrashPhase {
  /// Surveillance normale.
  monitoring,

  /// Choc violent détecté en roulant : on attend de voir si la moto s'arrête.
  impact,

  /// Choc puis quasi-immobilité : on compte les secondes.
  immobile,

  /// Chute suspectée : l'alerte doit être déclenchée (jusqu'à [CrashDetector.reset]).
  suspected,
}

/// Seuils de la détection de chute.
class CrashDetectorConfig {
  const CrashDetectorConfig({
    this.shockThresholdG = 4,
    this.minShockSamples = 2,
    this.shockWindow = const Duration(milliseconds: 150),
    this.minSpeedBeforeKmh = 20,
    this.speedLookback = const Duration(seconds: 3),
    this.stillSpeedKmh = 3,
    this.stillDuration = const Duration(seconds: 15),
    this.maxTimeToStop = const Duration(seconds: 12),
    this.resumeSpeedKmh = 10,
    this.resumeGrace = const Duration(seconds: 4),
    this.gpsLostAfter = const Duration(seconds: 4),
  });

  /// Norme de l'accélération (gravité incluse) considérée comme un choc.
  final double shockThresholdG;

  /// Nombre d'échantillons au-dessus du seuil dans [shockWindow] (filtre les
  /// pics isolés dus aux vibrations du guidon).
  final int minShockSamples;
  final Duration shockWindow;

  /// Il faut avoir roulé au-dessus de cette vitesse dans les [speedLookback]
  /// précédant le choc (évite le téléphone qui tombe à l'arrêt, la béquille…).
  final double minSpeedBeforeKmh;
  final Duration speedLookback;

  /// Quasi-immobilité : vitesse sous ce seuil pendant [stillDuration].
  final double stillSpeedKmh;
  final Duration stillDuration;

  /// La moto doit s'être arrêtée dans ce délai après le choc, sinon c'était un
  /// nid-de-poule.
  final Duration maxTimeToStop;

  /// Si on roule de nouveau au-dessus de cette vitesse après [resumeGrace],
  /// le motard a continué sa route : on annule.
  final double resumeSpeedKmh;
  final Duration resumeGrace;

  /// Sans fix GPS depuis ce délai, on considère la moto immobile (le téléphone
  /// peut avoir perdu le signal sous la moto ou dans le fossé).
  final Duration gpsLostAfter;
}

/// Machine à états pure de détection de chute.
///
/// Séquence : **choc** (|a| > 4 g sur au moins 2 échantillons rapprochés)
/// alors que la vitesse a dépassé 20 km/h dans les 3 s précédentes, puis
/// **arrêt** dans les 12 s, puis **quasi-immobilité** (< 3 km/h) pendant 15 s
/// → chute suspectée.
///
/// Faux positifs évités :
/// * nid-de-poule, dos-d'âne : choc mais la moto continue (vitesse > 10 km/h
///   après 4 s, ou pas d'arrêt dans les 12 s) ;
/// * téléphone qui tombe, moto sur la béquille, parking : vitesse faible avant
///   le choc ;
/// * vibrations : un pic isolé ne suffit pas.
///
/// Une lecture GPS isolée au-dessus de 3 km/h (bruit à l'arrêt) n'interrompt
/// pas le décompte ; deux lectures consécutives, si.
class CrashDetector {
  CrashDetector({this.config = const CrashDetectorConfig()});

  final CrashDetectorConfig config;

  CrashPhase _phase = CrashPhase.monitoring;
  final List<({DateTime t, double kmh})> _speeds = [];
  final List<DateTime> _shocks = [];
  DateTime? _lastFix;
  DateTime? _impactAt;
  double _impactG = 0;
  double _speedBeforeKmh = 0;
  DateTime? _stillSince;
  int _aboveStillCount = 0;

  CrashPhase get phase => _phase;
  DateTime? get impactAt => _impactAt;

  /// Intensité du choc (g).
  double get impactG => _impactG;

  /// Vitesse max dans les secondes précédant le choc (km/h).
  double get speedBeforeKmh => _speedBeforeKmh;

  bool get suspected => _phase == CrashPhase.suspected;

  /// Retour à la surveillance (après « Je vais bien » ou une pause).
  void reset() {
    _phase = CrashPhase.monitoring;
    _shocks.clear();
    _impactAt = null;
    _impactG = 0;
    _speedBeforeKmh = 0;
    _stillSince = null;
    _aboveStillCount = 0;
  }

  /// Échantillon d'accéléromètre (m/s², gravité incluse).
  /// Retourne true si la chute vient d'être suspectée.
  bool onAccelerometer(DateTime t, double x, double y, double z) {
    if (_phase == CrashPhase.suspected) return false;
    final g = math.sqrt(x * x + y * y + z * z) / Geo.g;
    if (g >= config.shockThresholdG) {
      _shocks.add(t);
      _shocks.removeWhere((s) => t.difference(s) > config.shockWindow);
      if (_shocks.length >= config.minShockSamples) _onShock(t, g);
    }
    return _evaluate(t);
  }

  /// Nouvelle vitesse GPS. Retourne true si la chute vient d'être suspectée.
  bool onSpeed(DateTime t, double speedMs) {
    final kmh = (speedMs.isFinite ? math.max(0.0, speedMs) : 0.0) * 3.6;
    _speeds.add((t: t, kmh: kmh));
    _speeds.removeWhere((s) => t.difference(s.t) > const Duration(seconds: 10));
    _lastFix = t;
    if (_phase == CrashPhase.monitoring || _phase == CrashPhase.suspected) return false;
    final impact = _impactAt!;
    if (!t.isAfter(impact)) return false;

    if (kmh >= config.stillSpeedKmh) {
      _aboveStillCount++;
    } else {
      _aboveStillCount = 0;
    }
    final sinceImpact = t.difference(impact);
    if (kmh >= config.resumeSpeedKmh && sinceImpact >= config.resumeGrace) {
      reset();
      return false;
    }
    if (kmh < config.stillSpeedKmh) {
      if (_phase == CrashPhase.impact) {
        _phase = CrashPhase.immobile;
        _stillSince = t;
      }
    } else if (_aboveStillCount >= 2 && _phase == CrashPhase.immobile) {
      _phase = CrashPhase.impact;
      _stillSince = null;
    }
    return _evaluate(t);
  }

  /// À appeler régulièrement (≈ 1 Hz) : gère les délais sans nouvelle donnée.
  bool tick(DateTime now) => _evaluate(now);

  void _onShock(DateTime t, double g) {
    final from = t.subtract(config.speedLookback);
    var before = 0.0;
    for (final s in _speeds) {
      if (!s.t.isBefore(from) && !s.t.isAfter(t)) before = math.max(before, s.kmh);
    }
    if (_phase == CrashPhase.monitoring) {
      if (before < config.minSpeedBeforeKmh) return;
      _phase = CrashPhase.impact;
      _impactAt = t;
      _impactG = g;
      _speedBeforeKmh = before;
      _stillSince = null;
      _aboveStillCount = 0;
    } else {
      // Nouveaux chocs (la moto glisse, rebondit) : on garde le premier impact.
      _impactG = math.max(_impactG, g);
    }
  }

  bool _evaluate(DateTime now) {
    if (_phase == CrashPhase.monitoring || _phase == CrashPhase.suspected) return false;
    final impact = _impactAt!;

    // GPS perdu après le choc : on considère la moto immobile.
    final lastFix = _lastFix;
    final gpsLost =
        lastFix == null ||
        (now.difference(lastFix) >= config.gpsLostAfter && now.difference(impact) >= config.gpsLostAfter);
    if (gpsLost && _phase == CrashPhase.impact) {
      _phase = CrashPhase.immobile;
      final since = lastFix != null && lastFix.isAfter(impact) ? lastFix : impact;
      _stillSince = since;
    }

    if (_phase == CrashPhase.impact) {
      if (now.difference(impact) > config.maxTimeToStop) reset();
      return false;
    }
    final still = _stillSince;
    if (_phase == CrashPhase.immobile && still != null && now.difference(still) >= config.stillDuration) {
      _phase = CrashPhase.suspected;
      return true;
    }
    return false;
  }
}
