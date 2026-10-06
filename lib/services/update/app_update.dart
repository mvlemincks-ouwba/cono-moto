import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

/// Plateforme d'une version publiée.
enum UpdatePlatform {
  android('android.json'),
  ios('ios.json');

  const UpdatePlatform(this.manifestName);

  /// Nom du fichier de description dans la release publique.
  final String manifestName;

  /// Plateforme du téléphone (null ailleurs : tests desktop, web…).
  static UpdatePlatform? get current => switch (defaultTargetPlatform) {
        TargetPlatform.android => UpdatePlatform.android,
        TargetPlatform.iOS => UpdatePlatform.ios,
        _ => null,
      };
}

/// APK d'une architecture de processeur (`files` d'android.json).
@immutable
class UpdateFile {
  const UpdateFile(this.name, {this.size = 0});

  final String name;

  /// Taille en octets (0 si inconnue).
  final int size;
}

/// Une version publiée, décrite par `android.json` / `ios.json` dans la release
/// « derniere-version » du dépôt (généré par tool/release/make_manifest.py).
@immutable
class UpdateManifest {
  const UpdateManifest({
    required this.platform,
    required this.version,
    required this.build,
    required this.file,
    this.size = 0,
    this.files = const {},
    this.notes = const [],
    this.date,
    this.commit = '',
  });

  factory UpdateManifest.fromJson(Map<String, dynamic> json) {
    final platform = UpdatePlatform.values.firstWhere(
      (p) => p.name == json['platform'],
      orElse: () => throw const FormatException('plateforme inconnue'),
    );
    final build = json['build'];
    if (build is! int || build <= 0) throw const FormatException('build ou fichier invalide');
    final perAbi = json['files'] ?? const {};
    if (perAbi is! Map) throw const FormatException('fichiers par architecture invalides');
    return UpdateManifest(
      platform: platform,
      version: (json['version'] as String?) ?? '',
      build: build,
      file: _fileName(json['file']),
      size: (json['size'] as num?)?.toInt() ?? 0,
      files: {
        for (final MapEntry(:key, :value) in perAbi.entries)
          key as String: switch (value) {
            Map() => UpdateFile(_fileName(value['file']), size: (value['size'] as num?)?.toInt() ?? 0),
            _ => throw const FormatException('fichiers par architecture invalides'),
          },
      },
      notes: [for (final n in (json['notes'] as List?) ?? const []) if (n is String && n.trim().isNotEmpty) n.trim()],
      date: DateTime.tryParse((json['date'] as String?) ?? ''),
      commit: (json['commit'] as String?) ?? '',
    );
  }

  /// Nom d'un fichier publié : jamais de chemin (il est enregistré tel quel
  /// dans le dossier des téléchargements).
  static String _fileName(Object? name) {
    if (name is! String || name.isEmpty || name.contains('/')) {
      throw const FormatException('build ou fichier invalide');
    }
    return name;
  }

  final UpdatePlatform platform;
  final String version;

  /// Numéro de build (numéro du run GitHub Actions) : il ne fait qu'augmenter.
  final int build;

  /// Nom du fichier à télécharger (APK ou IPA), à côté du manifeste. Sur
  /// Android, l'APK arm64 : celui des téléphones qui ne lisent pas [files].
  final String file;

  /// Taille en octets (0 si inconnue).
  final int size;

  /// APK par architecture (« arm64-v8a », « armeabi-v7a »), vide pour iPhone
  /// et pour les descriptions d'avant (build 54 et moins).
  final Map<String, UpdateFile> files;

  /// Quoi de neuf (titres des changements depuis la version précédente).
  final List<String> notes;
  final DateTime? date;
  final String commit;

  /// Plus récente que la version installée ? Jamais pour une version de
  /// développement (numéro de build inconnu).
  bool isNewerThan(int? installedBuild) => installedBuild != null && build > installedBuild;

  /// La même version, avec le fichier à télécharger sur un téléphone qui
  /// accepte [abis] (de la préférée à la moins bonne, Build.SUPPORTED_ABIS) :
  /// l'APK de la première architecture publiée dans [files], sinon [file].
  UpdateManifest forAbis(List<String> abis) {
    for (final abi in abis) {
      final f = files[abi];
      if (f == null) continue;
      return UpdateManifest(
        platform: platform,
        version: version,
        build: build,
        file: f.name,
        size: f.size,
        files: files,
        notes: notes,
        date: date,
        commit: commit,
      );
    }
    return this;
  }

  String get label => version.isEmpty ? 'build $build' : 'v$version (build $build)';

  /// « 48 Mo » (vide si la taille est inconnue).
  String get sizeLabel => size <= 0 ? '' : '${(size / (1024 * 1024)).toStringAsFixed(size < 10 * 1024 * 1024 ? 1 : 0)} Mo';
}

