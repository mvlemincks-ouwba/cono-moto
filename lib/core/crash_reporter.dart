import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/feedback/crash_report.dart';
import '../services/feedback/discord_feedback.dart';
import 'settings.dart';

/// Rapports de plantage automatiques : chaque erreur non rattrapée part sur le
/// Discord de la bande (même webhook que la boîte à idées), seulement dans les
/// versions publiées (jamais en debug ni dans les tests) et si le réglage est
/// activé. Anti-spam : une même erreur au plus une fois par semaine, 3 rapports
/// par jour au maximum. Sans réseau, jusqu'à 3 rapports attendent le prochain
/// démarrage.
class CrashReporter {
  CrashReporter({
    required SharedPreferences prefs,
    DiscordFeedbackClient? client,
    bool? active,
    bool Function()? isEnabled,
    DateTime Function()? clock,
    FeedbackContext Function()? appContext,
    String? Function()? currentScreen,
  }) : _prefs = prefs,
       _client = client ?? DiscordFeedbackClient(),
       active = active ?? (kReleaseMode && !_runningTests),
       _isEnabled = isEnabled ?? (() => AppSettings.fromPrefs(prefs).crashReports),
       _clock = clock ?? DateTime.now,
       _appContext = appContext ?? FeedbackContext.current,
       _currentScreen = currentScreen ?? crashScreenObserver.currentScreen;

  static const seenKey = 'crash.seen';
  static const sentKey = 'crash.sent';
  static const pendingKey = 'crash.pending';

  /// Une même erreur n'est envoyée qu'une fois par semaine…
  static const sameErrorEvery = Duration(days: 7);

  /// … et pas plus de 3 rapports par jour.
  static const maxPerDay = 3;
  static const _day = Duration(days: 1);

  /// Rapports gardés quand l'envoi échoue, renvoyés au démarrage suivant.
  static const maxPending = 3;

  /// Au-delà, un rapport en attente n'est plus envoyé.
  static const keepPendingFor = Duration(days: 7);

  final SharedPreferences _prefs;
  final DiscordFeedbackClient _client;
  final bool Function() _isEnabled;
  final DateTime Function() _clock;
  final FeedbackContext Function() _appContext;
  final String? Function() _currentScreen;

  /// Version publiée (pas debug, pas `flutter test`) : seule à envoyer.
  final bool active;

  static bool get _runningTests {
    try {
      return Platform.environment.containsKey('FLUTTER_TEST');
    } catch (_) {
      return false;
    }
  }

  /// Webhook présent dans ce build : sinon le rapporteur ne fait rien.
  bool get isConfigured => _client.isConfigured;

  /// Branche le rapporteur sur les erreurs de Flutter (affichage, mise en page,
  /// gestes…) et sur les erreurs Dart non rattrapées (Future sans catch,
  /// timers, flux…). Les erreurs restent affichées comme avant (console en
  /// debug). Pas besoin de runZonedGuarded : depuis Flutter 3.3, les erreurs
  /// asynchrones de la zone racine arrivent dans PlatformDispatcher.onError.
  void install() {
    final previousFlutter = FlutterError.onError;
    FlutterError.onError = (details) {
      (previousFlutter ?? FlutterError.presentError)(details);
      // « silent » : erreur sans gravité que Flutter n'affiche pas en release.
      if (!details.silent) unawaited(record(details.exception, details.stack, context: flutterErrorContext(details)));
    };
    final dispatcher = PlatformDispatcher.instance;
    final previousPlatform = dispatcher.onError;
    dispatcher.onError = (error, stack) {
      unawaited(record(error, stack, context: 'erreur non rattrapée (code asynchrone)'));
      // false : le moteur affiche quand même l'erreur, comme sans rapporteur.
      return previousPlatform?.call(error, stack) ?? false;
    };
  }

  /// Signale une erreur. Ne lève jamais d'exception.
  Future<void> record(Object error, StackTrace? stack, {String? context}) async {
    try {
      if (!active || !isConfigured || isBenignCrash(error) || !_isEnabled()) return;
      final at = _clock();
      // Tri d'abord (peu coûteux) : une erreur répétée à chaque image s'arrête ici.
      if (!_accept(crashSignature(errorTypeName(error), parseFrames(stack)), at)) return;
      final report = CrashReport.capture(
        error,
        stack,
        app: _appContext(),
        at: at,
        context: context,
        screen: _screen(),
      );
      try {
        await _client.sendPayload(buildCrashPayload(report));
      } catch (_) {
        await _enqueue(report);
      }
    } catch (_) {
      // Un rapport raté ne doit pas faire planter l'appli à son tour.
    }
  }

  /// Renvoie les rapports restés en attente (au démarrage, en tâche de fond).
  Future<void> flushPending({Duration delay = Duration.zero}) async {
    if (!active || !isConfigured) return;
    try {
      if (delay > Duration.zero) await Future<void>.delayed(delay);
      if (!_isEnabled()) {
        // Réglage coupé depuis : ces rapports ne partiront jamais.
        await _prefs.remove(pendingKey);
        return;
      }
      final sent = <String>{};
      for (final report in _pending()) {
        try {
          await _client.sendPayload(buildCrashPayload(report));
          sent.add(report.id);
        } catch (_) {
          break; // toujours pas de réseau : au prochain démarrage
        }
      }
      // Relu après les envois : un plantage a pu s'ajouter entre-temps.
      await _savePending([
        for (final r in _pending())
          if (!sent.contains(r.id)) r,
      ]);
    } catch (_) {
      // Tant pis, on réessaiera au prochain démarrage.
    }
  }

