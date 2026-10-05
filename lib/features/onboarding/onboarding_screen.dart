import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/location.dart';
import '../../core/native.dart';
import '../../core/notifications.dart';
import '../../core/settings.dart';
import '../../core/theme.dart';

/// Présentation au premier lancement : ce que fait l'app, permissions, sécurité.
class OnboardingScreen extends ConsumerStatefulWidget {
  const OnboardingScreen({super.key});

  @override
  ConsumerState<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends ConsumerState<OnboardingScreen> {
  final _pages = PageController();
  int _index = 0;
  bool _locationOk = false;
  final _name = TextEditingController();
  final _phone = TextEditingController();

  static const _count = 4;

  @override
  void initState() {
    super.initState();
    final s = ref.read(settingsProvider);
    _name.text = s.emergencyName;
    _phone.text = s.emergencyPhone;
  }

  @override
  void dispose() {
    _pages.dispose();
    _name.dispose();
    _phone.dispose();
    super.dispose();
  }

  Future<void> _askLocation() async {
    final access = await ref.read(locationServiceProvider).ensurePermission();
    await Notifications.requestPermission();
    if (mounted) setState(() => _locationOk = access == LocationAccess.granted);
  }

  Future<void> _finish() async {
    final phone = _phone.text.trim();
    // Android uniquement : sur iPhone, il n'y a pas de permission SMS.
    if (phone.isNotEmpty) await NativeBridge.requestSmsPermission();
    await ref.read(settingsProvider.notifier).update((s) => s.copyWith(
          emergencyName: _name.text.trim(),
          emergencyPhone: phone,
          onboardingDone: true,
        ));
  }

  void _next() {
    if (_index == _count - 1) {
      _finish();
    } else {
      _pages.nextPage(duration: const Duration(milliseconds: 350), curve: Curves.easeOutCubic);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(onPressed: _finish, child: const Text('Passer')),
            ),
            Expanded(
              child: PageView(
                controller: _pages,
                onPageChanged: (i) => setState(() => _index = i),
                children: [
                  const _Page(
                    icon: Icons.two_wheeler_rounded,
                    title: 'Salut, motard !',
                    text: 'Cono Moto, c\'est ton copilote pour les balades entre potes : '
                        'trouver de belles routes, suivre ta trace, voir tes potes en direct, '
                        'savoir où faire le plein au meilleur prix… et mesurer à quel point tu penches 😎',
                    bullets: [
                      (Icons.explore, 'Balades sinueuses, forêt, cols, plat ou rapide'),
                      (Icons.groups, 'Tes potes en temps réel sur la carte'),
                      (Icons.local_gas_station, 'Prix de l\'essence du moment'),
                      (Icons.speed, 'Angle, vitesse, freinages : toutes tes stats'),
                    ],
                  ),
                  _Page(
                    icon: Icons.my_location_rounded,
                    title: 'Ta position',
                    text: 'Pour enregistrer tes balades (même écran éteint), afficher ta position '
                        'et la partager à tes potes, Cono Moto a besoin du GPS et des notifications.'
                        '${NativeBridge.isIOS ? '\n\nSur iPhone, choisis « Lorsque l\'app est active » et garde '
                            '« Position exacte » activée : la balade continue d\'être enregistrée écran verrouillé.' : ''}',
                    action: FilledButton.icon(
                      onPressed: _locationOk ? null : _askLocation,
                      icon: Icon(_locationOk ? Icons.check_circle : Icons.location_on_outlined),
                      label: Text(_locationOk ? 'C\'est bon !' : 'Autoriser'),
                    ),
                  ),
                  const _Page(
                    icon: Icons.phone_android_rounded,
                    title: 'Fixe ton téléphone',
                    text: 'Pour mesurer l\'angle d\'inclinaison et les freinages, le téléphone doit être '
                        'fixé sur le guidon (support moto). Dans une poche, les stats d\'angle ne '
                        'seront pas fiables — le reste marche quand même.',
                    bullets: [
                      (Icons.check, 'Support rigide sur le guidon ou le té de fourche'),
                      (Icons.check, 'Écran face à toi, en portrait ou paysage'),
                      (Icons.battery_charging_full, 'Branche-le sur une prise USB si tu peux'),
                    ],
                  ),
                  _Page(
                    icon: Icons.health_and_safety_rounded,
                    title: 'Si ça tourne mal',
                    text: NativeBridge.canSendSmsAutomatically
                        ? 'Si l\'app détecte une chute (choc violent puis immobilité) et que tu ne réponds '
                            'pas en 60 s, elle envoie un SMS avec ta position à ton contact d\'urgence et alerte tes potes.'
                        : 'Si l\'app détecte une chute (choc violent puis immobilité) et que tu ne réponds '
                            'pas en 60 s, elle alerte tes potes et prépare un SMS avec ta position pour ton contact '
                            'd\'urgence : sur iPhone, le SMS est préparé, il te reste à appuyer sur Envoyer '
                            '(Apple interdit l\'envoi automatique).',
                    child: Column(
                      children: [
                        TextField(
                          controller: _name,
                          textCapitalization: TextCapitalization.words,
                          decoration: const InputDecoration(labelText: 'Nom du contact', prefixIcon: Icon(Icons.person_outline)),
                        ),
                        const SizedBox(height: 12),
                        TextField(
                          controller: _phone,
                          keyboardType: TextInputType.phone,
                          decoration: const InputDecoration(labelText: 'Téléphone', prefixIcon: Icon(Icons.phone_outlined)),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
              child: Row(
                children: [
                  for (var i = 0; i < _count; i++)
                    AnimatedContainer(
                      duration: const Duration(milliseconds: 250),
                      margin: const EdgeInsets.only(right: 6),
                      width: i == _index ? 22 : 8,
                      height: 8,
                      decoration: BoxDecoration(
                        color: i == _index ? CmColors.orange : scheme.outlineVariant,
                        borderRadius: BorderRadius.circular(8),
                      ),
                    ),
                  const Spacer(),
                  FilledButton(
                    onPressed: _next,
                    child: Text(_index == _count - 1 ? 'On roule !' : 'Suivant'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Page extends StatelessWidget {
  const _Page({
    required this.icon,
    required this.title,
    required this.text,
    this.bullets = const [],
    this.action,
    this.child,
  });

  final IconData icon;
  final String title;
  final String text;
  final List<(IconData, String)> bullets;
  final Widget? action;
  final Widget? child;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 28),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 24),
          Container(
            width: 84,
            height: 84,
            decoration: BoxDecoration(
              gradient: const LinearGradient(colors: [CmColors.orange, CmColors.orangeDeep]),
              borderRadius: BorderRadius.circular(26),
              boxShadow: [BoxShadow(color: CmColors.orange.withValues(alpha: 0.4), blurRadius: 24)],
            ),
            child: Icon(icon, color: Colors.white, size: 44),
          ),
          const SizedBox(height: 28),
          Text(title, style: CmTheme.numbers(size: 40, color: scheme.onSurface)),
          const SizedBox(height: 14),
          Text(text, style: Theme.of(context).textTheme.bodyLarge?.copyWith(color: scheme.onSurfaceVariant, height: 1.45)),
          const SizedBox(height: 20),
          for (final (i, label) in bullets)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Row(
                children: [
                  Icon(i, color: CmColors.orange, size: 22),
                  const SizedBox(width: 12),
                  Expanded(child: Text(label, style: const TextStyle(fontWeight: FontWeight.w600))),
                ],
              ),
            ),
          if (action != null) ...[const SizedBox(height: 8), action!],
          if (child != null) ...[const SizedBox(height: 8), child!],
          const SizedBox(height: 24),
        ],
      ),
    );
  }
}