/// Erreur lisible par l'utilisateur.
class UpdateException implements Exception {
  const UpdateException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Récupère la description de la dernière version et télécharge son fichier.
class UpdateClient {
  UpdateClient({
    required String baseUrl,
    http.Client? client,
    this.timeout = const Duration(seconds: 15),
  })  : baseUrl = baseUrl.trim().replaceAll(RegExp(r'/+$'), ''),
        _client = client ?? http.Client(),
        _ownsClient = client == null;

  /// Ex. https://github.com/moi/cono-moto/releases/download/derniere-version
  final String baseUrl;
  final Duration timeout;
  final http.Client _client;
  final bool _ownsClient;

  bool get enabled => baseUrl.isNotEmpty;

  Uri fileUri(String name) => Uri.parse('$baseUrl/$name');

  /// Page de la release (fichiers et mode d'emploi pour iPhone), si c'est GitHub.
  Uri? get pageUri {
    final uri = Uri.tryParse(baseUrl);
    if (uri == null || uri.host != 'github.com') return null;
    final s = uri.pathSegments;
    if (s.length != 5 || s[2] != 'releases' || s[3] != 'download') return null;
    return Uri.https('github.com', '/${s[0]}/${s[1]}/releases/tag/${s[4]}');
  }

  /// Dernière version publiée pour [platform].
  Future<UpdateManifest> latest(UpdatePlatform platform) async {
    if (!enabled) throw const UpdateException('Les mises à jour ne sont pas configurées dans cette version.');
    final http.Response response;
    try {
      response = await _client.get(fileUri(platform.manifestName)).timeout(timeout);
    } on TimeoutException {
      throw const UpdateException('Le serveur des mises à jour ne répond pas. Réessaie plus tard.');
    } on SocketException {
      throw const UpdateException('Pas de connexion internet.');
    } on http.ClientException {
      throw const UpdateException('Pas de connexion internet.');
    }
    if (response.statusCode == 404) throw const UpdateException('Aucune version publiée pour l\'instant.');
    if (response.statusCode != 200) {
      throw UpdateException('Serveur des mises à jour indisponible (${response.statusCode}).');
    }
    try {
      return UpdateManifest.fromJson(jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>);
    } catch (_) {
      throw const UpdateException('La description de la nouvelle version est illisible.');
    }
  }

  File _target(UpdateManifest manifest, Directory dir) => File('${dir.path}/${manifest.build}-${manifest.file}');

  /// Fichier de [manifest] déjà téléchargé en entier dans [dir] (taille
  /// vérifiée), sinon null.
  File? downloaded(UpdateManifest manifest, Directory dir) {
    final target = _target(manifest, dir);
    if (manifest.size > 0 && target.existsSync() && target.lengthSync() == manifest.size) return target;
    return null;
  }

  /// Télécharge le fichier de [manifest] dans [dir]. Si un téléchargement
  /// complet de la même version existe déjà, il est réutilisé ; les anciennes
  /// versions sont supprimées. [keepGoing] est consulté à chaque morceau reçu :
  /// s'il répond faux, le téléchargement s'arrête. En cas d'échec, le fichier
  /// partiel est supprimé.
  Future<File> download(
    UpdateManifest manifest,
    Directory dir, {
    void Function(double progress)? onProgress,
    bool Function()? keepGoing,
  }) async {
    await dir.create(recursive: true);
    final target = _target(manifest, dir);
    final ready = downloaded(manifest, dir);
    if (ready != null) {
      onProgress?.call(1);
      return ready;
    }
    await for (final old in dir.list()) {
      if (old is File) await old.delete();
    }

    final http.StreamedResponse response;
    try {
      response = await _client.send(http.Request('GET', fileUri(manifest.file))).timeout(timeout);
    } on TimeoutException {
      throw const UpdateException('Le serveur des mises à jour ne répond pas. Réessaie plus tard.');
    } on SocketException {
      throw const UpdateException('Pas de connexion internet.');
    } on http.ClientException {
      throw const UpdateException('Pas de connexion internet.');
    }
    if (response.statusCode != 200) {
      throw UpdateException('Téléchargement impossible (${response.statusCode}).');
    }

    final total = manifest.size > 0 ? manifest.size : (response.contentLength ?? 0);
    final part = File('${target.path}.part');
    final sink = part.openWrite();
    var received = 0;
    var stopped = false;
    try {
      await for (final chunk in response.stream.timeout(const Duration(seconds: 30))) {
        if (keepGoing != null && !keepGoing()) {
          stopped = true;
          break;
        }
        sink.add(chunk);
        received += chunk.length;
        if (total > 0) onProgress?.call((received / total).clamp(0.0, 1.0));
      }
      await sink.close();
    } catch (_) {
      await _discard(sink, part);
      throw const UpdateException('Téléchargement interrompu. Vérifie ta connexion et réessaie.');
    }
    if (stopped) {
      await _discard(sink, part);
      throw const UpdateException('Téléchargement arrêté.');
    }
    if (manifest.size > 0 && received != manifest.size) {
      await _discard(sink, part);
      throw const UpdateException('Le fichier téléchargé est incomplet. Réessaie.');
    }
    return part.rename(target.path);
  }

