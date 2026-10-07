// Enregistrement d'une balade : GPS, capteurs, angle, stats live, chute, autonomie.
// Les champs et méthodes publics d'origine (RideSessionState, RideStatus,
// rideControllerProvider, start/pause/resume/stop) sont un contrat utilisé par
// les autres modules : ne pas les renommer ni changer leurs signatures.
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../app.dart';
import '../../core/geo.dart';
import '../../core/location.dart';
import '../../core/notifications.dart';
import '../../core/providers.dart';
import '../../core/settings.dart';
import '../../data/models/planned_route.dart';
import '../../data/models/ride.dart';
import '../../data/repositories.dart';
import '../../services/ride/crash_detector.dart';
import '../../services/ride/lean_angle.dart';
import '../../services/ride/ride_naming.dart';
import '../../services/ride/ride_platform.dart';
import '../../services/ride/ride_stats.dart';
import '../../services/ride/ride_store.dart';
import '../garage/autonomy.dart';
import '../garage/maintenance_reminders.dart';
import 'crash_alert_controller.dart';
import 'crash_alert_screen.dart';
import 'ride_display.dart';

enum RideStatus { idle, starting, recording, paused, finishing }

/// État de la balade en cours, observé par la carte, le HUD, l'autonomie…
@immutable
class RideSessionState {
  const RideSessionState({
    this.status = RideStatus.idle,
    this.rideId,
    this.startedAt,
    this.route,
    this.distanceM = 0,
    this.movingTime = Duration.zero,
    this.elapsed = Duration.zero,
    this.speedKmh = 0,
    this.maxSpeedKmh = 0,
    this.avgSpeedKmh = 0,
    this.leanDeg = 0,
    this.maxLeanLeftDeg = 0,
    this.maxLeanRightDeg = 0,
    this.hardBrakeCount = 0,
    this.longG = 0,
    this.maxAccelG = 0,
    this.maxDecelG = 0,
    this.altitudeM,
    this.track = const [],
    this.gpsAccuracyM,
    this.lastError,
    this.bikeId,
    this.bikeName,
    this.curveCount = 0,
    this.elevationGainM = 0,
    this.pausedAt,
    this.gpsLost = false,
    this.leanCalibrated = false,
    this.leanFromGyro = false,
    this.lowFuelAlert = false,
    this.crashDetectionArmed = false,
    this.smsAllowed = false,
    this.locationAccess,
    this.lastRideId,
  });

  final RideStatus status;
  final String? rideId;
  final DateTime? startedAt;

  /// Itinéraire suivi (null = balade libre).
  final PlannedRoute? route;
  final double distanceM;
  final Duration movingTime;
  final Duration elapsed;
  final double speedKmh;
  final double maxSpeedKmh;
  final double avgSpeedKmh;

  /// Inclinaison instantanée signée (négatif = gauche).
  final double leanDeg;
  final double maxLeanLeftDeg;
  final double maxLeanRightDeg;
  final int hardBrakeCount;

  /// Accélération longitudinale en G (positif = accélération, négatif =
  /// freinage), estimée d'après la vitesse GPS ; 0 à l'arrêt.
  final double longG;

  /// Plus forte accélération et plus fort freinage de la balade (G, positifs).
  final double maxAccelG;
  final double maxDecelG;

  /// Altitude GPS (null si inconnue).
  final double? altitudeM;

  /// Trace parcourue (simplifiée) pour l'affichage.
  final List<GeoPoint> track;
  final double? gpsAccuracyM;
  final String? lastError;

  // --- Ajouts du module Balade ---

  final String? bikeId;
  final String? bikeName;
  final int curveCount;
  final double elevationGainM;

  /// Début de la pause en cours.
  final DateTime? pausedAt;

  /// Pas de fix GPS depuis plus de 10 s.
  final bool gpsLost;

  /// L'axe de la moto est calibré (angle mesuré au gyroscope).
  final bool leanCalibrated;

  /// Angle calculé au gyroscope (sinon au cap GPS, moins précis).
  final bool leanFromGyro;

  /// Autonomie passée sous le seuil pendant la balade (bandeau du HUD).
  final bool lowFuelAlert;

  /// Détection de chute active pour cette balade.
  final bool crashDetectionArmed;

  /// Permission SMS accordée (envoi automatique au contact d'urgence).
  final bool smsAllowed;

  /// Résultat de la demande de localisation (après un échec de démarrage).
  final LocationAccess? locationAccess;

