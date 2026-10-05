import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/providers.dart';
import '../../../core/theme.dart';
import '../../../core/ui/widgets.dart';
import '../../../services/social/social_api.dart';
import '../social_providers.dart';
import 'profile_editor.dart';
import 'social_widgets.dart';

/// Bandeau d'accueil orange avec une petite meute d'avatars.
class SocialHero extends StatelessWidget {
  const SocialHero({super.key, required this.title, required this.subtitle, this.badge});

  final String title;
  final String subtitle;
  final String? badge;

  static const _crew = [
    ('Max', Color(0xFF2EC4B6)),
    ('Julie', Color(0xFFFACC15)),
    ('Lolo', Color(0xFFA78BFA)),
    ('Seb', Color(0xFF4EA8FF)),
  ];

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Container(
      padding: const EdgeInsets.fromLTRB(CmSpacing.xl, CmSpacing.xl, CmSpacing.xl, CmSpacing.xl),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(28),
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFFFF8A3D), CmColors.orange, CmColors.orangeDeep],
        ),
        boxShadow: [
          BoxShadow(color: CmColors.orange.withValues(alpha: 0.35), blurRadius: 30, offset: const Offset(0, 12)),
        ],
      ),
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Positioned(
            right: -30,
            top: -40,
            child: Icon(Icons.two_wheeler, size: 150, color: Colors.white.withValues(alpha: 0.10)),
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  AvatarStack(people: [for (final c in _crew) (c.$1, c.$2)], size: 40),
                  const SizedBox(width: CmSpacing.sm),
                  Expanded(
                    child: badge == null
                        ? const SizedBox.shrink()
                        : Align(
                            alignment: Alignment.centerRight,
                            child: Container(
                              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                              decoration: BoxDecoration(
                                color: Colors.black.withValues(alpha: 0.18),
                                borderRadius: BorderRadius.circular(999),
                              ),
                              child: Text(
                                badge!,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: t.labelMedium?.copyWith(color: Colors.white, fontWeight: FontWeight.w800),
                              ),
                            ),
                          ),
                  ),
                ],
              ),
              const SizedBox(height: CmSpacing.xl),
              Text(title, style: t.displaySmall?.copyWith(color: Colors.white, height: 1.0)),
              const SizedBox(height: CmSpacing.sm),
              Text(subtitle,
                  style: t.bodyLarge?.copyWith(color: Colors.white.withValues(alpha: 0.92), fontWeight: FontWeight.w500)),
            ],
          ),
        ],
      ),
    );
  }
}

/// Fonctionnalités du module, pour l'accueil et le mode solo.
class SocialFeatureList extends StatelessWidget {
  const SocialFeatureList({super.key});

  @override
  Widget build(BuildContext context) {
    return const Column(
      children: [
        FeatureLine(
          icon: Icons.radar_rounded,
          color: CmColors.teal,
          title: 'Tes potes en direct',
          subtitle: 'Vois où roule la bande, qui décroche, et retrouvez-vous au point de regroupement.',
        ),
        FeatureLine(
          icon: Icons.warning_amber_rounded,
          color: CmColors.amber,
          title: 'Signalements entre potes',
          subtitle: 'Gravillons, contrôle, huile, travaux : préviens tout le monde en deux tapes.',
        ),
        FeatureLine(
          icon: Icons.payments_rounded,
          color: CmColors.green,
          title: 'Frais partagés',
          subtitle: 'Essence, péages, resto : qui doit quoi à qui, au centime près.',
        ),
        FeatureLine(
          icon: Icons.share_location_rounded,
          color: CmColors.sky,
          title: 'Lien de suivi',
          subtitle: 'Ta moitié suit ta balade en direct depuis un simple lien web.',
        ),
        FeatureLine(
          icon: Icons.sos_rounded,
          color: CmColors.red,
          title: 'SOS',
          subtitle: 'En cas de chute, tes potes sont prévenus avec ta position.',
        ),
      ],
    );
  }
}

