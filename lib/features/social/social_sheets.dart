// Module « Potes » : feuilles et actions appelées depuis la carte, le HUD,
// l'historique et les balades. Les 5 premières fonctions sont le contrat
// entre modules : ne pas les renommer.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:share_plus/share_plus.dart';

import '../../core/config.dart';
import '../../core/format.dart';
import '../../core/geo.dart';
import '../../core/providers.dart';
import '../../core/theme.dart';
import '../../core/ui/widgets.dart';
import '../../data/models/planned_route.dart';
import '../../data/models/ride.dart';
import '../../data/models/shared.dart';
import '../../services/social/codes.dart';
import '../../services/social/social_api.dart';
import '../home/home_shell.dart';
import 'social_models.dart';
import 'social_providers.dart';
import 'ui/group_screen.dart';
import 'ui/profile_editor.dart';
import 'ui/social_widgets.dart';

// ===========================================================================
// Contrat
// ===========================================================================

/// Signaler un danger (gravillons, police…) à la position donnée.
Future<void> showReportSheet(BuildContext context, {required GeoPoint at}) async {
  if (!await _ready(context) || !context.mounted) return;
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (_) => _ReportSheet(at: at),
  );
}

/// Partager sa position en direct (lien web pour quelqu'un sans l'app).
Future<void> showShareLocationSheet(BuildContext context) async {
  if (!await _ready(context) || !context.mounted) return;
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (_) => const _ShareLocationSheet(),
  );
}

/// Définir un point de regroupement pour un de mes groupes.
/// [groupId] présélectionne un groupe.
Future<void> showSetRallyPointSheet(BuildContext context, {required GeoPoint at, String? groupId}) async {
  if (!await _ready(context) || !context.mounted) return;
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (_) => _RallySheet(at: at, groupId: groupId),
  );
}

/// Partager une balade planifiée avec ses potes.
Future<void> shareRouteWithFriends(BuildContext context, PlannedRoute route) async {
  if (!await _ready(context) || !context.mounted) return;
  final container = ProviderScope.containerOf(context, listen: false);
  try {
    final synced = await container.read(socialActionsProvider).shareRoute(route);
    if (context.mounted) {
      showCmSnack(context, synced ? 'Balade « ${route.name} » partagée avec tes potes' : 'Partage en file, envoi dès que le réseau revient');
    }
  } on SocialException catch (e) {
    if (context.mounted) showCmSnack(context, e.message, error: true);
  }
}

/// Partager une balade enregistrée (tracé + stats) avec ses potes.
Future<void> shareRideWithFriends(BuildContext context, Ride ride) async {
  if (!await _ready(context) || !context.mounted) return;
  final container = ProviderScope.containerOf(context, listen: false);
  try {
    final synced = await container.read(socialActionsProvider).shareRide(ride);
    if (!ride.sharedWithFriends) {
      try {
        await container.read(rideRepositoryProvider).upsert(ride.copyWith(sharedWithFriends: true));
      } catch (_) {}
    }
    if (context.mounted) {
      showCmSnack(context, synced ? 'Balade partagée dans le fil de tes potes' : 'Partage en file, envoi dès que le réseau revient');
    }
  } on SocialException catch (e) {
    if (context.mounted) showCmSnack(context, e.message, error: true);
  }
}

// ===========================================================================
// Extras utilisables par les autres écrans
// ===========================================================================

/// Détail d'un signalement (avec suppression si c'est le mien).
Future<void> showReportDetailsSheet(BuildContext context, RoadReport report) {
  return showModalBottomSheet<void>(
    context: context,
    builder: (_) => _ReportDetails(report: report),
  );
}

/// Fiche d'un pote : statut, distance, voir sur la carte, retirer.
Future<void> showFriendSheet(BuildContext context, String friendUid) {
  return showModalBottomSheet<void>(
    context: context,
    builder: (_) => _FriendSheet(uid: friendUid),
  );
}