  /// Dernière balade enregistrée (après stop()).
  final String? lastRideId;

  bool get isActive => status == RideStatus.recording || status == RideStatus.paused || status == RideStatus.starting;

  bool get isPaused => status == RideStatus.paused;
  bool get isRecording => status == RideStatus.recording;
  bool get hasFix => gpsAccuracyM != null && !gpsLost;

  static const _keep = Object();

  RideSessionState copyWith({
    RideStatus? status,
    double? distanceM,
    Duration? movingTime,
    Duration? elapsed,
    double? speedKmh,
    double? maxSpeedKmh,
    double? avgSpeedKmh,
    double? leanDeg,
    double? maxLeanLeftDeg,
    double? maxLeanRightDeg,
    int? hardBrakeCount,
    double? longG,
    double? maxAccelG,
    double? maxDecelG,
    Object? altitudeM = _keep,
    List<GeoPoint>? track,
    Object? gpsAccuracyM = _keep,
    Object? lastError = _keep,
    int? curveCount,
    double? elevationGainM,
    Object? pausedAt = _keep,
    bool? gpsLost,
    bool? leanCalibrated,
    bool? leanFromGyro,
    bool? lowFuelAlert,
    bool? crashDetectionArmed,
    bool? smsAllowed,
  }) => RideSessionState(
    status: status ?? this.status,
    rideId: rideId,
    startedAt: startedAt,
    route: route,
    distanceM: distanceM ?? this.distanceM,
    movingTime: movingTime ?? this.movingTime,
    elapsed: elapsed ?? this.elapsed,
    speedKmh: speedKmh ?? this.speedKmh,
    maxSpeedKmh: maxSpeedKmh ?? this.maxSpeedKmh,
    avgSpeedKmh: avgSpeedKmh ?? this.avgSpeedKmh,
    leanDeg: leanDeg ?? this.leanDeg,
    maxLeanLeftDeg: maxLeanLeftDeg ?? this.maxLeanLeftDeg,
    maxLeanRightDeg: maxLeanRightDeg ?? this.maxLeanRightDeg,
    hardBrakeCount: hardBrakeCount ?? this.hardBrakeCount,
    longG: longG ?? this.longG,
    maxAccelG: maxAccelG ?? this.maxAccelG,
    maxDecelG: maxDecelG ?? this.maxDecelG,
    altitudeM: identical(altitudeM, _keep) ? this.altitudeM : altitudeM as double?,
    track: track ?? this.track,
    gpsAccuracyM: identical(gpsAccuracyM, _keep) ? this.gpsAccuracyM : gpsAccuracyM as double?,
    lastError: identical(lastError, _keep) ? this.lastError : lastError as String?,
    bikeId: bikeId,
    bikeName: bikeName,
    curveCount: curveCount ?? this.curveCount,
    elevationGainM: elevationGainM ?? this.elevationGainM,
    pausedAt: identical(pausedAt, _keep) ? this.pausedAt : pausedAt as DateTime?,
    gpsLost: gpsLost ?? this.gpsLost,
    leanCalibrated: leanCalibrated ?? this.leanCalibrated,
    leanFromGyro: leanFromGyro ?? this.leanFromGyro,
    lowFuelAlert: lowFuelAlert ?? this.lowFuelAlert,
    crashDetectionArmed: crashDetectionArmed ?? this.crashDetectionArmed,
    smsAllowed: smsAllowed ?? this.smsAllowed,
    locationAccess: locationAccess,
    lastRideId: lastRideId,
  );
}

/// Enregistreur de balade.
///
/// * `start()` : permissions, création de la balade en base, écoute du GPS et
///   des capteurs (≈ 50 Hz), angle d'inclinaison, stats live, détection de
///   chute, alerte autonomie.
/// * Les points sont écrits en base toutes les ~10 s : si l'appli est tuée, la
///   balade est reprise par [recoverUnfinished] (à appeler au démarrage).
/// * `stop()` : stats finales, aperçu, nom automatique, kilométrage de la moto,
///   rappels d'entretien.
class RideController extends Notifier<RideSessionState> {
  static const _fuelNotificationId = 4301;
  static const _maintenanceNotificationId = 4302;
  static const _crashNotificationId = 4304;

  /// En dessous, la balade est considérée comme vide.
  static const minRideDistanceM = 200.0;

