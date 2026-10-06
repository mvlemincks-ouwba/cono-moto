import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/config.dart';
import '../../services/update/app_update.dart';
import 'update_controller.dart';

/// Présente la nouvelle version trouvée (quoi de neuf + bouton de mise à jour).
Future<void> showUpdateSheet(BuildContext context) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => const UpdateSheet(),
  );
}

class UpdateSheet extends ConsumerWidget {
  const UpdateSheet({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(appUpdateProvider);
    final manifest = state.manifest;
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    if (manifest == null) return const SizedBox(height: 120, child: Center(child: CircularProgressIndicator()));

    final details = [manifest.label, if (manifest.sizeLabel.isNotEmpty) manifest.sizeLabel].join(' · ');
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.85),
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: [
                Icon(Icons.rocket_launch_rounded, color: scheme.primary, size: 32),
                const SizedBox(width: 12),
                Expanded(
                  child: Text('Nouvelle version de Cono Moto',
                      style: text.titleLarge?.copyWith(fontWeight: FontWeight.w800)),
                ),
              ]),
              const SizedBox(height: 4),
              Text(details, style: TextStyle(color: scheme.onSurfaceVariant)),
              if (manifest.notes.isNotEmpty) ...[
                const SizedBox(height: 16),
                Text('Quoi de neuf', style: text.titleSmall?.copyWith(fontWeight: FontWeight.w700)),
                const SizedBox(height: 6),
                for (final n in manifest.notes)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      const Text('•  '),
                      Expanded(child: Text(n)),
                    ]),
                  ),
              ],
              const SizedBox(height: 20),
              if (manifest.platform == UpdatePlatform.ios)
                _IosActions(manifest: manifest)
              else
                _AndroidActions(state: state),
            ],
          ),
        ),
      ),
    );
  }
}

class _AndroidActions extends ConsumerWidget {
  const _AndroidActions({required this.state});

  final AppUpdateState state;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final controller = ref.read(appUpdateProvider.notifier);
    final scheme = Theme.of(context).colorScheme;
    switch (state.phase) {
      case UpdatePhase.downloading:
        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          LinearProgressIndicator(value: state.progress > 0 ? state.progress : null),
          const SizedBox(height: 8),
          Text('Téléchargement… ${(state.progress * 100).round()} %'),
          const SizedBox(height: 4),
          Text('Tu peux continuer à utiliser l\'appli pendant ce temps.',
              style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 13)),
        ]);
      case UpdatePhase.waitingPermission:
        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          const Text(
            'Android demande d\'autoriser Cono Moto à installer ses mises à jour (une seule fois). '
            'Active « Autoriser cette source » dans le réglage qui vient de s\'ouvrir, puis reviens ici : '
            'l\'installation reprendra toute seule.',
          ),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            onPressed: controller.openPermissionSettings,
            icon: const Icon(Icons.settings_outlined),
            label: const Text('Ouvrir le réglage'),
          ),
        ]);
      case UpdatePhase.installing:
        return const Text(
          'Confirme l\'installation dans la fenêtre d\'Android si elle s\'affiche. '
          'L\'appli va se fermer le temps de la mise à jour : rouvre-la ensuite, tes balades et réglages sont gardés.',
        );
      default:
        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          if (state.phase == UpdatePhase.error && state.message.isNotEmpty) ...[
            Text(state.message, style: TextStyle(color: scheme.error)),
            const SizedBox(height: 12),
          ],
          FilledButton.icon(
            onPressed: controller.downloadAndInstall,
            icon: const Icon(Icons.system_update_alt_rounded),
            label: Text(state.phase == UpdatePhase.error ? 'Réessayer' : 'Mettre à jour'),
          ),
          const SizedBox(height: 4),
          TextButton(onPressed: () => _later(context, ref), child: const Text('Plus tard')),
        ]);
    }
  }
}

class _IosActions extends ConsumerWidget {
  const _IosActions({required this.manifest});

  final UpdateManifest manifest;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final page = ref.read(updateClientProvider).pageUri;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      const Text(
        'Sur iPhone, la mise à jour s\'installe avec SideStore (dans l\'onglet « Mes apps », sans ordinateur) '
        'ou avec Sideloadly depuis ton ordinateur, comme la première fois. Tes données sont gardées.',
      ),
      const SizedBox(height: 16),
      if (page != null)
        FilledButton.icon(
          onPressed: () => launchUrl(page, mode: LaunchMode.externalApplication),
          icon: const Icon(Icons.open_in_new_rounded),
          label: const Text('Comment faire'),
        ),
      const SizedBox(height: 4),
      TextButton(onPressed: () => _later(context, ref), child: const Text('Plus tard')),
    ]);
  }
}

Future<void> _later(BuildContext context, WidgetRef ref) async {
  final manifest = ref.read(appUpdateProvider).manifest;
  if (manifest != null) await ref.read(appUpdateProvider.notifier).snooze(manifest);
  if (context.mounted) Navigator.of(context).pop();
}

/// Lignes du réglage « Mises à jour » : version installée, recherche manuelle
/// et vérification automatique.
class UpdateSettingsTiles extends ConsumerWidget {
  const UpdateSettingsTiles({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(appUpdateProvider);
    final controller = ref.read(appUpdateProvider.notifier);
    final manifest = state.manifest;
    final String subtitle = switch (state.phase) {
      UpdatePhase.checking => 'Recherche d\'une nouvelle version…',
      UpdatePhase.upToDate => 'Tu as la dernière version ✅',
      UpdatePhase.available => 'Nouvelle version disponible : ${manifest?.label ?? ''}. Touche pour l\'installer',
      UpdatePhase.downloading => 'Téléchargement… ${(state.progress * 100).round()} %',
      UpdatePhase.waitingPermission || UpdatePhase.installing => 'Installation en cours…',
      UpdatePhase.error => state.message,
      UpdatePhase.idle => 'Touche pour chercher une nouvelle version',
    };
    return Column(mainAxisSize: MainAxisSize.min, children: [
      ListTile(
        leading: Icon(manifest != null ? Icons.system_update_rounded : Icons.verified_outlined),
        title: Text('Version ${AppConfig.appVersion} (build ${AppConfig.appBuild})'),
        subtitle: Text(subtitle),
        trailing: state.phase == UpdatePhase.checking
            ? const SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2))
            : null,
        onTap: state.phase == UpdatePhase.checking
            ? null
            : () async {
                final found = manifest ?? await controller.check(manual: true);
                if (found != null && context.mounted) await showUpdateSheet(context);
              },
      ),
      SwitchListTile(
        secondary: const Icon(Icons.update_rounded),
        title: const Text('Vérifier automatiquement'),
        subtitle: const Text('Au démarrage de l\'appli, jamais pendant une balade'),
        value: state.autoCheck,
        onChanged: controller.setAutoCheck,
      ),
    ]);
  }
}