/// Saisie d'un code ami.
Future<void> showAddFriendDialog(BuildContext context) async {
  if (!await _ready(context) || !context.mounted) return;
  final container = ProviderScope.containerOf(context, listen: false);
  final code = await _codeDialog(
    context,
    title: 'Ajouter un pote',
    message: 'Demande-lui son code ami : il est affiché en haut de son onglet Potes.',
    hint: 'K7PM2X',
    maxLength: 7,
    confirm: 'Ajouter',
  );
  if (code == null || !context.mounted) return;
  try {
    final before = container.read(friendIdsProvider).value ?? const <String>[];
    final uid = await container.read(socialActionsProvider).addFriend(code);
    final profile = await container.read(socialApiProvider)?.fetchProfile(uid).catchError((_) => null);
    final name = profile?.name ?? 'Ce pote';
    if (context.mounted) {
      showCmSnack(
        context,
        before.contains(uid) ? '$name est déjà dans tes potes.' : '$name fait maintenant partie de tes potes !',
      );
    }
  } on SocialException catch (e) {
    if (context.mounted) showCmSnack(context, e.message, error: true);
  }
}

/// Création d'un groupe puis ouverture de son écran.
Future<void> showCreateGroupDialog(BuildContext context) async {
  if (!await _ready(context) || !context.mounted) return;
  final container = ProviderScope.containerOf(context, listen: false);
  final name = await promptText(
    context,
    title: 'Nouveau groupe',
    label: 'Nom du groupe',
    hint: 'ex : Les Virolos du dimanche',
    confirm: 'Créer',
  );
  if (name == null || !context.mounted) return;
  if (name.trim().length < 2) {
    showCmSnack(context, 'Donne un nom d\'au moins 2 caractères à ton groupe.', error: true);
    return;
  }
  try {
    final gid = await container.read(socialActionsProvider).createGroup(name);
    if (context.mounted) await Navigator.of(context).push(GroupScreen.route(gid));
  } on SocialException catch (e) {
    if (context.mounted) showCmSnack(context, e.message, error: true);
  }
}

/// Rejoindre un groupe avec son code.
Future<void> showJoinGroupDialog(BuildContext context) async {
  if (!await _ready(context) || !context.mounted) return;
  final container = ProviderScope.containerOf(context, listen: false);
  final code = await _codeDialog(
    context,
    title: 'Rejoindre un groupe',
    message: 'Entre le code partagé par un membre. Tu deviendras pote avec tout le groupe '
        'pour vous voir sur la carte pendant les balades.',
    hint: 'ABCD-EFGH',
    maxLength: 11,
    confirm: 'Rejoindre',
  );
  if (code == null || !context.mounted) return;
  try {
    final g = await container.read(socialActionsProvider).joinGroup(code);
    if (context.mounted) {
      showCmSnack(context, 'Bienvenue dans « ${g.name} » !');
      await Navigator.of(context).push(GroupScreen.route(g.id));
    }
  } on SocialException catch (e) {
    if (context.mounted) showCmSnack(context, e.message, error: true);
  }
}

// ===========================================================================
// Implémentation
// ===========================================================================

/// Vérifie que le module est utilisable ; sinon explique pourquoi.
Future<bool> _ready(BuildContext context) async {
  final container = ProviderScope.containerOf(context, listen: false);
  if (container.read(socialApiProvider) == null) {
    _showNotReady(
      context,
      icon: Icons.cloud_off_rounded,
      title: 'Mode solo',
      message: 'Les fonctions entre potes ne sont pas configurées dans cette version de l\'app.',
    );
    return false;
  }
  var profile = container.read(myProfileProvider).value;
  if (profile == null && container.read(myUidProvider) != null) {
    // Profil pas encore chargé (démarrage de l'app) : on l'attend un peu.
    final sub = container.listen(myProfileProvider, (_, _) {});
    try {
      profile = await container.read(myProfileProvider.future).timeout(const Duration(seconds: 5));
    } catch (_) {
      profile = null;
    } finally {
      sub.close();
    }
  }
  if (!context.mounted) return false;
  if (container.read(myUidProvider) == null || profile == null) {
    _showNotReady(
      context,
      icon: Icons.groups_rounded,
      title: 'Connecte-toi d\'abord',
      message: 'Crée ton compte ou connecte-toi dans l\'onglet Potes pour prévenir la bande.',
      goToFriends: true,
    );
    return false;
  }
  return true;
}

void _showNotReady(
  BuildContext context, {
  required IconData icon,
  required String title,
  required String message,
  bool goToFriends = false,
}) {
  showModalBottomSheet<void>(
    context: context,
    builder: (ctx) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(CmSpacing.xl, 0, CmSpacing.xl, CmSpacing.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SheetTitle(icon: icon, title: title, subtitle: message),
            if (goToFriends) ...[
              const SizedBox(height: CmSpacing.xl),
              Consumer(
                builder: (ctx, ref, _) => FilledButton(
                  onPressed: () {
                    Navigator.of(ctx).popUntil((r) => r.isFirst);
                    ref.read(homeTabProvider.notifier).select(HomeTabs.friends);
                  },
                  child: const Text('Aller à l\'onglet Potes'),
                ),
              ),
            ],
          ],
        ),
      ),
    ),
  );
}

