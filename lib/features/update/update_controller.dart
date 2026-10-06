import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import '../../core/config.dart';
import '../../core/settings.dart';
import '../../services/update/app_update.dart';

/// Client des mises à jour (surchargeable dans les tests).
final updateClientProvider = Provider<UpdateClient>((ref) {
  final c = UpdateClient(baseUrl: AppConfig.updateBaseUrl);
  ref.onDispose(c.close);
  return c;
});

final apkInstallerProvider = Provider<ApkInstaller>((ref) {
  final i = ApkInstaller();
  ref.onDispose(i.dispose);
  return i;
});

/// Plateforme pour laquelle chercher une version (null : pas de mises à jour).
final updatePlatformProvider = Provider<UpdatePlatform?>((ref) => UpdatePlatform.current);

/// Numéro de build installé (null pour une version de développement).
final installedBuildProvider = Provider<int?>((ref) => int.tryParse(AppConfig.appBuild));

/// Dossier des téléchargements de mises à jour.
final updateDirectoryProvider = Provider<Future<Directory> Function()>(
  (ref) => () async => Directory('${(await getTemporaryDirectory()).path}/updates'),
);

enum UpdatePhase {
  idle,
  checking,
  upToDate,
  available,
  downloading,

  /// Réglage « Installer des applis inconnues » ouvert, on attend le retour.
  waitingPermission,

  /// Android installe ou attend la confirmation de l'utilisateur.
  installing,
  error,
}

@immutable
class AppUpdateState {
  const AppUpdateState({
    this.phase = UpdatePhase.idle,
    this.manifest,
    this.progress = 0,
    this.message = '',
    this.autoCheck = true,
  });

  final UpdatePhase phase;

  /// Dernière version trouvée plus récente que celle installée.
  final UpdateManifest? manifest;

  /// Avancement du téléchargement (0 à 1).
  final double progress;

  /// Message d'erreur ou d'information.
  final String message;

  /// Vérification automatique au démarrage.
  final bool autoCheck;

  bool get busy =>
      phase == UpdatePhase.checking || phase == UpdatePhase.downloading || phase == UpdatePhase.installing;

  AppUpdateState copyWith({
    UpdatePhase? phase,
    UpdateManifest? manifest,
    double? progress,
    String? message,
    bool? autoCheck,
  }) =>
      AppUpdateState(
        phase: phase ?? this.phase,
        manifest: manifest ?? this.manifest,
        progress: progress ?? this.progress,
        message: message ?? this.message,
        autoCheck: autoCheck ?? this.autoCheck,
      );
}

/// Mises à jour de l'appli : recherche, téléchargement et installation (Android),
/// simple annonce sur iPhone (l'installation passe par SideStore ou Sideloadly).
class AppUpdateController extends Notifier<AppUpdateState> {
  static const autoKey = 'update.auto';
  static const lastCheckKey = 'update.lastCheck';
  static const snoozedBuildKey = 'update.snoozedBuild';
  static const snoozedUntilKey = 'update.snoozedUntil';

  /// Vérification automatique au plus toutes les 6 h.
  static const checkEvery = Duration(hours: 6);

  /// « Plus tard » : on ne repropose pas la même version avant 24 h.
  static const snoozeFor = Duration(hours: 24);

  StreamSubscription<InstallEvent>? _installEvents;
  File? _downloaded;

  @override
  AppUpdateState build() {
    ref.onDispose(() => _installEvents?.cancel());
    return AppUpdateState(autoCheck: ref.read(sharedPreferencesProvider).getBool(autoKey) ?? true);
  }

  UpdateClient get _client => ref.read(updateClientProvider);

  Future<void> setAutoCheck(bool value) async {
    await ref.read(sharedPreferencesProvider).setBool(autoKey, value);
    state = state.copyWith(autoCheck: value);
  }

