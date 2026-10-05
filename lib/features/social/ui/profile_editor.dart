import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/providers.dart';
import '../../../core/theme.dart';
import '../../../core/ui/widgets.dart';
import '../../../services/social/social_api.dart';
import '../social_models.dart';
import '../social_providers.dart';
import 'social_widgets.dart';

/// Formulaire de profil : pseudo, couleur sur la carte, moto.
class ProfileEditor extends ConsumerStatefulWidget {
  const ProfileEditor({
    super.key,
    this.initial,
    required this.submitLabel,
    required this.onSubmit,
  });

  final UserProfile? initial;
  final String submitLabel;
  final Future<void> Function(String name, int colorValue, String bike) onSubmit;

  @override
  ConsumerState<ProfileEditor> createState() => _ProfileEditorState();
}

class _ProfileEditorState extends ConsumerState<ProfileEditor> {
  late final _name = TextEditingController(text: widget.initial?.name ?? '');
  late final _bike = TextEditingController(text: widget.initial?.bike ?? '');
  late int _color = widget.initial?.colorValue ?? CmColors.friendPalette.first.toARGB32();
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    if (widget.initial == null) {
      // Propose la moto par défaut du garage.
      final bike = ref.read(defaultBikeProvider);
      if (bike != null) _bike.text = bike.name;
    }
  }

  @override
  void dispose() {
    _name.dispose();
    _bike.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final name = _name.text.trim();
    if (name.length < 2) {
      setState(() => _error = 'Choisis un pseudo d\'au moins 2 caractères.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.onSubmit(name, _color, _bike.text.trim());
    } on SocialException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (e) {
      if (mounted) setState(() => _error = 'Impossible d\'enregistrer : $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final color = Color(_color);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Center(
          child: ValueListenableBuilder(
            valueListenable: _name,
            builder: (context, value, _) => RiderAvatar(
              name: value.text.trim().isEmpty ? '?' : value.text,
              color: color,
              size: 84,
            ),
          ),
        ),
        const SizedBox(height: CmSpacing.xl),
        TextField(
          controller: _name,
          textCapitalization: TextCapitalization.words,
          maxLength: UserProfile.maxNameLength,
          textInputAction: TextInputAction.next,
          decoration: const InputDecoration(
            labelText: 'Pseudo',
            hintText: 'Comment tes potes t\'appellent ?',
            prefixIcon: Icon(Icons.badge_outlined),
            counterText: '',
          ),
        ),
        const SizedBox(height: CmSpacing.md),
        TextField(
          controller: _bike,
          textCapitalization: TextCapitalization.words,
          maxLength: UserProfile.maxBikeLength,
          decoration: const InputDecoration(
            labelText: 'Ta moto (facultatif)',
            hintText: 'ex : MT-07, Street Triple…',
            prefixIcon: Icon(Icons.two_wheeler),
            counterText: '',
          ),
        ),
        const SizedBox(height: CmSpacing.lg),
        Text('Ta couleur sur la carte', style: t.titleSmall?.copyWith(fontWeight: FontWeight.w800)),
        const SizedBox(height: CmSpacing.sm),
        Wrap(
          spacing: 12,
          runSpacing: 12,
          children: [
            for (final c in CmColors.friendPalette)
              GestureDetector(
                onTap: () => setState(() => _color = c.toARGB32()),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 180),
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    color: c,
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: _color == c.toARGB32() ? scheme.onSurface : Colors.transparent,
                      width: 3,
                    ),
                    boxShadow: _color == c.toARGB32()
                        ? [BoxShadow(color: c.withValues(alpha: 0.6), blurRadius: 12)]
                        : null,
                  ),
                  child: _color == c.toARGB32() ? Icon(Icons.check_rounded, color: onColor(c)) : null,
                ),
              ),
          ],
        ),
        if (_error != null) ...[
          const SizedBox(height: CmSpacing.lg),
          _ErrorText(_error!),
        ],
        const SizedBox(height: CmSpacing.xl),
        BusyButton(label: widget.submitLabel, busy: _busy, onPressed: _submit),
      ],
    );
  }
}

class _ErrorText extends StatelessWidget {
  const _ErrorText(this.message);

  final String message;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(CmSpacing.md),
      decoration: BoxDecoration(
        color: CmColors.red.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          const Icon(Icons.error_outline_rounded, color: CmColors.red),
          const SizedBox(width: CmSpacing.sm),
          Expanded(child: Text(message, style: const TextStyle(color: CmColors.red, fontWeight: FontWeight.w600))),
        ],
      ),
    );
  }
}

/// Message d'erreur en ligne (réutilisé par les formulaires du module).
class InlineError extends StatelessWidget {
  const InlineError(this.message, {super.key});

  final String message;

  @override
  Widget build(BuildContext context) => _ErrorText(message);
}

/// Écran de création du profil juste après l'inscription.
class ProfileSetupView extends ConsumerWidget {
  const ProfileSetupView({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Theme.of(context).textTheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Ton profil'),
        actions: [
          TextButton(
            onPressed: () => ref.read(socialActionsProvider).signOut(),
            child: const Text('Déconnexion'),
          ),
        ],
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(CmSpacing.xl, CmSpacing.sm, CmSpacing.xl, CmSpacing.xxl),
          children: [
            Text('Dernière ligne droite !', style: t.headlineMedium),
            const SizedBox(height: CmSpacing.xs),
            Text(
              'Ton pseudo et ta couleur, c\'est ce que tes potes verront sur la carte.',
              style: t.bodyMedium?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
            ),
            const SizedBox(height: CmSpacing.xl),
            ProfileEditor(
              submitLabel: 'C\'est parti',
              onSubmit: (name, color, bike) async {
                await ref.read(socialActionsProvider).createProfile(name: name, colorValue: color, bike: bike);
              },
            ),
          ],
        ),
      ),
    );
  }
}

/// Feuille d'édition du profil.
Future<void> showEditProfileSheet(BuildContext context, UserProfile me) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (ctx) => Consumer(
      builder: (ctx, ref, _) => Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(ctx).bottom),
        child: SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(CmSpacing.xl, 0, CmSpacing.xl, CmSpacing.xl),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const SheetTitle(icon: Icons.edit_rounded, title: 'Mon profil'),
                const SizedBox(height: CmSpacing.lg),
                ProfileEditor(
                  initial: me,
                  submitLabel: 'Enregistrer',
                  onSubmit: (name, color, bike) async {
                    final synced = await ref
                        .read(socialActionsProvider)
                        .updateProfile(me.copyWith(name: name, colorValue: color, bike: bike));
                    if (ctx.mounted) Navigator.pop(ctx);
                    if (context.mounted) {
                      showCmSnack(context, synced ? 'Profil mis à jour' : 'Enregistré, envoi dès que le réseau revient');
                    }
                  },
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}