Future<String?> _codeDialog(
  BuildContext context, {
  required String title,
  required String message,
  required String hint,
  required int maxLength,
  required String confirm,
}) async {
  final ctrl = TextEditingController();
  final res = await showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(message),
          const SizedBox(height: CmSpacing.lg),
          TextField(
            controller: ctrl,
            autofocus: true,
            maxLength: maxLength,
            textCapitalization: TextCapitalization.characters,
            autocorrect: false,
            enableSuggestions: false,
            textAlign: TextAlign.center,
            style: CmTheme.numbers(size: 32, color: CmColors.orange).copyWith(letterSpacing: 6),
            decoration: InputDecoration(hintText: hint, counterText: ''),
            onSubmitted: (v) => Navigator.pop(ctx, v),
          ),
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Annuler')),
        FilledButton(onPressed: () => Navigator.pop(ctx, ctrl.text), child: Text(confirm)),
      ],
    ),
  );
  ctrl.dispose();
  return (res == null || res.trim().isEmpty) ? null : res;
}

// ---------------------------------------------------------------------------
// Signalement
// ---------------------------------------------------------------------------

class _ReportSheet extends ConsumerStatefulWidget {
  const _ReportSheet({required this.at});

  final GeoPoint at;

  @override
  ConsumerState<_ReportSheet> createState() => _ReportSheetState();
}

class _ReportSheetState extends ConsumerState<_ReportSheet> {
  ReportType? _type;
  Duration? _lifetime;
  final _comment = TextEditingController();
  bool _busy = false;