  /// Supprime un téléchargement partiel, même si l'écriture a échoué.
  Future<void> _discard(IOSink sink, File part) async {
    try {
      await sink.close();
    } catch (_) {}
    try {
      if (await part.exists()) await part.delete();
    } on FileSystemException catch (e) {
      debugPrint('Fichier partiel non supprimé : $e');
    }
  }

  void close() {
    if (_ownsClient) _client.close();
  }
}

/// Résultat du lancement de l'installation (Android).
enum InstallStart {
  /// Android installe (ou demande confirmation à l'utilisateur).
  started,

  /// Il faut d'abord autoriser Cono Moto à installer des applis.
  needsPermission,

  /// Pas disponible sur ce téléphone (iPhone, tests…).
  unsupported,
}

/// Avancement de l'installation, remonté par Android.
enum InstallOutcome { pending, success, failure }

@immutable
class InstallEvent {
  const InstallEvent(this.outcome, [this.message = '']);

  final InstallOutcome outcome;
  final String message;
}

/// Installe un APK téléchargé (canal « fr.conomoto/updater », voir
/// MainActivity.kt). Android demande une confirmation la première fois ; les
/// mises à jour suivantes peuvent passer sans (Android 12 et plus). Le même
/// canal donne l'architecture du téléphone et le type de connexion.
class ApkInstaller {
  ApkInstaller({MethodChannel? channel}) : _channel = channel ?? const MethodChannel('fr.conomoto/updater');

  final MethodChannel _channel;
  final _events = StreamController<InstallEvent>.broadcast();
  bool _listening = false;
  List<String>? _abis;

  Stream<InstallEvent> get events => _events.stream;

  /// Architectures acceptées par le téléphone, de la préférée à la moins
  /// bonne (Build.SUPPORTED_ABIS) ; vide si on ne sait pas.
  Future<List<String>> supportedAbis() async {
    if (_abis case final abis?) return abis;
    try {
      return _abis = await _channel.invokeListMethod<String>('supportedAbis') ?? const [];
    } on MissingPluginException {
      return const [];
    } on PlatformException {
      return const [];
    }
  }

  /// Connexion sans compteur (Wi-Fi, Ethernet) ? Dans le doute, non : rien ne
  /// se télécharge en arrière-plan sur les données mobiles.
  Future<bool> isNetworkUnmetered() async {
    try {
      return await _channel.invokeMethod<bool>('isNetworkUnmetered') ?? false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  Future<InstallStart> install(String path) async {
    if (!_listening) {
      _listening = true;
      _channel.setMethodCallHandler(_onCall);
    }
    try {
      final r = await _channel.invokeMethod<String>('installApk', {'path': path});
      return r == 'permission' ? InstallStart.needsPermission : InstallStart.started;
    } on MissingPluginException {
      return InstallStart.unsupported;
    } on PlatformException catch (e) {
      throw UpdateException('L\'installation n\'a pas pu démarrer${e.message == null ? '' : ' : ${e.message}'}.');
    }
  }

  /// Ouvre le réglage « Installer des applis inconnues » de Cono Moto.
  Future<void> openPermissionSettings() async {
    try {
      await _channel.invokeMethod<void>('openInstallSettings');
    } catch (e) {
      debugPrint('Réglage des installations inaccessible : $e');
    }
  }

  Future<dynamic> _onCall(MethodCall call) async {
    if (call.method != 'installStatus') return null;
    final args = Map<String, dynamic>.from(call.arguments as Map? ?? const {});
    switch (args['status']) {
      case 'pending':
        _events.add(const InstallEvent(InstallOutcome.pending));
      case 'success':
        _events.add(const InstallEvent(InstallOutcome.success));
      default:
        _events.add(InstallEvent(InstallOutcome.failure, installFailureMessage(args['code'] as int?)));
    }
    return null;
  }

  void dispose() {
    if (_listening) _channel.setMethodCallHandler(null);
    _events.close();
  }
}

/// Message pour un code d'échec de PackageInstaller.
@visibleForTesting
String installFailureMessage(int? code) => switch (code) {
      2 => 'Installation bloquée par le téléphone.',
      3 => 'Installation annulée.',
      4 => 'Le fichier de mise à jour est invalide. Réessaie.',
      5 => 'Cette version ne peut pas remplacer celle installée (signature différente). '
          'Désinstalle Cono Moto puis installe la nouvelle version à la main.',
      6 => 'Pas assez de place sur le téléphone.',
      7 => 'Cette version n\'est pas compatible avec ton téléphone.',
      _ => 'L\'installation a échoué. Réessaie.',
    };