  /// Cherche une nouvelle version. En automatique ([manual] faux) : silencieux
  /// en cas d'erreur, et au plus une fois toutes les [checkEvery]. Retourne la
  /// version trouvée, ou null.
  Future<UpdateManifest?> check({bool manual = false, DateTime? now}) async {
    final platform = ref.read(updatePlatformProvider);
    final installed = ref.read(installedBuildProvider);
    if (platform == null || !_client.enabled) {
      if (manual) _fail('Les mises à jour automatiques ne sont pas configurées dans cette version.');
      return null;
    }
    if (installed == null) {
      if (manual) _fail('Version de développement : pas de mise à jour automatique.');
      return null;
    }
    if (state.busy || state.phase == UpdatePhase.waitingPermission) return state.manifest;

    final prefs = ref.read(sharedPreferencesProvider);
    final t = now ?? DateTime.now();
    if (!manual) {
      final last = prefs.getInt(lastCheckKey);
      if (last != null && t.difference(DateTime.fromMillisecondsSinceEpoch(last)) < checkEvery) {
        return state.phase == UpdatePhase.available ? state.manifest : null;
      }
    }

    state = state.copyWith(phase: UpdatePhase.checking, message: '');
    try {
      final latest = await _client.latest(platform);
      await prefs.setInt(lastCheckKey, t.millisecondsSinceEpoch);
      if (latest.isNewerThan(installed)) {
        state = state.copyWith(phase: UpdatePhase.available, manifest: latest, progress: 0);
        return latest;
      }
      state = AppUpdateState(phase: UpdatePhase.upToDate, autoCheck: state.autoCheck);
      return null;
    } on UpdateException catch (e) {
      state = manual
          ? AppUpdateState(phase: UpdatePhase.error, message: e.message, autoCheck: state.autoCheck)
          : AppUpdateState(autoCheck: state.autoCheck);
      return null;
    }
  }

  /// Faut-il proposer [manifest] tout seul ? Pas si « plus tard » a été choisi
  /// pour cette version il y a moins de [snoozeFor].
  bool shouldPrompt(UpdateManifest manifest, {DateTime? now}) {
    final prefs = ref.read(sharedPreferencesProvider);
    if (prefs.getInt(snoozedBuildKey) != manifest.build) return true;
    final until = prefs.getInt(snoozedUntilKey) ?? 0;
    return (now ?? DateTime.now()).millisecondsSinceEpoch >= until;
  }

  Future<void> snooze(UpdateManifest manifest, {DateTime? now}) async {
    final prefs = ref.read(sharedPreferencesProvider);
    await prefs.setInt(snoozedBuildKey, manifest.build);
    await prefs.setInt(snoozedUntilKey, (now ?? DateTime.now()).add(snoozeFor).millisecondsSinceEpoch);
  }

  /// Télécharge puis installe la version trouvée (Android).
  Future<void> downloadAndInstall() async {
    final manifest = state.manifest;
    if (manifest == null || manifest.platform != UpdatePlatform.android || state.busy) return;
    state = state.copyWith(phase: UpdatePhase.downloading, progress: 0, message: '');
    try {
      final dir = await ref.read(updateDirectoryProvider)();
      _downloaded = await _client.download(manifest, dir, onProgress: (p) {
        // Pas plus d'une mise à jour d'écran par pour-cent.
        if (p >= 1 || p - state.progress >= 0.01) state = state.copyWith(progress: p);
      });
      await _install();
    } on UpdateException catch (e) {
      _fail(e.message);
    } catch (e) {
      debugPrint('Mise à jour : $e');
      _fail('La mise à jour a échoué. Réessaie.');
    }
  }

  /// Retour dans l'appli : si on attendait l'autorisation d'installer, on reprend.
  Future<void> onResumed() async {
    if (state.phase == UpdatePhase.waitingPermission && _downloaded != null) {
      try {
        await _install();
      } on UpdateException catch (e) {
        _fail(e.message);
      }
    }
  }

  Future<void> openPermissionSettings() => ref.read(apkInstallerProvider).openPermissionSettings();

  Future<void> _install() async {
    final installer = ref.read(apkInstallerProvider);
    _installEvents ??= installer.events.listen(_onInstallEvent);
    switch (await installer.install(_downloaded!.path)) {
      case InstallStart.needsPermission:
        state = state.copyWith(phase: UpdatePhase.waitingPermission, progress: 1);
        await installer.openPermissionSettings();
      case InstallStart.started:
        state = state.copyWith(phase: UpdatePhase.installing, progress: 1);
      case InstallStart.unsupported:
        _fail('L\'installation automatique n\'est pas possible sur ce téléphone.');
    }
  }

  void _onInstallEvent(InstallEvent e) {
    switch (e.outcome) {
      case InstallOutcome.pending:
        if (state.phase != UpdatePhase.installing) state = state.copyWith(phase: UpdatePhase.installing);
      case InstallOutcome.success:
        state = AppUpdateState(phase: UpdatePhase.upToDate, autoCheck: state.autoCheck);
      case InstallOutcome.failure:
        _fail(e.message);
    }
  }

  /// Erreur : on garde la version trouvée pour pouvoir réessayer.
  void _fail(String message) => state = state.copyWith(phase: UpdatePhase.error, message: message);
}

final appUpdateProvider = NotifierProvider<AppUpdateController, AppUpdateState>(AppUpdateController.new);