  Ride? _ride;
  StreamSubscription<RiderPosition>? _gpsSub;
  StreamSubscription<SensorSample>? _gyroSub;
  StreamSubscription<SensorSample>? _accSub;
  RideDisplay? _display;
  bool? _gyroFast;
  bool? _accFast;
  Timer? _ticker;
  ProviderSubscription<AutonomyInfo?>? _autonomySub;

  LeanAngleEstimator _lean = LeanAngleEstimator();
  RideStatsCalculator _stats = RideStatsCalculator();
  CrashDetector _crash = CrashDetector();

  final List<TrackPoint> _pending = [];
  int _nextSeq = 0;
  Future<void> _writeChain = Future.value();
  final List<GeoPoint> _displayTrack = [];
  bool _trackDirty = false;
  final List<RideEvent> _sessionEvents = [];
  int? _openPauseEvent;

  RiderPosition? _lastPosition;
  DateTime? _lastFixAt;
  double? _peakLean;
  DateTime? _pauseStartedAt;
  Duration _pausedTotal = Duration.zero;
  int _tickCount = 0;
  DateTime? _lastFlushAt;
  bool _lowFuelAlerted = false;
  bool _crashAlertOpen = false;
  bool _crashDetectionOn = false;
  bool _routeSetByRide = false;

  @override
  RideSessionState build() {
    ref.onDispose(_disposeResources);
    return const RideSessionState();
  }

  RidePlatform get _platform => ref.read(ridePlatformProvider);
  RideRepository get _rides => ref.read(rideRepositoryProvider);
  GarageRepository get _garage => ref.read(garageRepositoryProvider);
  RideStore get _store => ref.read(rideStoreProvider);

  /// Démarre l'enregistrement. Retourne false si impossible (permission…).
  Future<bool> start({PlannedRoute? route}) async {
    if (state.status == RideStatus.recording || state.status == RideStatus.paused) return true;
    if (state.status != RideStatus.idle) return false;
    state = RideSessionState(status: RideStatus.starting, route: route, lastRideId: state.lastRideId);
    final platform = _platform;
    try {
      final access = await platform.ensureLocationPermission();
      if (!ref.mounted) return false;
      if (access != LocationAccess.granted) {
        state = RideSessionState(lastError: _accessMessage(access), locationAccess: access);
        return false;
      }
      await platform.requestNotificationPermission();
      final settings = ref.read(settingsProvider);
      var smsAllowed = false;
      if (settings.crashDetection && settings.hasEmergencyContact) {
        smsAllowed = await platform.requestSmsPermission();
      }

      // Une balade d'une session précédente (appli tuée) est finalisée d'abord.
      await _finalizeOrphans();

      final bike = await _garage.defaultBike();
      final followed = route ?? ref.read(activeRouteProvider);
      if (!ref.mounted) return false;
      if (followed != null && ref.read(activeRouteProvider)?.id != followed.id) {
        ref.read(activeRouteProvider.notifier).set(followed);
      }
      _routeSetByRide = followed != null;

      final now = platform.now().toUtc();
      final ride = Ride(
        id: const Uuid().v4(),
        name: 'Balade en cours',
        startedAt: now,
        bikeId: bike?.id,
        routeId: followed?.id,
      );
      await _rides.upsert(ride);
      if (!ref.mounted) return false;

      _resetSession(settings);
      _ride = ride;
      _crashDetectionOn = settings.crashDetection;
      state = RideSessionState(
        status: RideStatus.recording,
        rideId: ride.id,
        startedAt: now,
        route: followed,
        bikeId: bike?.id,
        bikeName: bike?.name,
        crashDetectionArmed: settings.crashDetection,
        smsAllowed: smsAllowed,
      );

      _gpsSub = platform.positions().listen(
        _onPosition,
        onError: (Object e) {
          if (ref.mounted && _ride != null) {
            state = state.copyWith(lastError: 'GPS indisponible : vérifie que la localisation est activée.');
          }
        },
      );
      final display = ref.read(rideDisplayProvider);
      _display = display;
      display.addListener(_applySensorRates);
      _applySensorRates();
      _ticker = Timer.periodic(const Duration(milliseconds: 100), (_) => _onTick());
      _listenAutonomy();
      if (settings.keepScreenOn) unawaited(platform.keepScreenOn(true));
      return true;
    } catch (e, st) {
      debugPrint('Démarrage de la balade impossible : $e\n$st');
      await _stopStreams();
      _ride = null;
      if (ref.mounted) {
        state = const RideSessionState(lastError: 'Impossible de démarrer l\'enregistrement. Réessaie.');
      }
      return false;
    }
  }

