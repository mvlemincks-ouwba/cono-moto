import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../../core/settings.dart';
import '../navigation/recent_destinations.dart';
import '../ride/dashboard/dashboard_model.dart';

/// Dernière sauvegarde faite depuis ce téléphone.
@immutable
class LastBackup {
  const LastBackup({required this.at, required this.bytes});

  final DateTime at;

  /// Taille du fichier.
  final int bytes;
}

/// Au-delà, petit rappel dans les réglages.
const backupReminderAfter = Duration(days: 30);

/// Vrai s'il est temps de (re)faire une sauvegarde : des balades à perdre et
/// aucune sauvegarde depuis plus de [backupReminderAfter].
bool backupReminderDue({required int rides, required LastBackup? last, required DateTime now}) =>
    rides > 0 && (last == null || now.difference(last.at) > backupReminderAfter);

/// Date et taille de la dernière sauvegarde. Propres à ce téléphone : jamais
/// dans la sauvegarde elle-même (voir `AppBackup.excludedPrefPrefixes`).
class LastBackupNotifier extends Notifier<LastBackup?> {
  static const atKey = 'backup.lastAt';
  static const bytesKey = 'backup.lastBytes';

  @override
  LastBackup? build() {
    final prefs = ref.watch(sharedPreferencesProvider);
    final at = prefs.getInt(atKey);
    if (at == null) return null;
    return LastBackup(at: DateTime.fromMillisecondsSinceEpoch(at, isUtc: true), bytes: prefs.getInt(bytesKey) ?? 0);
  }

  Future<void> record(DateTime at, int bytes) async {
    state = LastBackup(at: at.toUtc(), bytes: bytes);
    final prefs = ref.read(sharedPreferencesProvider);
    await prefs.setInt(atKey, at.millisecondsSinceEpoch);
    await prefs.setInt(bytesKey, bytes);
  }
}

final lastBackupProvider = NotifierProvider<LastBackupNotifier, LastBackup?>(LastBackupNotifier.new);

/// Après une restauration, l'appli relit tout depuis la base et les
/// préférences : les dépôts sont recréés, donc tout ce qui les écoute
/// (historique, garage, balades à faire, stats…) se recharge, et les réglages,
/// vues du compteur et destinations récentes sont relus.
void reloadAfterRestore(ProviderContainer c) {
  c
    ..invalidate(rideRepositoryProvider)
    ..invalidate(routeRepositoryProvider)
    ..invalidate(garageRepositoryProvider)
    ..invalidate(activeRouteProvider)
    ..invalidate(settingsProvider)
    ..invalidate(dashboardProvider)
    ..invalidate(recentDestinationsProvider);
}