  @override
  void dispose() {
    _comment.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final type = _type;
    if (type == null) return;
    setState(() => _busy = true);
    try {
      final synced = await ref.read(socialActionsProvider).addReport(
            type: type,
            at: widget.at,
            comment: _comment.text,
            lifetime: _lifetime ?? defaultReportLifetime(type),
          );
      if (!mounted) return;
      Navigator.pop(context);
      showCmSnack(context, synced ? '${type.label} signalé à tes potes. Merci !' : 'Signalement en file, envoi dès que le réseau revient');
    } on SocialException catch (e) {
      if (mounted) showCmSnack(context, e.message, error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final type = _type;
    final me = ref.watch(myPositionProvider);
    final dist = me == null ? null : Geo.distance(me, widget.at);
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(CmSpacing.lg, 0, CmSpacing.lg, CmSpacing.lg),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: CmSpacing.xs),
                child: SheetTitle(
                  icon: Icons.campaign_rounded,
                  title: 'Signaler',
                  subtitle: dist != null && dist > 150
                      ? 'À ${Fmt.distance(dist)} de toi · visible par tes potes'
                      : 'Ici · visible sur la carte de tes potes',
                ),
              ),
              const SizedBox(height: CmSpacing.lg),
              GridView.count(
                crossAxisCount: 3,
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                mainAxisSpacing: CmSpacing.sm,
                crossAxisSpacing: CmSpacing.sm,
                childAspectRatio: 1.05,
                children: [
                  for (final rt in ReportType.values)
                    _ReportTypeTile(
                      type: rt,
                      selected: rt == type,
                      onTap: () => setState(() {
                        _type = rt;
                        _lifetime = defaultReportLifetime(rt);
                      }),
                    ),
                ],
              ),
              AnimatedSize(
                duration: const Duration(milliseconds: 220),
                curve: Curves.easeOutCubic,
                child: type == null
                    ? const SizedBox(width: double.infinity)
                    : Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          const SizedBox(height: CmSpacing.lg),
                          TextField(
                            controller: _comment,
                            maxLength: 120,
                            textCapitalization: TextCapitalization.sentences,
                            decoration: InputDecoration(
                              hintText: switch (type) {
                                ReportType.gravillons => 'ex : plein de gravillons sortie de virage',
                                ReportType.police => 'ex : jumelles au rond-point',
                                ReportType.superSpot => 'ex : vue de dingue, parking pour les motos',
                                _ => 'Précise si besoin (facultatif)',
                              },
                              prefixIcon: const Icon(Icons.chat_bubble_outline_rounded),
                              counterText: '',
                            ),
                          ),
                          const SizedBox(height: CmSpacing.md),
                          Text('Visible pendant', style: t.labelLarge?.copyWith(color: scheme.onSurfaceVariant)),
                          const SizedBox(height: CmSpacing.xs),
                          Wrap(
                            spacing: 6,
                            runSpacing: 6,
                            children: [
                              for (final d in reportLifetimeChoices)
                                ChoiceChip(
                                  label: Text(lifetimeLabel(d)),
                                  selected: _lifetime == d,
                                  showCheckmark: false,
                                  selectedColor: type.color.withValues(alpha: 0.25),
                                  onSelected: (_) => setState(() => _lifetime = d),
                                ),
                            ],
                          ),
                          const SizedBox(height: CmSpacing.lg),
                          BusyButton(
                            label: 'Signaler « ${type.label} »',
                            busy: _busy,
                            color: type.color,
                            onPressed: _send,
                          ),
                        ],
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ReportTypeTile extends StatelessWidget {
  const _ReportTypeTile({required this.type, required this.selected, required this.onTap});

  final ReportType type;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 160),
      decoration: BoxDecoration(
        color: selected ? type.color.withValues(alpha: 0.18) : scheme.surfaceContainer,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: selected ? type.color : Colors.transparent, width: 2),
      ),
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          borderRadius: BorderRadius.circular(18),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(CmSpacing.sm),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Container(
                  width: 46,
                  height: 46,
                  decoration: BoxDecoration(
                    color: type.color,
                    shape: BoxShape.circle,
                    boxShadow: [BoxShadow(color: type.color.withValues(alpha: 0.45), blurRadius: 12)],
                  ),
                  child: Icon(type.icon, color: Colors.white, size: 24),
                ),
                const SizedBox(height: CmSpacing.sm),
                Text(
                  type.label,
                  textAlign: TextAlign.center,
                  maxLines: 2,
                  style: Theme.of(context).textTheme.labelMedium?.copyWith(fontWeight: FontWeight.w800, height: 1.1),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ReportDetails extends ConsumerWidget {
  const _ReportDetails({required this.report});

  final RoadReport report;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final r = report;
    final mine = ref.watch(myUidProvider) == r.authorUid;
    final me = ref.watch(myPositionProvider);
    final t = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(CmSpacing.xl, 0, CmSpacing.xl, CmSpacing.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SheetTitle(
              icon: r.type.icon,
              color: r.type.color,
              title: r.type.label,
              subtitle: '${mine ? 'Signalé par toi' : 'Signalé par ${r.authorName}'} ${Fmt.ago(r.createdAt)}',
            ),
            if (r.comment.isNotEmpty) ...[
              const SizedBox(height: CmSpacing.lg),
              Text('« ${r.comment} »', style: t.titleMedium?.copyWith(fontStyle: FontStyle.italic)),
            ],
            const SizedBox(height: CmSpacing.md),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                if (me != null) SocialPill(label: 'à ${Fmt.distance(Geo.distance(me, r.location))}', icon: Icons.near_me_rounded, color: CmColors.sky),
                if (r.expiresAt != null)
                  SocialPill(
                    label: 'Disparaît ${_until(r.expiresAt!)}',
                    icon: Icons.timer_outlined,
                    color: scheme.onSurfaceVariant,
                  ),
              ],
            ),
            if (mine) ...[
              const SizedBox(height: CmSpacing.xl),
              OutlinedButton.icon(
                style: OutlinedButton.styleFrom(foregroundColor: CmColors.red),
                onPressed: () async {
                  try {
                    await ref.read(socialActionsProvider).deleteReport(r.id);
                    if (context.mounted) {
                      Navigator.pop(context);
                      showCmSnack(context, 'Signalement retiré');
                    }
                  } on SocialException catch (e) {
                    if (context.mounted) showCmSnack(context, e.message, error: true);
                  }
                },
                icon: const Icon(Icons.delete_outline_rounded),
                label: const Text('Retirer mon signalement'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// « dans 2 h », « dans 3 j ».
String _until(DateTime at) {
  final d = at.toUtc().difference(DateTime.now().toUtc());
  if (d.isNegative) return 'bientôt';
  if (d.inMinutes < 60) return 'dans ${d.inMinutes} min';
  if (d.inHours < 48) return 'dans ${d.inHours} h';
  return 'dans ${d.inDays} j';
}

// ---------------------------------------------------------------------------
// Fiche pote
// ---------------------------------------------------------------------------

class _FriendSheet extends ConsumerWidget {
  const _FriendSheet({required this.uid});

  final String uid;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final friend = ref.watch(friendsProvider).where((f) => f.uid == uid).firstOrNull;
    final t = Theme.of(context).textTheme;
    if (friend == null) {
      return const SafeArea(child: Padding(padding: EdgeInsets.all(CmSpacing.xl), child: Text('Ce pote n\'est plus dans ta liste.')));
    }
    final me = ref.watch(myPositionProvider);
    final status = FriendStatus.of(friend, me: me);
    final live = friend.recentLive();
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(CmSpacing.xl, 0, CmSpacing.xl, CmSpacing.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                RiderAvatar(name: friend.name, color: friend.color, size: 64, riding: friend.isRiding(), sos: friend.isSos()),
                const SizedBox(width: CmSpacing.lg),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(friend.name, style: t.headlineSmall),
                      if (friend.bike != null)
                        Text(friend.bike!, style: t.bodyMedium?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant)),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: CmSpacing.lg),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                SocialPill(label: status.label, icon: status.icon, color: status.color),
                if (status.distance != null) SocialPill(label: status.distance!, icon: Icons.near_me_rounded, color: CmColors.sky),
              ],
            ),
            if (live?.sos == true && (live?.sosMessage?.isNotEmpty ?? false)) ...[
              const SizedBox(height: CmSpacing.md),
              Text(live!.sosMessage!, style: t.bodyMedium?.copyWith(color: CmColors.red, fontWeight: FontWeight.w700)),
            ],
            const SizedBox(height: CmSpacing.xl),
            if (live != null)
              FilledButton.icon(
                onPressed: () => showOnMap(context, ref, live.location),
                icon: const Icon(Icons.map_rounded),
                label: const Text('Voir sur la carte'),
              ),
            const SizedBox(height: CmSpacing.sm),
            TextButton(
              style: TextButton.styleFrom(foregroundColor: CmColors.red),
              onPressed: () async {
                final ok = await confirmAction(
                  context,
                  title: 'Retirer ${friend.name} ?',
                  message: 'Vous ne vous verrez plus sur la carte. Tu pourras le rajouter avec son code ami.',
                  confirm: 'Retirer',
                );
                if (!ok) return;
                try {
                  await ref.read(socialActionsProvider).removeFriend(uid);
                  if (context.mounted) Navigator.pop(context);
                } on SocialException catch (e) {
                  if (context.mounted) showCmSnack(context, e.message, error: true);
                }
              },
              child: const Text('Retirer de mes potes'),
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Lien de suivi web
// ---------------------------------------------------------------------------

class _ShareLocationSheet extends ConsumerStatefulWidget {
  const _ShareLocationSheet();

  @override
  ConsumerState<_ShareLocationSheet> createState() => _ShareLocationSheetState();
}

class _ShareLocationSheetState extends ConsumerState<_ShareLocationSheet> {
  static const _durations = [Duration(hours: 1), Duration(hours: 4), Duration(hours: 12)];
  Duration _duration = const Duration(hours: 4);
  bool _busy = false;

  String? _url(String token) => SocialCodes.shareUrl(
        viewerUrl: AppConfig.shareViewerUrl,
        databaseUrl: AppConfig.firebaseDatabaseUrl,
        token: token,
      );

  Future<void> _send(String url) =>
      SharePlus.instance.share(ShareParams(text: 'Suis ma balade en direct : $url', subject: 'Ma balade moto en direct'));

  Future<void> _create() async {
    setState(() => _busy = true);
    try {
      final token = await ref.read(socialActionsProvider).createShare(_duration);
      final url = _url(token);
      if (url != null) await _send(url);
    } on SocialException catch (e) {
      if (mounted) showCmSnack(context, e.message, error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final deployed = AppConfig.shareViewerUrl.trim().isNotEmpty;
    final shares = (ref.watch(mySharesProvider).value ?? const <LiveShare>[]).where((s) => s.isActive()).toList();
    final sharingLive = ref.watch(liveSyncProvider.select((s) => s.sharingWithFriends));

    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(CmSpacing.xl, 0, CmSpacing.xl, CmSpacing.xl),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SheetTitle(
              icon: Icons.share_location_rounded,
              title: 'Lien de suivi en direct',
              subtitle: 'Pour qu\'un proche suive ta balade, sans installer l\'app.',
              color: CmColors.sky,
            ),
            const SizedBox(height: CmSpacing.lg),
            if (!deployed)
              SocialCard(
                color: CmColors.amber.withValues(alpha: 0.12),
                border: Border.all(color: CmColors.amber.withValues(alpha: 0.5)),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Icon(Icons.construction_rounded, color: CmColors.amber),
                    const SizedBox(width: CmSpacing.md),
                    Expanded(
                      child: Text(
                        'La page de suivi n\'est pas encore en ligne. Déploie web_share/live.html '
                        '(Firebase Hosting, gratuit) puis recompile l\'app avec SHARE_VIEWER_URL. '
                        'Tout est expliqué dans firebase/README.md.',
                        style: t.bodyMedium,
                      ),
                    ),
                  ],
                ),
              ),
            for (final s in shares) ...[
              SocialCard(
                color: CmColors.sky.withValues(alpha: 0.12),
                padding: const EdgeInsets.fromLTRB(CmSpacing.lg, CmSpacing.md, CmSpacing.sm, CmSpacing.md),
                child: Row(
                  children: [
                    const _LiveDot(),
                    const SizedBox(width: CmSpacing.md),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('Lien actif', style: t.titleSmall?.copyWith(fontWeight: FontWeight.w800)),
                          Text('Expire dans ${Fmt.duration(s.remaining())} (${Fmt.time(s.expiresAt)})',
                              style: t.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
                        ],
                      ),
                    ),
                    if (_url(s.token) != null)
                      IconButton(
                        tooltip: 'Partager à nouveau',
                        icon: const Icon(Icons.ios_share_rounded),
                        onPressed: () => _send(_url(s.token)!),
                      ),
                    TextButton(
                      style: TextButton.styleFrom(foregroundColor: CmColors.red),
                      onPressed: () async {
                        try {
                          await ref.read(socialActionsProvider).stopShare(s.token);
                          if (context.mounted) showCmSnack(context, 'Partage arrêté : le lien ne montre plus ta position.');
                        } on SocialException catch (e) {
                          if (context.mounted) showCmSnack(context, e.message, error: true);
                        }
                      },
                      child: const Text('Arrêter'),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: CmSpacing.sm),
            ],
            const SizedBox(height: CmSpacing.md),
            Text(shares.isEmpty ? 'Durée du partage' : 'Nouveau lien', style: t.titleSmall?.copyWith(fontWeight: FontWeight.w800)),
            const SizedBox(height: CmSpacing.sm),
            SegmentedButton<Duration>(
              segments: [
                for (final d in _durations) ButtonSegment(value: d, label: Text(lifetimeLabel(d))),
              ],
              selected: {_duration},
              onSelectionChanged: (s) => setState(() => _duration = s.first),
            ),
            const SizedBox(height: CmSpacing.md),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.info_outline_rounded, size: 18, color: scheme.onSurfaceVariant),
                const SizedBox(width: CmSpacing.sm),
                Expanded(
                  child: Text(
                    'Ta position est mise à jour pendant la balade, toutes les 5 secondes environ. '
                    'Le lien s\'arrête tout seul à la fin de la durée choisie.'
                    '${sharingLive ? '' : ' Lance une balade pour que la position suive.'}',
                    style: t.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                  ),
                ),
              ],
            ),
            const SizedBox(height: CmSpacing.lg),
            BusyButton(
              label: 'Créer et partager le lien',
              icon: Icons.send_rounded,
              busy: _busy,
              color: CmColors.sky,
              onPressed: deployed ? _create : null,
            ),
          ],
        ),
      ),
    );
  }
}