  void pause() {
    if (state.status != RideStatus.recording || _ride == null) return;
    final now = _platform.now().toUtc();
    _pauseStartedAt = now;
    _stats.breakSegment();
    _crash.reset();
    _peakLean = null;
    final at = _lastPosition?.point;
    _openPauseEvent = _sessionEvents.length;
    _sessionEvents.add(RideEvent(type: 'pause', time: now, lat: at?.lat ?? 0, lng: at?.lng ?? 0));
    _flush();
    _persistProgress();
    state = state.copyWith(status: RideStatus.paused, pausedAt: now, leanDeg: 0);
  }

  void resume() {
    if (state.status != RideStatus.paused || _ride == null) return;
    _closePause(_platform.now().toUtc());
    _persistProgress();
    state = state.copyWith(status: RideStatus.recording, pausedAt: null, elapsed: _elapsed());
  }

  /// Termine la balade ; retourne la balade enregistrée (null si annulée/vide).
  Future<Ride?> stop({bool save = true}) async {
    final ride = _ride;
    if (ride == null || state.status == RideStatus.finishing) return null;
    final now = _platform.now().toUtc();
    _closePause(now);
    state = state.copyWith(status: RideStatus.finishing);
    await _stopStreams();
    Ride? saved;
    try {
      _flush();
      await _writeChain;
      if (!save) {
        await _rides.delete(ride.id);
      } else {
        saved = await _finalize(
          ride.copyWith(events: List.of(_sessionEvents)),
          endedAt: now,
          routeName: state.route?.name,
        );
      }
    } catch (e, st) {
      debugPrint('Fin de balade : $e\n$st');
    }
    await _afterStop(saved?.id);
    return saved;
  }

  /// Finalise une balade restée ouverte (appli tuée pendant l'enregistrement)
  /// à partir de ses points stockés. À appeler au démarrage de l'appli.
  /// Retourne la balade récupérée (null s'il n'y en avait pas, ou si elle
  /// était vide et a été supprimée).
  Future<Ride?> recoverUnfinished() async {
    if (_ride != null || state.status != RideStatus.idle) return null;
    return _finalizeOrphans();
  }

  /// Masque le bandeau « réserve » du HUD.
  void dismissLowFuelAlert() {
    if (state.lowFuelAlert) state = state.copyWith(lowFuelAlert: false);
  }

  /// Le GPS a-t-il assez roulé pour que la balade mérite d'être gardée ?
  bool get isWorthSaving => state.distanceM >= minRideDistanceM;

  /// Position du dernier fix (avec l'angle).
  RiderPosition? get lastPosition => _lastPosition;

  /// Écrit tout de suite les points en attente (tests).
  @visibleForTesting
  Future<void> debugFlush() {
    _flush();
    return _writeChain;
  }

  // ---------------------------------------------------------------------------
  // Flux
  // ---------------------------------------------------------------------------

