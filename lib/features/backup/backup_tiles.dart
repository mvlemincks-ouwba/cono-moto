import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../core/format.dart';
import '../../core/native.dart';
import '../../core/providers.dart';
import '../../core/settings.dart';
import '../../core/theme.dart';
import '../../core/ui/widgets.dart';
import '../../data/backup.dart';
import '../history/history_providers.dart';
import '../ride/ride_controller.dart';
import 'backup_providers.dart';

/// Section « Sauvegarde » des réglages : toutes les données du téléphone dans
/// un fichier à ranger sur un Drive, dans Fichiers ou par mail, et retour en
/// arrière depuis ce fichier (sur ce téléphone ou un autre).
class BackupSettingsTiles extends ConsumerWidget {
  const BackupSettingsTiles({super.key, this.now});

  /// Date du jour (surchargée dans les tests).
  final DateTime? now;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final rides = ref.watch(ridesProvider).value?.length;
    final last = ref.watch(lastBackupProvider);
    final remind = backupReminderDue(rides: rides ?? 0, last: last, now: now ?? DateTime.now());
    final summary = [
      if (rides != null) rides == 0 ? 'Aucune balade' : _rides(rides),
      last == null
          ? 'pas encore de sauvegarde'
          : 'dernière le ${Fmt.date(last.at)} (${Fmt.fileSize(last.bytes)})',
    ].join(' · ');
    return Column(mainAxisSize: MainAxisSize.min, children: [
      ListTile(
        leading: Icon(Icons.backup_outlined, color: remind ? CmColors.amber : null),
        title: const Text('Sauvegarder mes données'),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(summary),
            if (remind)
              Text(
                last == null
                    ? 'Si tu changes de téléphone, tout est perdu : fais-en une'
                    : 'Plus d\'un mois sans sauvegarde : pense à en refaire une',
                style: const TextStyle(color: CmColors.amber),
              ),
          ],
        ),
        trailing: const Icon(Icons.chevron_right),
        onTap: () => backupFlow(context),
      ),
      ListTile(
        leading: const Icon(Icons.settings_backup_restore_rounded),
        title: const Text('Restaurer une sauvegarde'),
        subtitle: const Text('Reprends tes données depuis un fichier .cmbackup (nouveau téléphone…)'),
        trailing: const Icon(Icons.chevron_right),
        onTap: () => restoreFlow(context),
      ),
    ]);
  }
}

String _rides(int n) => switch (n) {
      0 => 'aucune balade',
      1 => '1 balade',
      _ => '$n balades',
    };

/// Crée le fichier de sauvegarde puis ouvre la feuille de partage (Drive,
/// Fichiers, mail…).
Future<void> backupFlow(BuildContext context) async {
  final container = ProviderScope.containerOf(context, listen: false);
  final box = context.findRenderObject() as RenderBox?;
  final origin = box == null ? null : box.localToGlobal(Offset.zero) & box.size;
  final now = DateTime.now();
  final File file;
  try {
    file = await _withProgress(context, 'Préparation de ta sauvegarde…', (progress) async {
      final dir = Directory('${(await getTemporaryDirectory()).path}/sauvegarde');
      return AppBackup.writeFile(
        container.read(databaseProvider),
        container.read(sharedPreferencesProvider),
        dir,
        now: now,
        onProgress: progress,
      );
    });
  } catch (e) {
    if (context.mounted) showCmSnack(context, 'Sauvegarde impossible : $e', error: true);
    return;
  }
  final ShareResult result;
  try {
    // Pas de texte avec le fichier : sur iPhone, « Enregistrer dans Fichiers »
    // en ferait un deuxième fichier.
    result = await SharePlus.instance.share(
      ShareParams(
        files: [XFile(file.path, mimeType: 'application/octet-stream', name: AppBackup.fileName(now))],
        subject: 'Sauvegarde Cono Moto du ${Fmt.date(now)}',
        sharePositionOrigin: origin,
      ),
    );
  } catch (e) {
    if (context.mounted) showCmSnack(context, 'Partage impossible : $e', error: true);
    return;
  }
  if (result.status == ShareResultStatus.dismissed) return;
  await container.read(lastBackupProvider.notifier).record(now, await file.length());
  if (context.mounted) showCmSnack(context, 'Sauvegarde faite ✅ Garde bien ce fichier.');
}

