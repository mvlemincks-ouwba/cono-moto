import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../data/models/garage.dart';
import 'config.dart';

/// Styles de carte disponibles (OpenFreeMap, gratuits et sans clé).
enum MapStyle {
  auto('Auto (jour / nuit)', ''),
  liberty('Liberty (jour)', 'https://tiles.openfreemap.org/styles/liberty'),
  bright('Bright', 'https://tiles.openfreemap.org/styles/bright'),
  positron('Positron (épuré)', 'https://tiles.openfreemap.org/styles/positron'),
  dark('Dark (nuit)', 'https://tiles.openfreemap.org/styles/dark'),
  fiord('Fiord (nuit bleutée)', 'https://tiles.openfreemap.org/styles/fiord');

  const MapStyle(this.label, this.url);

  final String label;
  final String url;

  /// URL à utiliser selon la luminosité courante.
  String resolve(Brightness brightness) {
    if (this != MapStyle.auto) return url;
    return brightness == Brightness.dark ? MapStyle.dark.url : MapStyle.liberty.url;
  }

  static MapStyle fromName(String? n) =>
      MapStyle.values.firstWhere((s) => s.name == n, orElse: () => MapStyle.auto);
}

/// Réglages utilisateur persistés localement.
@immutable
class AppSettings {
  const AppSettings({
    this.themeMode = ThemeMode.dark,
    this.mapStyle = MapStyle.auto,
    this.fuelType = FuelType.sp98,
    this.tomtomApiKey = '',
    this.showTraffic = true,
    this.showFriends = true,
    this.showReports = true,
    this.showStations = false,
    this.voiceGuidance = true,
    this.keepScreenOn = true,
    this.crashDetection = true,
    this.emergencyName = '',
    this.emergencyPhone = '',
    this.autonomyAlertKm = 40,
    this.stragglerAlertKm = 3,
    this.shareLiveWithFriends = true,
    this.hardBrakeThresholdG = 0.45,
    this.onboardingDone = false,
    this.rideMapFirst = true,
    this.mapHighContrast = true,
    this.crashReports = true,
  });

  final ThemeMode themeMode;
  final MapStyle mapStyle;

  /// Carburant mis dans la moto (filtre et tri des stations).
  final FuelType fuelType;

  /// Clé TomTom saisie par l'utilisateur (prioritaire sur celle du build).
  final String tomtomApiKey;
  final bool showTraffic;
  final bool showFriends;
  final bool showReports;
  final bool showStations;
  final bool voiceGuidance;
  final bool keepScreenOn;

  /// Détection de chute activée pendant les balades.
  final bool crashDetection;
  final String emergencyName;
  final String emergencyPhone;

  /// Seuil d'alerte autonomie (km restants).
  final int autonomyAlertKm;

  /// Distance au-delà de laquelle un pote du groupe est considéré « décroché ».
  final double stragglerAlertKm;

  /// Partager automatiquement sa position avec ses potes pendant une balade.
  final bool shareLiveWithFriends;

  /// Seuil de décélération (en g) pour compter un freinage fort.
  final double hardBrakeThresholdG;
  final bool onboardingDone;

  /// Pendant une balade, ouvrir d'abord le plan de navigation (façon GPS)
  /// plutôt que le compteur. Le compteur reste accessible d'un geste.
  final bool rideMapFirst;

  /// Carte sombre : rues plus claires et plus larges, noms plus lisibles
  /// (repérage des intersections en navigation de nuit).
  final bool mapHighContrast;

  /// Envoyer un rapport sur le Discord quand l'appli plante (sans donnée perso).
  final bool crashReports;

  /// Clé TomTom effective.
  String get effectiveTomtomKey =>
      tomtomApiKey.trim().isNotEmpty ? tomtomApiKey.trim() : AppConfig.tomtomApiKey;

  bool get hasEmergencyContact => emergencyPhone.trim().isNotEmpty;

  AppSettings copyWith({
    ThemeMode? themeMode,
    MapStyle? mapStyle,
    FuelType? fuelType,
    String? tomtomApiKey,
    bool? showTraffic,
    bool? showFriends,
    bool? showReports,
    bool? showStations,
    bool? voiceGuidance,
    bool? keepScreenOn,
    bool? crashDetection,
    String? emergencyName,
    String? emergencyPhone,
    int? autonomyAlertKm,
    double? stragglerAlertKm,
    bool? shareLiveWithFriends,
    double? hardBrakeThresholdG,
    bool? onboardingDone,
    bool? rideMapFirst,
    bool? mapHighContrast,
    bool? crashReports,
  }) =>
      AppSettings(
        themeMode: themeMode ?? this.themeMode,
        mapStyle: mapStyle ?? this.mapStyle,
        fuelType: fuelType ?? this.fuelType,
        tomtomApiKey: tomtomApiKey ?? this.tomtomApiKey,
        showTraffic: showTraffic ?? this.showTraffic,
        showFriends: showFriends ?? this.showFriends,
        showReports: showReports ?? this.showReports,
        showStations: showStations ?? this.showStations,
        voiceGuidance: voiceGuidance ?? this.voiceGuidance,
        keepScreenOn: keepScreenOn ?? this.keepScreenOn,
        crashDetection: crashDetection ?? this.crashDetection,
        emergencyName: emergencyName ?? this.emergencyName,
        emergencyPhone: emergencyPhone ?? this.emergencyPhone,
        autonomyAlertKm: autonomyAlertKm ?? this.autonomyAlertKm,
        stragglerAlertKm: stragglerAlertKm ?? this.stragglerAlertKm,
        shareLiveWithFriends: shareLiveWithFriends ?? this.shareLiveWithFriends,
        hardBrakeThresholdG: hardBrakeThresholdG ?? this.hardBrakeThresholdG,
        onboardingDone: onboardingDone ?? this.onboardingDone,
        rideMapFirst: rideMapFirst ?? this.rideMapFirst,
        mapHighContrast: mapHighContrast ?? this.mapHighContrast,
        crashReports: crashReports ?? this.crashReports,
      );