/// Firebase n'est pas configuré dans ce build : explication claire.
class SoloModeView extends StatelessWidget {
  const SoloModeView({super.key});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    Widget step(String n, String text) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 26,
                height: 26,
                alignment: Alignment.center,
                decoration: const BoxDecoration(color: CmColors.orange, shape: BoxShape.circle),
                child: Text(n, style: t.labelLarge?.copyWith(color: Colors.white)),
              ),
              const SizedBox(width: CmSpacing.md),
              Expanded(child: Padding(padding: const EdgeInsets.only(top: 3), child: Text(text))),
            ],
          ),
        );

    return Scaffold(
      appBar: AppBar(title: const Text('Potes')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(CmSpacing.lg, CmSpacing.sm, CmSpacing.lg, CmSpacing.xxl),
        children: [
          const SocialHero(
            title: 'Roule en meute',
            subtitle: 'Cette version de Cono Moto tourne en mode solo : tout le reste marche, sauf les fonctions entre potes.',
            badge: 'MODE SOLO',
          ),
          const SizedBox(height: CmSpacing.lg),
          SocialCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Ce que tu débloques', style: t.titleMedium?.copyWith(fontWeight: FontWeight.w800)),
                const SizedBox(height: CmSpacing.sm),
                const SocialFeatureList(),
              ],
            ),
          ),
          const SizedBox(height: CmSpacing.md),
          SocialCard(
            border: Border.all(color: CmColors.orange.withValues(alpha: 0.35)),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Icon(Icons.build_circle_rounded, color: CmColors.orange),
                    const SizedBox(width: CmSpacing.sm),
                    Expanded(
                      child: Text('Pour activer le mode potes', style: t.titleMedium?.copyWith(fontWeight: FontWeight.w800)),
                    ),
                  ],
                ),
                const SizedBox(height: CmSpacing.sm),
                step('1', 'Crée un projet Firebase gratuit (offre Spark, sans carte bancaire).'),
                step('2', 'Active la connexion par e-mail et une Realtime Database, puis déploie les règles fournies.'),
                step('3', 'Recompile l\'app avec les clés du projet (--dart-define).'),
                const SizedBox(height: CmSpacing.sm),
                Text(
                  'Le pas-à-pas complet est dans firebase/README.md du projet.',
                  style: t.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Accueil quand on n'est pas connecté.
class SocialWelcomeView extends StatelessWidget {
  const SocialWelcomeView({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(CmSpacing.lg, CmSpacing.lg, CmSpacing.lg, CmSpacing.xxl),
          children: [
            const SocialHero(
              title: 'Roule en meute',
              subtitle: 'Tes potes sur la carte, les dangers signalés, les frais partagés. Crée ton compte en 30 secondes.',
            ),
            const SizedBox(height: CmSpacing.xl),
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: CmSpacing.xs),
              child: SocialFeatureList(),
            ),
            const SizedBox(height: CmSpacing.xl),
            FilledButton.icon(
              onPressed: () => Navigator.of(context).push(AuthPage.route(signUp: true)),
              icon: const Icon(Icons.person_add_alt_1_rounded),
              label: const Text('Créer mon compte'),
            ),
            const SizedBox(height: CmSpacing.md),
            OutlinedButton(
              onPressed: () => Navigator.of(context).push(AuthPage.route(signUp: false)),
              child: const Text('J\'ai déjà un compte'),
            ),
          ],
        ),
      ),
    );
  }
}

/// Connexion / inscription par e-mail et mot de passe.
class AuthPage extends ConsumerStatefulWidget {
  const AuthPage({super.key, required this.signUp});

  final bool signUp;

  static Route<void> route({required bool signUp}) =>
      MaterialPageRoute(builder: (_) => AuthPage(signUp: signUp));

  @override
  ConsumerState<AuthPage> createState() => _AuthPageState();
}

