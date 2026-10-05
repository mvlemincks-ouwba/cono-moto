import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/config.dart';
import '../../core/native.dart';
import '../../core/settings.dart';
import '../../core/theme.dart';
import '../../core/ui/widgets.dart';
import '../../data/models/garage.dart';
import '../../services/feedback/discord_feedback.dart';
import '../feedback/feedback_screen.dart';
import '../offline/offline_maps_screen.dart';

/// Réglages de l'app.
class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  static Route<void> route() => MaterialPageRoute(builder: (_) => const SettingsScreen());

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(settingsProvider);
    final n = ref.read(settingsProvider.notifier);
    final scheme = Theme.of(context).colorScheme;
    // iPhone : Apple interdit l'envoi automatique de SMS.
    final smsAuto = NativeBridge.canSendSmsAutomatically;

    return Scaffold(
      appBar: AppBar(title: const Text('Réglages')),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 40),
        children: [
          const SectionHeader('Sécurité'),
          _Group(children: [
            SwitchListTile(
              secondary: const Icon(Icons.health_and_safety_outlined),
              title: const Text('Détection de chute'),
              subtitle: Text(smsAuto
                  ? 'Choc violent puis immobilité : compte à rebours, puis SMS à ton contact d\'urgence'
                  : 'Choc violent puis immobilité : compte à rebours, puis alerte aux potes et SMS prêt '
                      'à envoyer à ton contact d\'urgence'),
              value: s.crashDetection,
              onChanged: (v) => n.update((x) => x.copyWith(crashDetection: v)),
            ),
            ListTile(
              leading: const Icon(Icons.contact_phone_outlined),
              title: const Text('Contact d\'urgence'),
              subtitle: Text(
                s.hasEmergencyContact
                    ? '${s.emergencyName.isEmpty ? 'Contact' : s.emergencyName} · ${s.emergencyPhone}'
                    : 'Personne n\'est prévenu en cas de chute : ajoute quelqu\'un',
                style: TextStyle(color: s.hasEmergencyContact ? null : CmColors.amber),
              ),
              trailing: const Icon(Icons.edit_outlined),
              onTap: () => _editEmergency(context, ref),
            ),
            if (s.hasEmergencyContact)
              ListTile(
                leading: const Icon(Icons.sms_outlined),
                title: Text(smsAuto ? 'Envoyer un SMS de test' : 'Préparer un SMS de test'),
                subtitle: Text(smsAuto
                    ? 'Vérifie que l\'envoi automatique fonctionne'
                    : 'Sur iPhone, le SMS est préparé : il te reste à appuyer sur Envoyer'),
                onTap: () => _testSms(context, s),
              ),
          ]),
          const SectionHeader('Balade'),
          _Group(children: [
            SwitchListTile(
              secondary: const Icon(Icons.navigation_outlined),
              title: const Text('Plan de navigation en roulant'),
              subtitle: const Text('La balade s\'ouvre sur la carte façon GPS (sinon sur le compteur)'),
              value: s.rideMapFirst,
              onChanged: (v) => n.update((x) => x.copyWith(rideMapFirst: v)),
            ),
            SwitchListTile(
              secondary: const Icon(Icons.record_voice_over_outlined),
              title: const Text('Guidage vocal'),
              subtitle: const Text('Annonces des virages et alertes dans l\'intercom'),
              value: s.voiceGuidance,
              onChanged: (v) => n.update((x) => x.copyWith(voiceGuidance: v)),
            ),
            SwitchListTile(
              secondary: const Icon(Icons.light_mode_outlined),
              title: const Text('Écran toujours allumé'),
              subtitle: const Text('Pendant une balade (plus gourmand en batterie)'),
              value: s.keepScreenOn,
              onChanged: (v) => n.update((x) => x.copyWith(keepScreenOn: v)),
            ),
            SwitchListTile(
              secondary: const Icon(Icons.share_location_outlined),
              title: const Text('Partager ma position aux potes'),
              subtitle: const Text('Automatiquement pendant mes balades'),
              value: s.shareLiveWithFriends,
              onChanged: (v) => n.update((x) => x.copyWith(shareLiveWithFriends: v)),
            ),
            _SliderTile(
              icon: Icons.local_gas_station_outlined,
              title: 'Alerte autonomie',
              valueLabel: '${s.autonomyAlertKm} km restants',
              value: s.autonomyAlertKm.toDouble(),
              min: 10,
              max: 100,
              divisions: 18,
              onChanged: (v) => n.update((x) => x.copyWith(autonomyAlertKm: v.round())),
            ),
            _SliderTile(
              icon: Icons.groups_2_outlined,
              title: 'Pote qui décroche',
              valueLabel: 'au-delà de ${s.stragglerAlertKm.toStringAsFixed(1)} km',
              value: s.stragglerAlertKm,
              min: 0.5,
              max: 10,
              divisions: 19,
              onChanged: (v) => n.update((x) => x.copyWith(stragglerAlertKm: v)),
            ),
            _SliderTile(
              icon: Icons.speed,
              title: 'Seuil freinage fort',
              valueLabel: '${s.hardBrakeThresholdG.toStringAsFixed(2)} g',
              value: s.hardBrakeThresholdG,
              min: 0.3,
              max: 0.9,
              divisions: 12,
              onChanged: (v) => n.update((x) => x.copyWith(hardBrakeThresholdG: v)),
            ),
          ]),
          const SectionHeader('Essence'),
          _Group(children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Carburant affiché en priorité', style: TextStyle(fontWeight: FontWeight.w600)),
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final f in FuelType.values)
                        ChoiceChip(
                          label: Text(f.label),
                          selected: s.fuelType == f,
                          onSelected: (_) => n.update((x) => x.copyWith(fuelType: f)),
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ]),
          const SectionHeader('Carte'),
          _Group(children: [
            ListTile(
              leading: const Icon(Icons.layers_outlined),
              title: const Text('Style de carte'),
              subtitle: Text(s.mapStyle.label),
              onTap: () => _pickMapStyle(context, ref),
            ),
            ListTile(
              leading: const Icon(Icons.dark_mode_outlined),
              title: const Text('Thème'),
              subtitle: Text(switch (s.themeMode) {
                ThemeMode.dark => 'Sombre',
                ThemeMode.light => 'Clair',
                ThemeMode.system => 'Comme le téléphone',
              }),
              onTap: () => _pickTheme(context, ref),
            ),
            ListTile(
              leading: const Icon(Icons.download_for_offline_outlined),
              title: const Text('Cartes hors-ligne'),
              subtitle: const Text('Pour les zones sans réseau'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.of(context).push(OfflineMapsScreen.route()),
            ),
          ]),
          const SectionHeader('Trafic en temps réel'),
          _Group(children: [
            SwitchListTile(
              secondary: const Icon(Icons.traffic_outlined),
              title: const Text('Afficher accidents, travaux, fermetures'),
              value: s.showTraffic,
              onChanged: (v) => n.update((x) => x.copyWith(showTraffic: v)),
            ),
            ListTile(
              leading: const Icon(Icons.key_outlined),
              title: const Text('Clé TomTom'),
              subtitle: Text(
                s.effectiveTomtomKey.isEmpty
                    ? 'Manquante : crée une clé gratuite sur developer.tomtom.com'
                    : (s.tomtomApiKey.isEmpty ? 'Clé fournie avec l\'app' : 'Clé perso ••••${_tail(s.tomtomApiKey)}'),
                style: TextStyle(color: s.effectiveTomtomKey.isEmpty ? CmColors.amber : null),
              ),
              trailing: const Icon(Icons.edit_outlined),
              onTap: () => _editTomtomKey(context, ref),
            ),
          ]),
          const SectionHeader('Communauté'),
          _Group(children: [
            ListTile(
              leading: const Icon(Icons.lightbulb_outline_rounded, color: CmColors.orange),
              title: const Text('Proposer une idée'),
              subtitle: const Text('Une fonction qui te manque ? Dis-le à la bande'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.of(context).push(FeedbackScreen.route()),
            ),
            ListTile(
              leading: const Icon(Icons.bug_report_outlined),
              title: const Text('Signaler un bug'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.of(context).push(FeedbackScreen.route(initialKind: FeedbackKind.bug)),
            ),
            if (AppConfig.discordInviteUrl.isNotEmpty)
              ListTile(
                leading: const Icon(Icons.forum_outlined),
                title: const Text('Rejoindre le Discord'),
                trailing: const Icon(Icons.open_in_new_rounded, size: 18),
                onTap: openDiscordInvite,
              ),
          ]),
          const SectionHeader('À propos'),
          _Group(children: [
            ListTile(
              leading: const Icon(Icons.info_outline),
              title: const Text('Cono Moto'),
              subtitle: Text(AppConfig.firebaseConfigured
                  ? 'Mode potes activé'
                  : 'Mode solo (Firebase non configuré dans ce build)'),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
              child: Text(
                'Données : © contributeurs OpenStreetMap, OpenFreeMap (cartes), '
                'prix-carburants.gouv.fr (prix des carburants), Valhalla / FOSSGIS (itinéraires), '
                'Open-Meteo (météo et altitude), TomTom (trafic), Photon / Komoot (recherche d\'adresses).',
                style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 13),
              ),
            ),
          ]),
        ],
      ),
    );
  }

  static String _tail(String s) => s.length <= 4 ? s : s.substring(s.length - 4);

  Future<void> _editEmergency(BuildContext context, WidgetRef ref) async {
    final s = ref.read(settingsProvider);
    final name = TextEditingController(text: s.emergencyName);
    final phone = TextEditingController(text: s.emergencyPhone);
    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Contact d\'urgence'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: name,
              textCapitalization: TextCapitalization.words,
              decoration: const InputDecoration(labelText: 'Nom', hintText: 'Ex : Julie'),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: phone,
              keyboardType: TextInputType.phone,
              decoration: const InputDecoration(labelText: 'Téléphone', hintText: '06 12 34 56 78'),
            ),
            const SizedBox(height: 12),
            Text(
              NativeBridge.canSendSmsAutomatically
                  ? 'En cas de chute détectée et sans réponse de ta part pendant 60 s, '
                      'un SMS avec ta position lui est envoyé automatiquement.'
                  : 'En cas de chute détectée et sans réponse de ta part pendant 60 s, tes potes sont '
                      'alertés et un SMS avec ta position est préparé pour ce contact. Sur iPhone, '
                      'Apple interdit l\'envoi automatique : il te reste (ou à un témoin) à appuyer sur Envoyer.',
              style: const TextStyle(fontSize: 13),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Annuler')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Enregistrer')),
        ],
      ),
    );
    if (saved == true) {
      await ref.read(settingsProvider.notifier).update(
            (x) => x.copyWith(emergencyName: name.text.trim(), emergencyPhone: phone.text.trim()),
          );
      // Android uniquement : sur iPhone, il n'y a pas de permission SMS.
      if (phone.text.trim().isNotEmpty) await NativeBridge.requestSmsPermission();
    }
  }

  Future<void> _testSms(BuildContext context, AppSettings s) async {
    if (!NativeBridge.canSendSmsAutomatically) {
      // iPhone : Messages s'ouvre pré-rempli, comme en cas de vraie chute.
      final r = await NativeBridge.composeSms(
        s.emergencyPhone,
        'Cono Moto : test du contact d\'urgence. Si je chute à moto, tu pourras recevoir un SMS avec ma position. '
        'Tout va bien 🙂',
      );
      if (!context.mounted) return;
      switch (r) {
        case SmsComposeResult.sent:
          showCmSnack(context, 'SMS de test envoyé ✅');
        case SmsComposeResult.cancelled:
          showCmSnack(context, 'SMS de test non envoyé');
        case SmsComposeResult.failed:
          showCmSnack(context, 'Échec de l\'envoi du SMS', error: true);
        case SmsComposeResult.unavailable:
          showCmSnack(context, 'Ce téléphone ne peut pas envoyer de SMS', error: true);
        case SmsComposeResult.opened:
          break;
      }
      return;
    }
    if (!await NativeBridge.requestSmsPermission()) {
      if (context.mounted) showCmSnack(context, 'Autorise l\'envoi de SMS pour la détection de chute.', error: true);
      return;
    }
    final ok = await NativeBridge.sendSms(
      s.emergencyPhone,
      'Cono Moto : test du contact d\'urgence. Si je chute à moto, tu recevras un SMS avec ma position. Tout va bien 🙂',
    );
    if (context.mounted) {
      showCmSnack(context, ok ? 'SMS de test envoyé ✅' : 'Échec de l\'envoi du SMS', error: !ok);
    }
  }

  Future<void> _editTomtomKey(BuildContext context, WidgetRef ref) async {
    final c = TextEditingController(text: ref.read(settingsProvider).tomtomApiKey);
    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Clé TomTom'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Les infos trafic (accidents, travaux, routes fermées) viennent de TomTom. '
              'Crée un compte gratuit sur developer.tomtom.com et colle ta clé ici '
              '(2 500 requêtes/jour gratuites, largement assez).',
              style: TextStyle(fontSize: 13),
            ),
            const SizedBox(height: 12),
            TextField(controller: c, decoration: const InputDecoration(labelText: 'Clé API')),
            TextButton.icon(
              onPressed: () => launchUrl(Uri.parse('https://developer.tomtom.com/user/register'),
                  mode: LaunchMode.externalApplication),
              icon: const Icon(Icons.open_in_new, size: 18),
              label: const Text('Créer une clé gratuite'),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Annuler')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Enregistrer')),
        ],
      ),
    );
    if (saved == true) {
      await ref.read(settingsProvider.notifier).update((x) => x.copyWith(tomtomApiKey: c.text.trim()));
    }
  }

  Future<void> _pickMapStyle(BuildContext context, WidgetRef ref) async {
    final current = ref.read(settingsProvider).mapStyle;
    final picked = await showModalBottomSheet<MapStyle>(
      context: context,
      builder: (ctx) => SafeArea(
        child: RadioGroup<MapStyle>(
          groupValue: current,
          onChanged: (v) => Navigator.pop(ctx, v),
          child: ListView(
            shrinkWrap: true,
            children: [
              for (final m in MapStyle.values) RadioListTile<MapStyle>(value: m, title: Text(m.label)),
            ],
          ),
        ),
      ),
    );
    if (picked != null) await ref.read(settingsProvider.notifier).update((x) => x.copyWith(mapStyle: picked));
  }

  Future<void> _pickTheme(BuildContext context, WidgetRef ref) async {
    final current = ref.read(settingsProvider).themeMode;
    final picked = await showModalBottomSheet<ThemeMode>(
      context: context,
      builder: (ctx) => SafeArea(
        child: RadioGroup<ThemeMode>(
          groupValue: current,
          onChanged: (v) => Navigator.pop(ctx, v),
          child: const Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              RadioListTile(value: ThemeMode.dark, title: Text('Sombre')),
              RadioListTile(value: ThemeMode.light, title: Text('Clair')),
              RadioListTile(value: ThemeMode.system, title: Text('Comme le téléphone')),
            ],
          ),
        ),
      ),
    );
    if (picked != null) await ref.read(settingsProvider.notifier).update((x) => x.copyWith(themeMode: picked));
  }
}

class _Group extends StatelessWidget {
  const _Group({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Card(
        clipBehavior: Clip.antiAlias,
        child: Column(children: children),
      ),
    );
  }
}

class _SliderTile extends StatelessWidget {
  const _SliderTile({
    required this.icon,
    required this.title,
    required this.valueLabel,
    required this.value,
    required this.min,
    required this.max,
    required this.divisions,
    required this.onChanged,
  });

  final IconData icon;
  final String title;
  final String valueLabel;
  final double value;
  final double min;
  final double max;
  final int divisions;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 8, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, color: Theme.of(context).colorScheme.onSurfaceVariant),
              const SizedBox(width: 16),
              Expanded(child: Text(title, style: const TextStyle(fontSize: 16))),
              Text(valueLabel, style: const TextStyle(color: CmColors.orange, fontWeight: FontWeight.w700)),
              const SizedBox(width: 8),
            ],
          ),
          Slider(
            value: value.clamp(min, max),
            min: min,
            max: max,
            divisions: divisions,
            onChanged: onChanged,
          ),
        ],
      ),
    );
  }
}