  void _onPosition(RiderPosition pos) {
    if (_ride == null || !ref.mounted) return;
    final now = _platform.now();
    _lean.addGps(now, pos.speedMs, headingDeg: pos.heading, position: pos.point);
    final lean = state.isPaused ? 0.0 : _lean.leanAt(now);
    final published = pos.withLean(lean);
    _lastPosition = published;
    _lastFixAt = now;
    ref.read(positionHubProvider.notifier).publish(published);

    final goodFix = pos.accuracyM == null || pos.accuracyM! <= 30;
    if (state.status != RideStatus.recording) {
      state = state.copyWith(
        speedKmh: goodFix ? pos.speedKmh : 0,
        longG: 0,
        altitudeM: pos.altitude ?? state.altitudeM,
        gpsAccuracyM: pos.accuracyM ?? 0,
        gpsLost: false,
        lastError: null,
      );
      return;
    }

    if (_crashDetectionOn && _crash.onSpeed(now, pos.speedMs)) _onCrashSuspected();

    final peak = _takePeakLean(lean);
    final point = TrackPoint(
      time: pos.time,
      lat: pos.point.lat,
      lng: pos.point.lng,
      altitude: pos.altitude,
      speedMs: pos.speedMs,
      heading: pos.heading,
      accuracyM: pos.accuracyM,
      leanDeg: double.parse(peak.toStringAsFixed(1)),
      longAccelMs2: double.parse(_lean.speedSlopeMs2.toStringAsFixed(2)),
    );
    _pending.add(point);
    _stats.add(point);
    if (goodFix) _addDisplayPoint(pos.point);

    final s = _stats.stats;
    state = state.copyWith(
      distanceM: s.distanceM,
      movingTime: Duration(seconds: s.movingTimeS),
      elapsed: _elapsed(),
      speedKmh: goodFix ? pos.speedKmh : 0,
      maxSpeedKmh: s.maxSpeedKmh,
      avgSpeedKmh: s.avgMovingSpeedKmh,
      leanDeg: lean,
      maxLeanLeftDeg: s.maxLeanLeftDeg,
      maxLeanRightDeg: s.maxLeanRightDeg,
      hardBrakeCount: s.hardBrakeCount,
      // Sous 10 km/h la pente de vitesse GPS n'est que du bruit.
      longG: goodFix && pos.speedKmh >= 10 ? _lean.speedSlopeMs2 / Geo.g : 0,
      maxAccelG: s.maxAccelG,
      maxDecelG: s.maxDecelG,
      altitudeM: pos.altitude ?? state.altitudeM,
      curveCount: s.curveCount,
      elevationGainM: s.elevationGainM,
      track: _takeTrack(),
      gpsAccuracyM: pos.accuracyM ?? 0,
      gpsLost: false,
      lastError: null,
      leanCalibrated: _lean.calibrated,
      leanFromGyro: _lean.source == LeanSource.gyroscope,
    );
  }

  /// Fréquence des capteurs (batterie) : le gyroscope ne sert qu'à l'angle,
  /// ≈ 50 Hz s'il est à l'écran, ≈ 15 Hz sinon (écran éteint, appli en
  /// arrière-plan, écran de balade réduit) : l'angle reste enregistré pour
  /// l'historique, avec trois fois moins de réveils. L'accéléromètre garde
  /// 50 Hz tant que la détection de chute est active (pics de choc).
  void _applySensorRates() {
    if (_ride == null || !ref.mounted) return;
    final shown = _display?.leanVisible ?? true;
    final gyroFast = shown;
    final accFast = shown || _crashDetectionOn;
    if (gyroFast != _gyroFast) {
      _gyroFast = gyroFast;
      unawaited(_gyroSub?.cancel());
      _gyroSub = _platform.gyroscope(fast: gyroFast).listen(
        _onGyro,
        onError: (Object e) => debugPrint('Gyroscope indisponible : $e'),
        cancelOnError: true,
      );
    }
    if (accFast != _accFast) {
      _accFast = accFast;
      unawaited(_accSub?.cancel());
      _accSub = _platform.accelerometer(fast: accFast).listen(
        _onAccel,
        onError: (Object e) => debugPrint('Accéléromètre indisponible : $e'),
        cancelOnError: true,
      );
    }
  }

  void _onGyro(SensorSample s) {
    if (_ride == null) return;
    _lean.addGyroscope(s.time, s.x, s.y, s.z);
    if (state.status == RideStatus.recording) _trackPeak(_lean.leanDeg);
  }

  void _onAccel(SensorSample s) {
    if (_ride == null) return;
    _lean.addAccelerometer(s.time, s.x, s.y, s.z);
    if (_crashDetectionOn && state.status == RideStatus.recording && _crash.onAccelerometer(s.time, s.x, s.y, s.z)) {
      _onCrashSuspected();
    }
  }

  void _onTick() {
    if (_ride == null || !ref.mounted) return;
    final st = state.status;
    if (st != RideStatus.recording && st != RideStatus.paused) return;
    _tickCount++;
    final now = _platform.now();
    final lean = st == RideStatus.recording ? _lean.leanAt(now) : 0.0;
    final everySecond = _tickCount % 10 == 0;

    if (!everySecond) {
      // Au plus 10 redessins par seconde (ce minuteur), et pas pour les
      // tremblements de moins d'un demi-degré.
      if ((lean - state.leanDeg).abs() >= 0.5) state = state.copyWith(leanDeg: lean);
      return;
    }

    final settings = ref.read(settingsProvider);
    _crashDetectionOn = settings.crashDetection;
    _applySensorRates();
    if (_crashDetectionOn && st == RideStatus.recording && _crash.tick(now)) _onCrashSuspected();

    final lastFix = _lastFixAt;
    // Sans aucun fix depuis le départ, le HUD affiche « Recherche GPS ».
    final gpsLost = lastFix != null && now.difference(lastFix).inSeconds >= 10;
    state = state.copyWith(
      leanDeg: lean,
      elapsed: _elapsed(),
      gpsLost: gpsLost,
      speedKmh: gpsLost ? 0 : null,
      leanCalibrated: _lean.calibrated,
      leanFromGyro: _lean.source == LeanSource.gyroscope && _lean.gyroActiveAt(now),
      crashDetectionArmed: _crashDetectionOn,
    );

    final lastFlush = _lastFlushAt;
    if (lastFlush == null || now.difference(lastFlush).inSeconds >= 10) _flush();
  }