/// Choisit un fichier de sauvegarde, le vérifie, demande confirmation, puis
/// remplace toutes les données du téléphone.
Future<void> restoreFlow(BuildContext context) async {
  final container = ProviderScope.containerOf(context, listen: false);
  if (container.read(rideControllerProvider).isActive) {
    showCmSnack(context, 'Termine ta balade avant de restaurer une sauvegarde.', error: true);
    return;
  }
  final PlatformFile? file;
  try {
    file = await FilePicker.pickFile(type: FileType.any, dialogTitle: 'Choisis ta sauvegarde Cono Moto');
  } catch (e) {
    if (context.mounted) showCmSnack(context, "Impossible d'ouvrir le sélecteur de fichiers.", error: true);
    return;
  }
  if (file == null || !context.mounted) return;

  final BackupData data;
  try {
    data = await _withProgress(context, 'Lecture de la sauvegarde…', (_) async {
      return AppBackup.read(await file!.readAsBytes());
    });
  } on BackupException catch (e) {
    if (context.mounted) showCmSnack(context, e.message, error: true);
    return;
  } catch (e) {
    if (context.mounted) showCmSnack(context, 'Lecture du fichier impossible.', error: true);
    return;
  }
  if (!context.mounted) return;

  final current = container.read(ridesProvider).value?.length ?? 0;
  final ok = await _confirmRestore(context, data, current);
  if (ok != true || !context.mounted) return;

  try {
    await _withProgress(
      context,
      'Restauration de tes données…',
      (progress) => AppBackup.restore(
        container.read(databaseProvider),
        container.read(sharedPreferencesProvider),
        data,
        onProgress: progress,
      ),
    );
  } catch (e) {
    final why = e is BackupException ? e.message : 'La restauration a échoué.';
    if (context.mounted) showCmSnack(context, "$why Tes données n'ont pas bougé.", error: true);
    return;
  }
  reloadAfterRestore(container);
  if (context.mounted) {
    final n = data.rideCount;
    showCmSnack(context, 'Sauvegarde restaurée : ${_rides(n)} ${n > 1 ? 'récupérées' : 'récupérée'} ✅');
  }
  // Contact d'urgence repris de la sauvegarde : l'envoi de SMS en cas de chute
  // doit être autorisé sur ce téléphone (Android).
  if (container.read(settingsProvider).hasEmergencyContact) await NativeBridge.requestSmsPermission();
}

Future<bool?> _confirmRestore(BuildContext context, BackupData data, int currentRides) {
  final at = data.createdAt;
  final from = at == null ? 'Sauvegarde' : 'Sauvegarde du ${Fmt.dateLong(at)} à ${Fmt.time(at)}';
  final mine = switch (currentRides) {
    0 => '',
    1 => ', dont ta balade actuelle',
    _ => ', dont tes $currentRides balades actuelles',
  };
  return showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      icon: const Icon(Icons.settings_backup_restore_rounded),
      title: const Text('Remplacer tes données ?'),
      content: Text(
        '$from : ${_rides(data.rideCount)}.\n\n'
        'Elle remplace tout ce qu\'il y a sur ce téléphone (balades, garage, balades à faire, réglages)$mine. '
        'Ce qui n\'est pas dans la sauvegarde sera perdu.',
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Annuler')),
        FilledButton(
          style: FilledButton.styleFrom(backgroundColor: CmColors.red),
          onPressed: () => Navigator.pop(ctx, true),
          child: const Text('Remplacer'),
        ),
      ],
    ),
  );
}

/// Fenêtre d'attente, impossible à fermer, pendant [task]. La tâche reçoit de
/// quoi indiquer son avancement (0 à 1) ; sans ça, la barre tourne en boucle.
Future<T> _withProgress<T>(
  BuildContext context,
  String message,
  Future<T> Function(void Function(double done) progress) task,
) async {
  final navigator = Navigator.of(context, rootNavigator: true);
  final progress = ValueNotifier<double?>(null);
  unawaited(showDialog<void>(
    context: context,
    useRootNavigator: true,
    barrierDismissible: false,
    builder: (_) => PopScope(
      canPop: false,
      child: AlertDialog(
        content: ValueListenableBuilder<double?>(
          valueListenable: progress,
          builder: (_, value, _) => Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(message),
              const SizedBox(height: 16),
              LinearProgressIndicator(value: value),
            ],
          ),
        ),
      ),
    ),
  ));
  try {
    return await task((v) => progress.value = v);
  } finally {
    navigator.pop();
    progress.dispose();
  }
}
