import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import '../../core/config.dart';
import '../../core/settings.dart';
import '../../services/update/app_update.dart';
import '../ride/ride_controller.dart';

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

/// Balade en cours ? Comme la proposition de mise à jour (home_shell.dart),
/// le téléchargement en arrière-plan attend la fin de la balade.
final updateRideActiveProvider = Provider<bool>(
  (ref) => ref.watch(rideControllerProvider.select((s) => s.isActive)),
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
    this.wifiDownload = true,
    this.downloaded = false,
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

  /// Téléchargement en arrière-plan en Wi-Fi (Android).
  final bool wifiDownload;

  /// Le fichier de [manifest] est déjà téléchargé : l'installation démarre
  /// tout de suite.
  final bool downloaded;

  bool get busy =>
      phase == UpdatePhase.checking || phase == UpdatePhase.downloading || phase == UpdatePhase.installing;

  AppUpdateState copyWith({
    UpdatePhase? phase,
    UpdateManifest? manifest,
    double? progress,
    String? message,
    bool? autoCheck,
    bool? wifiDownload,
    bool? downloaded,
  }) =>
      AppUpdateState(
        phase: phase ?? this.phase,
        manifest: manifest ?? this.manifest,
        progress: progress ?? this.progress,
        message: message ?? this.message,
        autoCheck: autoCheck ?? this.autoCheck,
        wifiDownload: wifiDownload ?? this.wifiDownload,
        downloaded: downloaded ?? this.downloaded,
      );
}

/// Mises à jour de l'appli : recherche, téléchargement et installation (Android),
/// simple annonce sur iPhone (l'installation passe par SideStore ou Sideloadly).
class AppUpdateController extends Notifier<AppUpdateState> {
  static const autoKey = 'update.auto';
  static const wifiKey = 'update.wifiDownload';
  static const lastCheckKey = 'update.lastCheck';
  static const snoozedBuildKey = 'update.snoozedBuild';
  static const snoozedUntilKey = 'update.snoozedUntil';
  static const preDownloadBuildKey = 'update.preDownloadBuild';
  static const preDownloadAtKey = 'update.preDownloadAt';

  /// Vérification automatique au plus toutes les 6 h.
  static const checkEvery = Duration(hours: 6);

  /// « Plus tard » : on ne repropose pas la même version avant 24 h.
  static const snoozeFor = Duration(hours: 24);

  /// Téléchargement en Wi-Fi : au plus un essai par version et par jour.
  static const preDownloadEvery = Duration(hours: 24);

  StreamSubscription<InstallEvent>? _installEvents;
  File? _downloaded;

  /// Téléchargement en cours (au premier plan ou en arrière-plan) et son
  /// fichier : « Mettre à jour » pendant un téléchargement en Wi-Fi le reprend.
  Future<File>? _fetching;
  String? _fetchingName;

  @override
  AppUpdateState build() {
    ref.onDispose(() => _installEvents?.cancel());
    final prefs = ref.read(sharedPreferencesProvider);
    return AppUpdateState(
      autoCheck: prefs.getBool(autoKey) ?? true,
      wifiDownload: prefs.getBool(wifiKey) ?? true,
    );
  }

  UpdateClient get _client => ref.read(updateClientProvider);

  /// État remis à zéro (sans version trouvée), réglages gardés.
  AppUpdateState _reset(UpdatePhase phase, [String message = '']) => AppUpdateState(
        phase: phase,
        message: message,
        autoCheck: state.autoCheck,
        wifiDownload: state.wifiDownload,
      );

  Future<void> setAutoCheck(bool value) async {
    await ref.read(sharedPreferencesProvider).setBool(autoKey, value);
    state = state.copyWith(autoCheck: value);
  }