  // ---------------------------------------------------------------------------
  // Angle
  // ---------------------------------------------------------------------------

  void _trackPeak(double lean) {
    final p = _peakLean;
    if (p == null || lean.abs() > p.abs()) _peakLean = lean;
  }

  /// Angle le plus marqué depuis le fix précédent (pour ne pas rater le pic
  /// d'un virage entre deux points à 1 Hz).
  double _takePeakLean(double current) {
    _trackPeak(current);
    final p = _peakLean ?? current;
    _peakLean = null;
    return p;
  }

  // ---------------------------------------------------------------------------
  // Trace affichée
  // ---------------------------------------------------------------------------

  void _addDisplayPoint(GeoPoint p) {
    final last = _displayTrack.isEmpty ? null : _displayTrack.last;
    if (last != null && Geo.distance(last, p) < 12) return;
    _displayTrack.add(p);
    _trackDirty = true;
    if (_displayTrack.length > 1500) {
      var tol = 6.0;
      var simplified = Geo.simplify(_displayTrack, tol);
      while (simplified.length > 1000 && tol < 400) {
        tol *= 2;
        simplified = Geo.simplify(_displayTrack, tol);
      }
      _displayTrack
        ..clear()
        ..addAll(simplified);
    }
  }

  List<GeoPoint> _takeTrack() {
    if (!_trackDirty) return state.track;
    _trackDirty = false;
    return List.unmodifiable(_displayTrack);
  }

  // ---------------------------------------------------------------------------
  // Persistance
  // ---------------------------------------------------------------------------

  /// Écrit les points en attente (dans l'ordre, sans bloquer l'appelant).
  void _flush() {
    final ride = _ride;
    _lastFlushAt = _platform.now();
    if (ride == null || _pending.isEmpty) return;
    final batch = List<TrackPoint>.of(_pending);
    _pending.clear();
    final first = _nextSeq;
    _nextSeq += batch.length;
    final repo = _rides;
    _writeChain = _writeChain.then((_) async {
      try {
        await repo.appendPoints(ride.id, first, batch);
      } catch (e) {
        debugPrint('Écriture des points : $e');
      }
    });
  }

  /// Sauvegarde les évènements (pauses, chute) de la balade en cours, pour
  /// pouvoir la reconstituer si l'appli est tuée.
  void _persistProgress() {
    final ride = _ride;
    if (ride == null) return;
    final snapshot = ride.copyWith(events: List.of(_sessionEvents), stats: _stats.stats);
    final store = _store;
    _writeChain = _writeChain.then((_) async {
      try {
        await store.save(snapshot);
      } catch (e) {
        debugPrint('Sauvegarde de la balade en cours : $e');
      }
    });
  }

  void _closePause(DateTime now) {
    final start = _pauseStartedAt;
    if (start == null) return;
    final d = now.difference(start);
    _pausedTotal += d;
    _pauseStartedAt = null;
    final idx = _openPauseEvent;
    _openPauseEvent = null;
    if (idx != null && idx < _sessionEvents.length) {
      final e = _sessionEvents[idx];
      _sessionEvents[idx] = RideEvent(
        type: e.type,
        time: e.time,
        lat: e.lat,
        lng: e.lng,
        value: d.inMilliseconds <= 0 ? 0.001 : d.inMilliseconds / 1000,
      );
    }
  }

  Duration _elapsed() {
    final start = state.startedAt;
    if (start == null) return Duration.zero;
    final now = _platform.now().toUtc();
    var paused = _pausedTotal;
    final p = _pauseStartedAt;
    if (p != null) paused += now.difference(p);
    final e = now.difference(start) - paused;
    return e.isNegative ? Duration.zero : e;
  }