  Map<String, Object> toPrefs() => {
        'themeMode': themeMode.name,
        'mapStyle': mapStyle.name,
        'fuelType': fuelType.name,
        'tomtomApiKey': tomtomApiKey,
        'showTraffic': showTraffic,
        'showFriends': showFriends,
        'showReports': showReports,
        'showStations': showStations,
        'voiceGuidance': voiceGuidance,
        'keepScreenOn': keepScreenOn,
        'crashDetection': crashDetection,
        'emergencyName': emergencyName,
        'emergencyPhone': emergencyPhone,
        'autonomyAlertKm': autonomyAlertKm,
        'stragglerAlertKm': stragglerAlertKm,
        'shareLiveWithFriends': shareLiveWithFriends,
        'hardBrakeThresholdG': hardBrakeThresholdG,
        'onboardingDone': onboardingDone,
        'rideMapFirst': rideMapFirst,
        'mapHighContrast': mapHighContrast,
        'crashReports': crashReports,
      };

  factory AppSettings.fromPrefs(SharedPreferences p) {
    const d = AppSettings();
    String? s(String k) => p.getString('settings.$k');
    bool b(String k, bool def) => p.getBool('settings.$k') ?? def;
    return AppSettings(
      themeMode: ThemeMode.values.firstWhere((m) => m.name == s('themeMode'),
          orElse: () => d.themeMode),
      mapStyle: MapStyle.fromName(s('mapStyle')),
      fuelType: FuelType.fromName(s('fuelType')),
      tomtomApiKey: s('tomtomApiKey') ?? '',
      showTraffic: b('showTraffic', d.showTraffic),
      showFriends: b('showFriends', d.showFriends),
      showReports: b('showReports', d.showReports),
      showStations: b('showStations', d.showStations),
      voiceGuidance: b('voiceGuidance', d.voiceGuidance),
      keepScreenOn: b('keepScreenOn', d.keepScreenOn),
      crashDetection: b('crashDetection', d.crashDetection),
      emergencyName: s('emergencyName') ?? '',
      emergencyPhone: s('emergencyPhone') ?? '',
      autonomyAlertKm: p.getInt('settings.autonomyAlertKm') ?? d.autonomyAlertKm,
      stragglerAlertKm: p.getDouble('settings.stragglerAlertKm') ?? d.stragglerAlertKm,
      shareLiveWithFriends: b('shareLiveWithFriends', d.shareLiveWithFriends),
      hardBrakeThresholdG: p.getDouble('settings.hardBrakeThresholdG') ?? d.hardBrakeThresholdG,
      onboardingDone: b('onboardingDone', d.onboardingDone),
      rideMapFirst: b('rideMapFirst', d.rideMapFirst),
      mapHighContrast: b('mapHighContrast', d.mapHighContrast),
      crashReports: b('crashReports', d.crashReports),
    );
  }
}

/// Instance SharedPreferences, injectée au démarrage (voir main.dart).
final sharedPreferencesProvider = Provider<SharedPreferences>(
  (ref) => throw UnimplementedError('sharedPreferencesProvider doit être surchargé dans main()'),
);

class SettingsNotifier extends Notifier<AppSettings> {
  @override
  AppSettings build() => AppSettings.fromPrefs(ref.watch(sharedPreferencesProvider));

  Future<void> update(AppSettings Function(AppSettings s) change) async {
    final next = change(state);
    state = next;
    final prefs = ref.read(sharedPreferencesProvider);
    for (final e in next.toPrefs().entries) {
      final key = 'settings.${e.key}';
      final v = e.value;
      if (v is bool) {
        await prefs.setBool(key, v);
      } else if (v is int) {
        await prefs.setInt(key, v);
      } else if (v is double) {
        await prefs.setDouble(key, v);
      } else {
        await prefs.setString(key, '$v');
      }
    }
  }
}

final settingsProvider = NotifierProvider<SettingsNotifier, AppSettings>(SettingsNotifier.new);