class _AuthPageState extends ConsumerState<AuthPage> {
  late bool _signUp = widget.signUp;
  final _email = TextEditingController();
  final _password = TextEditingController();
  final _name = TextEditingController();
  bool _obscure = true;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    _name.dispose();
    super.dispose();
  }

  String? _validate() {
    final email = _email.text.trim();
    if (!RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(email)) return 'Entre une adresse e-mail valide.';
    if (_password.text.length < 6) return 'Le mot de passe doit faire au moins 6 caractères.';
    if (_signUp && _name.text.trim().length < 2) return 'Choisis un pseudo d\'au moins 2 caractères.';
    return null;
  }

  Future<void> _submit() async {
    final invalid = _validate();
    if (invalid != null) {
      setState(() => _error = invalid);
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    final actions = ref.read(socialActionsProvider);
    try {
      if (_signUp) {
        await actions.signUp(
          email: _email.text,
          password: _password.text,
          name: _name.text,
          bike: ref.read(defaultBikeProvider)?.name ?? '',
        );
      } else {
        await actions.signIn(_email.text, _password.text);
      }
      if (mounted) Navigator.of(context).pop();
    } on SocialException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (e) {
      if (mounted) setState(() => _error = 'Oups : $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _forgot() async {
    final ctrl = TextEditingController(text: _email.text.trim());
    final email = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Mot de passe oublié'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('On t\'envoie un lien pour en choisir un nouveau.'),
            const SizedBox(height: CmSpacing.md),
            TextField(
              controller: ctrl,
              autofocus: true,
              keyboardType: TextInputType.emailAddress,
              decoration: const InputDecoration(labelText: 'E-mail', prefixIcon: Icon(Icons.alternate_email)),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Annuler')),
          FilledButton(onPressed: () => Navigator.pop(ctx, ctrl.text.trim()), child: const Text('Envoyer')),
        ],
      ),
    );
    ctrl.dispose();
    if (email == null || email.isEmpty || !mounted) return;
    try {
      await ref.read(socialActionsProvider).resetPassword(email);
      if (mounted) showCmSnack(context, 'E-mail envoyé ! Pense à regarder dans les spams.');
    } on SocialException catch (e) {
      if (mounted) showCmSnack(context, e.message, error: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(CmSpacing.xl, 0, CmSpacing.xl, CmSpacing.xxl),
          children: [
            Text(_signUp ? 'Bienvenue dans la bande' : 'Content de te revoir', style: t.headlineMedium),
            const SizedBox(height: CmSpacing.xs),
            Text(
              _signUp
                  ? 'Un e-mail, un mot de passe, un pseudo. Et c\'est parti.'
                  : 'Connecte-toi pour retrouver tes potes et tes groupes.',
              style: t.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
            ),
            const SizedBox(height: CmSpacing.xl),
            SegmentedButton<bool>(
              segments: const [
                ButtonSegment(value: false, label: Text('Connexion'), icon: Icon(Icons.login_rounded)),
                ButtonSegment(value: true, label: Text('Inscription'), icon: Icon(Icons.person_add_alt_1_rounded)),
              ],
              selected: {_signUp},
              onSelectionChanged: (s) => setState(() {
                _signUp = s.first;
                _error = null;
              }),
            ),
            const SizedBox(height: CmSpacing.xl),
            if (_signUp) ...[
              TextField(
                controller: _name,
                textCapitalization: TextCapitalization.words,
                textInputAction: TextInputAction.next,
                maxLength: 24,
                decoration: const InputDecoration(
                  labelText: 'Pseudo',
                  hintText: 'Comment tes potes t\'appellent ?',
                  prefixIcon: Icon(Icons.badge_outlined),
                  counterText: '',
                ),
              ),
              const SizedBox(height: CmSpacing.md),
            ],
            TextField(
              controller: _email,
              keyboardType: TextInputType.emailAddress,
              autocorrect: false,
              textInputAction: TextInputAction.next,
              autofillHints: const [AutofillHints.email],
              decoration: const InputDecoration(labelText: 'E-mail', prefixIcon: Icon(Icons.alternate_email)),
            ),
            const SizedBox(height: CmSpacing.md),
            TextField(
              controller: _password,
              obscureText: _obscure,
              textInputAction: TextInputAction.done,
              autofillHints: [_signUp ? AutofillHints.newPassword : AutofillHints.password],
              onSubmitted: (_) => _submit(),
              decoration: InputDecoration(
                labelText: 'Mot de passe',
                helperText: _signUp ? '6 caractères minimum' : null,
                prefixIcon: const Icon(Icons.lock_outline_rounded),
                suffixIcon: IconButton(
                  tooltip: _obscure ? 'Afficher' : 'Masquer',
                  icon: Icon(_obscure ? Icons.visibility_outlined : Icons.visibility_off_outlined),
                  onPressed: () => setState(() => _obscure = !_obscure),
                ),
              ),
            ),
            if (!_signUp)
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(onPressed: _busy ? null : _forgot, child: const Text('Mot de passe oublié ?')),
              ),
            if (_error != null) ...[
              const SizedBox(height: CmSpacing.md),
              InlineError(_error!),
            ],
            const SizedBox(height: CmSpacing.xl),
            BusyButton(
              label: _signUp ? 'Créer mon compte' : 'Me connecter',
              busy: _busy,
              onPressed: _submit,
            ),
            const SizedBox(height: CmSpacing.lg),
            Text(
              'Ton e-mail sert uniquement à te connecter : tes potes ne voient que ton pseudo.',
              textAlign: TextAlign.center,
              style: t.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }
}