  /// Calcule et enregistre la version finale d'une balade à partir de ses
  /// points stockés.
  Future<Ride?> _finalize(Ride ride, {DateTime? endedAt, String? routeName}) async {
    final points = await _rides.points(ride.id);
    final settings = ref.read(settingsProvider);
    final config = RideStatsConfig(hardBrakeThresholdG: settings.hardBrakeThresholdG);
    final result = RideStatsCalculator.compute(
      points,
      config: config,
      pauses: RideStatsCalculator.pausesFromEvents(ride.events),
    );
    final stats = result.stats;

    final kept = [
      for (final p in points)
        if (p.accuracyM == null || p.accuracyM! <= config.maxAccuracyM) p.point,
    ];
    final preview = kept.length >= 2 ? Geo.encodePolyline(Geo.simplify(kept, 15)) : '';

    var name = routeName;
    if (name == null && ride.routeId != null) {
      try {
        name = (await ref.read(routeRepositoryProvider).get(ride.routeId!))?.name;
      } catch (_) {}
    }
    final events = [
      ...result.events,
      for (final e in ride.events)
        if (e.type != 'hard_brake' && e.type != 'hard_accel' && e.type != 'max_lean') e,
    ]..sort((a, b) => a.time.compareTo(b.time));

    final end = endedAt ?? (points.isNotEmpty ? points.last.time : ride.startedAt);
    final finalRide = ride.copyWith(
      name: autoRideName(ride.startedAt, distanceKm: stats.distanceKm, routeName: name),
      endedAt: end.isBefore(ride.startedAt) ? ride.startedAt : end,
      stats: stats,
      events: events,
      previewPolyline: preview,
    );
    await _store.save(finalRide);

    final bikeId = ride.bikeId;
    if (bikeId != null && stats.distanceKm > 0.01) {
      try {
        await _garage.addDistance(bikeId, double.parse(stats.distanceKm.toStringAsFixed(2)));
        await _maintenanceCheck(bikeId);
      } catch (e) {
        debugPrint('Mise à jour du garage : $e');
      }
    }
    return finalRide;
  }

  Future<void> _maintenanceCheck(String bikeId) async {
    final bike = await _garage.bike(bikeId);
    if (bike == null) return;
    final messages = await dueMaintenanceMessages(_garage, bike);
    if (messages.isEmpty) return;
    await _platform.notify(
      id: _maintenanceNotificationId,
      title: 'Entretien à prévoir · ${bike.name}',
      body: messages.join('\n'),
      channel: CmChannel.garage,
    );
  }

  Future<Ride?> _finalizeOrphans() async {
    Ride? first;
    for (var i = 0; i < 5; i++) {
      final Ride? orphan;
      try {
        orphan = await _rides.unfinished();
      } catch (e) {
        debugPrint('Recherche de balade non terminée : $e');
        break;
      }
      if (orphan == null || orphan.id == _ride?.id) break;
      try {
        final count = await _rides.pointCount(orphan.id);
        final recovered = count < 2 ? null : await _finalize(orphan);
        if (recovered == null || recovered.stats.distanceM < minRideDistanceM) {
          await _rides.delete(orphan.id);
          continue;
        }
        first ??= recovered;
      } catch (e) {
        debugPrint('Reprise de la balade ${orphan.id} : $e');
        await _rides.delete(orphan.id);
      }
    }
    return first;
  }

  // ---------------------------------------------------------------------------
  // Chute
  // ---------------------------------------------------------------------------

  void _onCrashSuspected() {
    if (_crashAlertOpen || _ride == null) return;
    _crashAlertOpen = true;
    final now = _platform.now().toUtc();
    final pos = _lastPosition;
    _sessionEvents.add(
      RideEvent(
        type: 'crash',
        time: now,
        lat: pos?.point.lat ?? 0,
        lng: pos?.point.lng ?? 0,
        value: double.parse(_crash.impactG.toStringAsFixed(1)),
      ),
    );
    _persistProgress();
    unawaited(
      _platform.notify(
        id: _crashNotificationId,
        title: 'Chute détectée ?',
        body: 'Ouvre Cono Moto et touche « Je vais bien », sinon tes proches seront prévenus dans 1 minute.',
        channel: CmChannel.safety,
      ),
    );
    ref
        .read(crashAlertProvider.notifier)
        .trigger(at: pos?.point, accuracyM: pos?.accuracyM, onClosed: _onCrashAlertClosed);
    final nav = rootNavigatorKey.currentState;
    if (nav != null) nav.push(CrashAlertScreen.route());
  }