  /// Rapports en attente d'envoi (les trop vieux sont abandonnés).
  @visibleForTesting
  List<CrashReport> pendingReports() => _pending();

  String? _screen() {
    try {
      return _currentScreen();
    } catch (_) {
      return null;
    }
  }

  /// Anti-spam : non si la même erreur est déjà partie cette semaine ou si le
  /// quota du jour est atteint. Sinon le rapport est compté tout de suite,
  /// avant l'envoi, pour qu'une erreur répétée en rafale ne parte qu'une fois.
  bool _accept(String signature, DateTime at) {
    final now = at.millisecondsSinceEpoch;
    final seen = <String, int>{};
    try {
      final raw = jsonDecode(_prefs.getString(seenKey) ?? '{}') as Map<String, dynamic>;
      for (final e in raw.entries) {
        final t = e.value;
        if (t is int && _within(now, t, sameErrorEvery)) seen[e.key] = t;
      }
    } catch (_) {
      // Données illisibles : on repart de zéro.
    }
    if (seen.containsKey(signature)) return false;
    final sent = [
      for (final t in (_prefs.getStringList(sentKey) ?? const <String>[]).map(int.tryParse))
        if (t != null && _within(now, t, _day)) t,
    ];
    if (sent.length >= maxPerDay) return false;
    seen[signature] = now;
    sent.add(now);
    // Valeurs relues tout de suite (cache des préférences) ; une écriture ratée
    // sur le téléphone ne doit pas déclencher un nouveau rapport.
    _prefs.setString(seenKey, jsonEncode(seen)).ignore();
    _prefs.setStringList(sentKey, [for (final t in sent) '$t']).ignore();
    return true;
  }

  static bool _within(int now, int t, Duration period) => t <= now && now - t < period.inMilliseconds;

  Future<void> _enqueue(CrashReport report) async {
    final all = [..._pending(), report];
    await _savePending(all.length > maxPending ? all.sublist(all.length - maxPending) : all);
  }

  List<CrashReport> _pending() {
    final now = _clock();
    final out = <CrashReport>[];
    for (final raw in _prefs.getStringList(pendingKey) ?? const <String>[]) {
      try {
        final report = CrashReport.fromJson(jsonDecode(raw) as Map<String, dynamic>);
        if (now.difference(report.at) < keepPendingFor) out.add(report);
      } catch (_) {
        // Rapport illisible : abandonné.
      }
    }
    return out;
  }

  Future<void> _savePending(List<CrashReport> reports) => reports.isEmpty
      ? _prefs.remove(pendingKey)
      : _prefs.setStringList(pendingKey, [for (final r in reports) jsonEncode(r.toJson())]);
}

/// Ce que faisait Flutter (« building RideScreen (widgets library) »), sans le
/// détail du widget (clé, état…) qui pourrait contenir des données.
String? flutterErrorContext(FlutterErrorDetails details) {
  var what = '';
  try {
    what = details.context?.toDescription() ?? '';
  } catch (_) {
    // Description indisponible : on s'en passe.
  }
  what = what.split(RegExp(r'-?[(\[\n]')).first.trim();
  final library = details.library;
  final parts = [
    if (what.isNotEmpty) what,
    if (library != null && library.isNotEmpty) '($library)',
  ];
  return parts.isEmpty ? null : parts.join(' ');
}

/// Suit les écrans ouverts pour dire dans le rapport où on était.
class CrashScreenObserver extends NavigatorObserver {
  final _routes = <Route<dynamic>>[];

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) => _routes.add(route);

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) => _routes.remove(route);

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) => _routes.remove(route);

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    final i = oldRoute == null ? -1 : _routes.indexOf(oldRoute);
    if (i >= 0) _routes.removeAt(i);
    if (newRoute != null) _routes.insert(i >= 0 ? i : _routes.length, newRoute);
  }

  /// Écran affiché (« RideScreen ») : le plus haut qui contient un widget
  /// « …Screen » (une fenêtre ou un panneau ouvert par-dessus n'en a pas).
  String? currentScreen() {
    for (final route in _routes.reversed) {
      if (route is! ModalRoute) continue;
      final name = findScreenWidget(route.subtreeContext);
      if (name != null) return name;
    }
    return null;
  }
}

/// Branché sur le navigateur de l'appli (voir app.dart).
final crashScreenObserver = CrashScreenObserver();

/// Premier widget dont le nom finit par « Screen » sous [context]. Dans un
/// IndexedStack (onglets de l'accueil), seul l'onglet affiché est suivi.
@visibleForTesting
String? findScreenWidget(BuildContext? context) {
  if (context is! Element) return null;
  var budget = 5000; // de quoi trouver l'écran sans parcourir tout l'arbre
  String? visit(Element element, int? onlyChild) {
    if (--budget < 0) return null;
    final widget = element.widget;
    final name = widget.runtimeType.toString();
    // DisplayFeatureSubScreen : enveloppe des fenêtres de Flutter, pas un écran.
    if (name.endsWith('Screen') && name != 'DisplayFeatureSubScreen') {
      return name.startsWith('_') ? name.substring(1) : name;
    }
    // IndexedStack enveloppe ses enfants : le tri se fait un niveau plus bas.
    final next = widget is IndexedStack ? widget.index : null;
    String? found;
    var i = 0;
    element.visitChildren((child) {
      if (found == null && (onlyChild == null || i == onlyChild)) found = visit(child, next);
      i++;
    });
    return found;
  }

  return visit(context, null);
}