class _LiveDot extends StatefulWidget {
  const _LiveDot();

  @override
  State<_LiveDot> createState() => _LiveDotState();
}

class _LiveDotState extends State<_LiveDot> with SingleTickerProviderStateMixin {
  late final _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 1400))..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 22,
      height: 22,
      child: AnimatedBuilder(
        animation: _c,
        builder: (context, _) => Stack(
          alignment: Alignment.center,
          children: [
            Container(
              width: 10 + 12 * _c.value,
              height: 10 + 12 * _c.value,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: CmColors.sky.withValues(alpha: 0.4 * (1 - _c.value)),
              ),
            ),
            Container(width: 10, height: 10, decoration: const BoxDecoration(shape: BoxShape.circle, color: CmColors.sky)),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Point de regroupement
// ---------------------------------------------------------------------------

class _RallySheet extends ConsumerStatefulWidget {
  const _RallySheet({required this.at, this.groupId});

  final GeoPoint at;
  final String? groupId;

  @override
  ConsumerState<_RallySheet> createState() => _RallySheetState();
}

class _RallySheetState extends ConsumerState<_RallySheet> {
  String? _gid;
  final _label = TextEditingController();
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _gid = widget.groupId;
  }

  @override
  void dispose() {
    _label.dispose();
    super.dispose();
  }

  Future<void> _save(String gid) async {
    setState(() => _busy = true);
    try {
      final synced = await ref.read(socialActionsProvider).setRally(gid, widget.at, _label.text);
      if (!mounted) return;
      Navigator.pop(context);
      showCmSnack(context, synced ? 'Point de regroupement fixé, la bande est prévenue' : 'Enregistré, envoi dès que le réseau revient');
    } on SocialException catch (e) {
      if (mounted) showCmSnack(context, e.message, error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final groups = ref.watch(myGroupsProvider);
    final me = ref.watch(myPositionProvider);
    final dist = me == null ? null : Geo.distance(me, widget.at);
    final gid = _gid ?? groups.firstOrNull?.id;
    final selected = groups.where((g) => g.id == gid).firstOrNull;

    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(CmSpacing.xl, 0, CmSpacing.xl, CmSpacing.xl),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SheetTitle(
                icon: Icons.flag_rounded,
                color: CmColors.sky,
                title: 'Point de regroupement',
                subtitle: dist == null ? 'On se retrouve ici' : 'À ${Fmt.distance(dist)} de toi',
              ),
              const SizedBox(height: CmSpacing.lg),
              if (groups.isEmpty) ...[
                Text(
                  'Il faut un groupe pour fixer un point de regroupement. Crée-en un ou rejoins celui de tes potes.',
                  style: t.bodyMedium,
                ),
                const SizedBox(height: CmSpacing.lg),
                FilledButton(
                  onPressed: () {
                    Navigator.of(context).popUntil((r) => r.isFirst);
                    ref.read(homeTabProvider.notifier).select(HomeTabs.friends);
                  },
                  child: const Text('Aller à l\'onglet Potes'),
                ),
              ] else ...[
                Text('Pour quel groupe ?', style: t.titleSmall?.copyWith(fontWeight: FontWeight.w800)),
                const SizedBox(height: CmSpacing.sm),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final g in groups)
                      ChoiceChip(
                        avatar: Icon(Icons.groups_rounded, size: 18, color: g.id == gid ? Colors.white : CmColors.sky),
                        label: Text(g.name),
                        selected: g.id == gid,
                        selectedColor: CmColors.sky,
                        labelStyle: TextStyle(color: g.id == gid ? Colors.white : null, fontWeight: FontWeight.w700),
                        showCheckmark: false,
                        onSelected: (_) => setState(() => _gid = g.id),
                      ),
                  ],
                ),
                const SizedBox(height: CmSpacing.lg),
                TextField(
                  controller: _label,
                  maxLength: 50,
                  textCapitalization: TextCapitalization.sentences,
                  decoration: const InputDecoration(
                    labelText: 'Nom du lieu',
                    hintText: 'ex : Parking du col de la Croix',
                    prefixIcon: Icon(Icons.place_outlined),
                    counterText: '',
                  ),
                ),
                if (selected?.rally != null) ...[
                  const SizedBox(height: CmSpacing.sm),
                  Text(
                    'Remplace « ${selected!.rally!.label} » fixé par ${selected.rally!.setBy}.',
                    style: t.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                  ),
                ],
                const SizedBox(height: CmSpacing.lg),
                BusyButton(
                  label: 'Fixer le regroupement',
                  icon: Icons.flag_rounded,
                  busy: _busy,
                  color: CmColors.sky,
                  onPressed: gid == null ? null : () => _save(gid),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Raccourci : ouvre l'édition de mon profil.
Future<void> showMyProfileEditor(BuildContext context) async {
  final container = ProviderScope.containerOf(context, listen: false);
  final me = container.read(myProfileProvider).value;
  if (me == null) return;
  await showEditProfileSheet(context, me);
}