  void _onCrashAlertClosed() {
    _crashAlertOpen = false;
    _crash.reset();
    unawaited(_platform.cancelNotification(_crashNotificationId));
  }

  // ---------------------------------------------------------------------------
  // Autonomie
  // ---------------------------------------------------------------------------

  void _listenAutonomy() {
    try {
      // container.listen : autonomyProvider peut lui-même dépendre de la balade
      // en cours, un ref.listen créerait une dépendance circulaire.
      _autonomySub = ref.container.listen<AutonomyInfo?>(
        autonomyProvider,
        (_, next) => Future.microtask(() => _onAutonomy(next)),
        fireImmediately: true,
        onError: (e, _) => debugPrint('Autonomie : $e'),
      );
    } catch (e) {
      debugPrint('Autonomie indisponible : $e');
    }
  }

  void _onAutonomy(AutonomyInfo? info) {
    if (info == null || _ride == null || !ref.mounted || !state.isActive) return;
    if (!info.low) {
      _lowFuelAlerted = false;
      if (state.lowFuelAlert) state = state.copyWith(lowFuelAlert: false);
      return;
    }
    if (_lowFuelAlerted) return;
    _lowFuelAlerted = true;
    state = state.copyWith(lowFuelAlert: true);
    final km = info.remainingKm.round();
    unawaited(
      _platform.notify(
        id: _fuelNotificationId,
        title: 'Pense à faire le plein',
        body: 'Il te reste environ $km km d\'autonomie. Touche « Essence » dans le compteur pour trouver une station.',
      ),
    );
    if (ref.read(settingsProvider).voiceGuidance) {
      unawaited(_platform.speak('Attention, il te reste environ $km kilomètres d\'autonomie. Pense à faire le plein.'));
    }
  }

  // ---------------------------------------------------------------------------
  // Cycle de vie
  // ---------------------------------------------------------------------------

  void _resetSession(AppSettings settings) {
    _lean = LeanAngleEstimator();
    _stats = RideStatsCalculator(config: RideStatsConfig(hardBrakeThresholdG: settings.hardBrakeThresholdG));
    _crash = CrashDetector();
    _pending.clear();
    _nextSeq = 0;
    _writeChain = Future.value();
    _displayTrack.clear();
    _trackDirty = false;
    _sessionEvents.clear();
    _openPauseEvent = null;
    _lastPosition = null;
    _lastFixAt = null;
    _peakLean = null;
    _pauseStartedAt = null;
    _pausedTotal = Duration.zero;
    _tickCount = 0;
    _lastFlushAt = null;
    _lowFuelAlerted = false;
    _crashAlertOpen = false;
  }

  Future<void> _stopStreams() async {
    _ticker?.cancel();
    _ticker = null;
    _display?.removeListener(_applySensorRates);
    _display = null;
    _gyroFast = _accFast = null;
    _autonomySub?.close();
    _autonomySub = null;
    final subs = [_gpsSub, _gyroSub, _accSub];
    _gpsSub = null;
    _gyroSub = null;
    _accSub = null;
    for (final s in subs) {
      try {
        await s?.cancel();
      } catch (_) {}
    }
  }

  Future<void> _afterStop(String? savedId) async {
    _ride = null;
    _pending.clear();
    _displayTrack.clear();
    _sessionEvents.clear();
    try {
      await _platform.keepScreenOn(false);
    } catch (_) {}
    if (!ref.mounted) return;
    if (_routeSetByRide) ref.read(activeRouteProvider.notifier).clear();
    _routeSetByRide = false;
    state = RideSessionState(lastRideId: savedId);
  }

  void _disposeResources() {
    _ticker?.cancel();
    _display?.removeListener(_applySensorRates);
    _autonomySub?.close();
    _gpsSub?.cancel();
    _gyroSub?.cancel();
    _accSub?.cancel();
  }

  static String _accessMessage(LocationAccess access) => switch (access) {
    LocationAccess.serviceDisabled => 'Active la localisation du téléphone pour enregistrer ta balade.',
    LocationAccess.deniedForever =>
      'La localisation est bloquée pour Cono Moto. Autorise-la dans les réglages du téléphone.',
    LocationAccess.denied => 'Sans accès à ta position, impossible d\'enregistrer la balade.',
    LocationAccess.granted => '',
  };
}

final rideControllerProvider = NotifierProvider<RideController, RideSessionState>(RideController.new);
