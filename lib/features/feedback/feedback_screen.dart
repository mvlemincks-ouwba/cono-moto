import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/config.dart';
import '../../core/settings.dart';
import '../../core/theme.dart';
import '../../core/ui/widgets.dart';
import '../../services/feedback/discord_feedback.dart';
import '../social/social_providers.dart';

/// Client d'envoi des retours (surchargeable dans les tests).
final discordFeedbackClientProvider = Provider<DiscordFeedbackClient>((ref) {
  final c = DiscordFeedbackClient();
  ref.onDispose(c.close);
  return c;
});

/// Ouvre l'invitation au serveur Discord (si configurée).
Future<void> openDiscordInvite() async {
  if (AppConfig.discordInviteUrl.isEmpty) return;
  await launchUrl(Uri.parse(AppConfig.discordInviteUrl), mode: LaunchMode.externalApplication);
}

/// Boîte à idées : une idée ou un bug, posté direct sur le Discord de la bande.
class FeedbackScreen extends ConsumerStatefulWidget {
  const FeedbackScreen({super.key, this.initialKind = FeedbackKind.idee});

  final FeedbackKind initialKind;

  static Route<void> route({FeedbackKind initialKind = FeedbackKind.idee}) =>
      MaterialPageRoute(builder: (_) => FeedbackScreen(initialKind: initialKind));

  @override
  ConsumerState<FeedbackScreen> createState() => _FeedbackScreenState();
}

class _FeedbackScreenState extends ConsumerState<FeedbackScreen> {
  static const _authorKey = 'feedback.author';

  /// Anti-doublon : pas deux envois en moins de 30 s.
  static DateTime? _lastSent;

  late FeedbackKind _kind = widget.initialKind;
  final _title = TextEditingController();
  final _description = TextEditingController();
  final _author = TextEditingController();
  FeedbackAttachment? _attachment;
  bool _deviceInfo = true;
  bool _sending = false;
  bool _sent = false;

  @override
  void initState() {
    super.initState();
    final saved = ref.read(sharedPreferencesProvider).getString(_authorKey);
    final profileName = ref.read(myProfileProvider).value?.name;
    _author.text = saved ?? profileName ?? '';
  }

  @override
  void dispose() {
    _title.dispose();
    _description.dispose();
    _author.dispose();
    super.dispose();
  }

  FeedbackDraft get _draft => FeedbackDraft(
        kind: _kind,
        title: _title.text,
        description: _description.text,
        author: _author.text,
        attachment: _attachment,
        includeDeviceInfo: _deviceInfo,
      );

  Future<void> _pickScreenshot() async {
    try {
      final file = await FilePicker.pickFile(type: FileType.image, compressionQuality: 70, dialogTitle: 'Choisis une capture');
      if (file == null) return;
      final bytes = await file.readAsBytes();
      if (bytes.length > FeedbackAttachment.maxBytes) {
        if (mounted) showCmSnack(context, 'Capture trop lourde (8 Mo maximum).', error: true);
        return;
      }
      final ext = file.name.contains('.') ? file.name.split('.').last.toLowerCase() : 'jpg';
      setState(() => _attachment = FeedbackAttachment(bytes: bytes, filename: 'capture.$ext'));
    } catch (_) {
      if (mounted) showCmSnack(context, 'Impossible d\'ouvrir tes photos.', error: true);
    }
  }