  Future<void> setWifiDownload(bool value) async {
    await ref.read(sharedPreferencesProvider).setBool(wifiKey, value);
    state = state.copyWith(wifiDownload: value);
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
        final found = await _forThisPhone(latest);
        final ready = await _isDownloaded(found);
        state = state.copyWith(phase: UpdatePhase.available, manifest: found, progress: 0, downloaded: ready);
        return found;
      }
      state = _reset(UpdatePhase.upToDate);
      return null;
    } on UpdateException catch (e) {
      state = manual ? _reset(UpdatePhase.error, e.message) : _reset(UpdatePhase.idle);
      return null;
    }
  }

  /// Sur Android, l'APK de l'architecture du téléphone (`files`), sinon `file`.
  Future<UpdateManifest> _forThisPhone(UpdateManifest m) async {
    if (m.platform != UpdatePlatform.android || m.files.isEmpty) return m;
    return m.forAbis(await ref.read(apkInstallerProvider).supportedAbis());
  }

  /// Déjà téléchargée (en Wi-Fi, ou avant un « Plus tard ») ?
  Future<bool> _isDownloaded(UpdateManifest m) async {
    if (m.platform != UpdatePlatform.android) return false;
    try {
      return _client.downloaded(m, await ref.read(updateDirectoryProvider)()) != null;
    } on Exception catch (e) {
      debugPrint('Mise à jour : $e');
      return false;
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

  /// Après une vérification automatique, en Wi-Fi : télécharge en douce la
  /// version trouvée (Android), pour que « Mettre à jour » l'installe en
  /// quelques secondes. Jamais pendant une balade ni sur les données mobiles,
  /// au plus un essai par version et par jour ; en cas d'échec, le fichier
  /// partiel est supprimé et « Mettre à jour » retéléchargera. Retourne vrai
  /// si le fichier est prêt.
  Future<bool> preDownload({DateTime? now}) async {
    final manifest = state.manifest;
    if (manifest == null || manifest.platform != UpdatePlatform.android) return false;
    if (state.downloaded) return true;
    if (!_canPreDownload(manifest)) return false;

    final prefs = ref.read(sharedPreferencesProvider);
    final t = now ?? DateTime.now();
    final last = prefs.getInt(preDownloadAtKey);
    if (prefs.getInt(preDownloadBuildKey) == manifest.build &&
        last != null &&
        t.difference(DateTime.fromMillisecondsSinceEpoch(last)) < preDownloadEvery) {
      return false;
    }
    if (!await ref.read(apkInstallerProvider).isNetworkUnmetered()) return false;
    // La situation a pu changer pendant la question à Android.
    if (!ref.mounted || !_canPreDownload(manifest)) return false;

    await prefs.setInt(preDownloadBuildKey, manifest.build);
    await prefs.setInt(preDownloadAtKey, t.millisecondsSinceEpoch);
    try {
      await _fetch(manifest, keepGoing: () => _keepPreDownloading(manifest));
      return true;
    } catch (e) {
      debugPrint('Mise à jour en arrière-plan : $e');
      return false;
    }
  }

  bool _canPreDownload(UpdateManifest manifest) =>
      state.phase == UpdatePhase.available &&
      _fetching == null &&
      _keepPreDownloading(manifest);

  /// Le téléchargement en arrière-plan de [manifest] continue tant que c'est
  /// la version proposée, que le réglage est actif et qu'aucune balade n'a
  /// commencé ; ou si « Mettre à jour » l'a repris au premier plan.
  bool _keepPreDownloading(UpdateManifest manifest) {
    if (!ref.mounted) return false;
    final current = state.manifest;
    if (current == null || current.build != manifest.build || current.file != manifest.file) return false;
    if (state.phase == UpdatePhase.downloading) return true;
    return state.autoCheck && state.wifiDownload && !ref.read(updateRideActiveProvider);
  }

  /// Télécharge [manifest] (ou reprend le téléchargement en cours du même
  /// fichier). Un fichier déjà complet est réutilisé sans retéléchargement.
  Future<File> _fetch(UpdateManifest manifest, {bool Function()? keepGoing}) {
    final name = '${manifest.build}-${manifest.file}';
    final previous = _fetching;
    if (previous != null && _fetchingName == name) return previous;
    final future = () async {
      // Un autre fichier en cours (version plus ancienne) : il s'arrête de
      // lui-même, on attend qu'il libère le dossier.
      if (previous != null) {
        try {
          await previous;
        } catch (_) {}
      }
      final file = await _client.download(
        manifest,
        await ref.read(updateDirectoryProvider)(),
        onProgress: _onProgress,
        keepGoing: keepGoing,
      );
      final current = ref.mounted ? state.manifest : null;
      if (current != null && current.build == manifest.build && current.file == manifest.file) {
        state = state.copyWith(downloaded: true);
      }
      return file;
    }();
    _fetching = future;
    _fetchingName = name;
    return future.whenComplete(() {
      if (identical(_fetching, future)) {
        _fetching = null;
        _fetchingName = null;
      }
    });
  }

  /// Avancement à l'écran, seulement au premier plan, et pas plus d'une mise
  /// à jour d'écran par pour-cent.
  void _onProgress(double p) {
    if (!ref.mounted || state.phase != UpdatePhase.downloading) return;
    if (p >= 1 || p - state.progress >= 0.01) state = state.copyWith(progress: p);
  }

  /// Télécharge (si ce n'est pas déjà fait) puis installe la version trouvée
  /// (Android).
  Future<void> downloadAndInstall() async {
    final manifest = state.manifest;
    if (manifest == null || manifest.platform != UpdatePlatform.android || state.busy) return;
    state = state.copyWith(phase: UpdatePhase.downloading, progress: state.downloaded ? 1 : 0, message: '');
    try {
      _downloaded = await _fetch(manifest);
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
        state = _reset(UpdatePhase.upToDate);
      case InstallOutcome.failure:
        _fail(e.message);
    }
  }

  /// Erreur : on garde la version trouvée pour pouvoir réessayer.
  void _fail(String message) => state = state.copyWith(phase: UpdatePhase.error, message: message);
}

final appUpdateProvider = NotifierProvider<AppUpdateController, AppUpdateState>(AppUpdateController.new);