  Future<void> _send() async {
    final draft = _draft;
    final error = draft.validate();
    if (error != null) {
      showCmSnack(context, error, error: true);
      return;
    }
    final last = _lastSent;
    if (last != null && DateTime.now().difference(last) < const Duration(seconds: 30)) {
      showCmSnack(context, 'Doucement 🙂 attends quelques secondes avant de renvoyer.');
      return;
    }
    setState(() => _sending = true);
    try {
      await ref.read(discordFeedbackClientProvider).send(draft, FeedbackContext.current());
      _lastSent = DateTime.now();
      await ref.read(sharedPreferencesProvider).setString(_authorKey, _author.text.trim());
      if (mounted) setState(() => _sent = true);
    } on FeedbackException catch (e) {
      if (mounted) showCmSnack(context, e.message, error: true);
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _shareOtherwise() async {
    final draft = _draft;
    if (draft.title.trim().isEmpty && draft.description.trim().isEmpty) {
      showCmSnack(context, 'Écris d\'abord ton idée 🙂', error: true);
      return;
    }
    await SharePlus.instance.share(ShareParams(
      text: draft.asPlainText(FeedbackContext.current()),
      subject: 'Cono Moto : ${draft.kind.label.toLowerCase()}',
    ));
  }

  @override
  Widget build(BuildContext context) {
    final configured = ref.watch(discordFeedbackClientProvider).isConfigured;
    return Scaffold(
      appBar: AppBar(title: const Text('Boîte à idées')),
      body: _sent ? _SentView(kind: _kind, onAnother: _reset) : _form(context, configured),
    );
  }

  void _reset() => setState(() {
        _sent = false;
        _title.clear();
        _description.clear();
        _attachment = null;
      });

  Widget _form(BuildContext context, bool configured) {
    final scheme = Theme.of(context).colorScheme;
    return ListView(
      padding: const EdgeInsets.fromLTRB(CmSpacing.lg, CmSpacing.sm, CmSpacing.lg, CmSpacing.xxl),
      children: [
        Text(
          'Une idée pour l\'appli ? Un truc qui coince ? Dis-le : ça part sur le Discord de la bande, '
          'tout le monde peut voter 👍, et on s\'en occupe.',
          style: TextStyle(color: scheme.onSurfaceVariant, height: 1.4),
        ),
        if (!configured) ...[
          const SizedBox(height: CmSpacing.md),
          Card(
            color: CmColors.amber.withValues(alpha: 0.12),
            child: const Padding(
              padding: EdgeInsets.all(CmSpacing.md),
              child: Row(
                children: [
                  Icon(Icons.info_outline_rounded, color: CmColors.amber),
                  SizedBox(width: CmSpacing.md),
                  Expanded(
                    child: Text(
                      'Le Discord n\'est pas encore branché sur cette version : utilise « Partager autrement » '
                      '(WhatsApp, Messages…).',
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
        const SizedBox(height: CmSpacing.lg),
        SegmentedButton<FeedbackKind>(
          segments: [
            for (final k in FeedbackKind.values) ButtonSegment(value: k, label: Text('${k.emoji} ${k.label}')),
          ],
          selected: {_kind},
          showSelectedIcon: false,
          onSelectionChanged: (s) => setState(() => _kind = s.first),
        ),
        const SizedBox(height: CmSpacing.lg),
        TextField(
          controller: _title,
          maxLength: 90,
          textCapitalization: TextCapitalization.sentences,
          decoration: InputDecoration(
            labelText: 'Titre',
            hintText: switch (_kind) {
              FeedbackKind.idee => 'Ex : afficher les radars sur la carte',
              FeedbackKind.bug => 'Ex : la carte se fige quand je verrouille',
              FeedbackKind.autre => 'De quoi tu veux parler ?',
            },
          ),
        ),
        const SizedBox(height: CmSpacing.sm),
        TextField(
          controller: _description,
          minLines: 5,
          maxLines: 12,
          maxLength: 3000,
          textCapitalization: TextCapitalization.sentences,
          decoration: InputDecoration(
            labelText: 'Explique-nous',
            alignLabelWithHint: true,
            hintText: _kind == FeedbackKind.bug
                ? 'Ce que tu faisais, ce qui s\'est passé, ce que tu attendais…'
                : 'Comment tu l\'imagines, à quoi ça te servirait…',
          ),
        ),
        const SizedBox(height: CmSpacing.sm),
        TextField(
          controller: _author,
          maxLength: 40,
          textCapitalization: TextCapitalization.words,
          decoration: const InputDecoration(labelText: 'Ton pseudo (facultatif)'),
        ),
        const SizedBox(height: CmSpacing.sm),
        if (_attachment == null)
          OutlinedButton.icon(
            onPressed: _pickScreenshot,
            icon: const Icon(Icons.add_photo_alternate_outlined),
            label: const Text('Ajouter une capture d\'écran'),
          )
        else
          Card(
            clipBehavior: Clip.antiAlias,
            child: Row(
              children: [
                Image.memory(_attachment!.bytes, width: 72, height: 72, fit: BoxFit.cover),
                const SizedBox(width: CmSpacing.md),
                const Expanded(child: Text('Capture jointe')),
                IconButton(
                  tooltip: 'Retirer la capture',
                  onPressed: () => setState(() => _attachment = null),
                  icon: const Icon(Icons.close_rounded),
                ),
              ],
            ),
          ),
        const SizedBox(height: CmSpacing.sm),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          value: _deviceInfo,
          onChanged: (v) => setState(() => _deviceInfo = v),
          title: const Text('Joindre la version de l\'appli et du téléphone'),
          subtitle: const Text('Ça aide beaucoup pour les bugs'),
        ),
        const SizedBox(height: CmSpacing.lg),
        if (configured)
          FilledButton.icon(
            onPressed: _sending ? null : _send,
            icon: _sending
                ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2.4))
                : const Icon(Icons.send_rounded),
            label: Text(_sending ? 'Envoi…' : 'Envoyer sur Discord'),
          ),
        const SizedBox(height: CmSpacing.sm),
        OutlinedButton.icon(
          onPressed: _sending ? null : _shareOtherwise,
          icon: const Icon(Icons.ios_share_rounded),
          label: const Text('Partager autrement'),
        ),
        if (AppConfig.discordInviteUrl.isNotEmpty) ...[
          const SizedBox(height: CmSpacing.sm),
          TextButton.icon(
            onPressed: openDiscordInvite,
            icon: const Icon(Icons.forum_outlined),
            label: const Text('Voir les idées des autres sur Discord'),
          ),
        ],
      ],
    );
  }
}

class _SentView extends StatelessWidget {
  const _SentView({required this.kind, required this.onAnother});

  final FeedbackKind kind;
  final VoidCallback onAnother;

  @override
  Widget build(BuildContext context) {
    return EmptyState(
      icon: kind == FeedbackKind.bug ? Icons.build_circle_outlined : Icons.lightbulb_outline_rounded,
      title: 'Merci, c\'est posté ! 🙌',
      message: kind == FeedbackKind.bug
          ? 'Ton bug est sur le Discord. On regarde ça et on te répond dans le fil.'
          : 'Ton idée est sur le Discord : les potes peuvent voter 👍 et on te répond dans le fil.',
      action: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (AppConfig.discordInviteUrl.isNotEmpty)
            FilledButton.icon(
              onPressed: openDiscordInvite,
              icon: const Icon(Icons.forum_outlined),
              label: const Text('Ouvrir le Discord'),
            ),
          TextButton(onPressed: onAnother, child: const Text('Envoyer autre chose')),
        ],
      ),
    );
  }
}
