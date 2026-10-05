// Module « Potes » : écran principal de l'onglet (amis, groupes, partage, frais).
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:share_plus/share_plus.dart';

import '../../core/format.dart';
import '../../core/geo.dart';
import '../../core/settings.dart';
import '../../core/theme.dart';
import '../../core/ui/widgets.dart';
import '../../data/models/shared.dart';
import '../../services/social/social_api.dart';
import 'expenses.dart';
import 'social_models.dart';
import 'social_providers.dart';
import 'social_sheets.dart';
import 'ui/auth_screens.dart';
import 'ui/feed.dart';
import 'ui/group_screen.dart';
import 'ui/profile_editor.dart';
import 'ui/social_widgets.dart';

class SocialHomeScreen extends ConsumerWidget {
  const SocialHomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!ref.watch(socialAvailableProvider)) return const SoloModeView();
    final auth = ref.watch(authUserProvider);
    if (!auth.hasValue) return const _Loading();
    if (ref.watch(myUidProvider) == null) return const SocialWelcomeView();
    final profile = ref.watch(myProfileProvider);
    if (profile.isLoading) return const _Loading();
    final me = profile.value;
    if (me == null) return const ProfileSetupView();
    return _Dashboard(me: me);
  }
}

class _Loading extends StatelessWidget {
  const _Loading();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Potes')),
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(),
            const SizedBox(height: CmSpacing.lg),
            Text('On rassemble la bande…', style: Theme.of(context).textTheme.bodyMedium),
          ],
        ),
      ),
    );
  }
}

class _Dashboard extends ConsumerWidget {
  const _Dashboard({required this.me});

  final UserProfile me;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final friends = [...ref.watch(friendsProvider)];
    final groups = ref.watch(myGroupsProvider);
    final myReports = ref.watch(myReportsProvider);
    final feed = ref.watch(friendsFeedProvider);
    final myPos = ref.watch(myPositionProvider);
    final activeLinks = (ref.watch(mySharesProvider).value ?? const <LiveShare>[]).where((s) => s.isActive()).toList();
    final now = DateTime.now().toUtc();
    final ridingCount = friends.where((f) => f.isRiding(now: now)).length;

    friends.sort((a, b) {
      int rank(Friend f) => f.isSos(now: now) ? 0 : (f.isRiding(now: now) ? 1 : (f.recentLive(now: now) != null ? 2 : 3));
      final r = rank(a).compareTo(rank(b));
      if (r != 0) return r;
      final la = a.recentLive(now: now)?.updatedAt, lb = b.recentLive(now: now)?.updatedAt;
      if (la != null && lb != null && la != lb) return lb.compareTo(la);
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });

    return Scaffold(
      body: CustomScrollView(
        slivers: [
          SliverAppBar(
            floating: true,
            snap: true,
            title: const Text('Potes'),
            actions: [
              IconButton(
                tooltip: 'Lien de suivi en direct',
                icon: Badge(
                  isLabelVisible: activeLinks.isNotEmpty,
                  backgroundColor: CmColors.sky,
                  smallSize: 9,
                  child: const Icon(Icons.share_location_rounded),
                ),
                onPressed: () => showShareLocationSheet(context),
              ),
              PopupMenuButton<String>(
                onSelected: (v) async {
                  if (v == 'profile') {
                    await showEditProfileSheet(context, me);
                  } else if (v == 'logout') {
                    final ok = await confirmAction(
                      context,
                      title: 'Te déconnecter ?',
                      message: 'Tes potes ne te verront plus sur la carte jusqu\'à ta prochaine connexion.',
                      confirm: 'Déconnexion',
                    );
                    if (ok) await ref.read(socialActionsProvider).signOut();
                  }
                },
                itemBuilder: (_) => const [
                  PopupMenuItem(value: 'profile', child: ListTile(leading: Icon(Icons.edit_rounded), title: Text('Modifier mon profil'))),
                  PopupMenuItem(value: 'logout', child: ListTile(leading: Icon(Icons.logout_rounded), title: Text('Me déconnecter'))),
                ],
              ),
            ],
          ),
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(CmSpacing.lg, CmSpacing.xs, CmSpacing.lg, CmSpacing.xxl),
            sliver: SliverList.list(
              children: [
                _ProfileCard(me: me),
                const SizedBox(height: CmSpacing.md),
                const _QuickActions(),
                if (activeLinks.isNotEmpty) ...[
                  const SizedBox(height: CmSpacing.md),
                  _ActiveLinkBanner(share: activeLinks.first, count: activeLinks.length),
                ],
                // ------------------------------------------------- Potes
                SectionHeader(
                  friends.isEmpty
                      ? 'Mes potes'
                      : 'Mes potes · ${friends.length}${ridingCount > 0 ? '  ·  $ridingCount en balade' : ''}',
                  padding: const EdgeInsets.fromLTRB(CmSpacing.xs, CmSpacing.xl, 0, CmSpacing.sm),
                  action: TextButton.icon(
                    onPressed: () => showAddFriendDialog(context),
                    icon: const Icon(Icons.person_add_alt_1_rounded, size: 18),
                    label: const Text('Ajouter'),
                  ),
                ),
                if (friends.isEmpty)
                  _EmptyBlock(
                    icon: Icons.group_add_rounded,
                    title: 'Pas encore de potes ici',
                    message: 'Donne ton code ami à la bande, ou demande-leur le leur.',
                    actions: [
                      FilledButton.tonalIcon(
                        onPressed: () => showAddFriendDialog(context),
                        icon: const Icon(Icons.keyboard_rounded, size: 18),
                        label: const Text('J\'ai un code'),
                      ),
                      OutlinedButton.icon(
                        onPressed: () => _shareMyCode(me),
                        icon: const Icon(Icons.share_rounded, size: 18),
                        label: const Text('Donner le mien'),
                      ),
                    ],
                  )
                else
                  SocialCard(
                    padding: const EdgeInsets.symmetric(vertical: CmSpacing.xs),
                    child: Column(
                      children: [
                        for (final f in friends) _FriendTile(friend: f, me: myPos),
                      ],
                    ),
                  ),
                // ------------------------------------------------ Groupes
                SectionHeader(
                  'Groupes',
                  padding: const EdgeInsets.fromLTRB(CmSpacing.xs, CmSpacing.xl, 0, CmSpacing.sm),
                  action: groups.isEmpty
                      ? null
                      : Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            TextButton(onPressed: () => showJoinGroupDialog(context), child: const Text('Rejoindre')),
                            IconButton(
                              tooltip: 'Nouveau groupe',
                              onPressed: () => showCreateGroupDialog(context),
                              icon: const Icon(Icons.add_circle_outline_rounded),
                            ),
                          ],
                        ),
                ),
                if (groups.isEmpty)
                  _EmptyBlock(
                    icon: Icons.groups_rounded,
                    title: 'Roulez en groupe',
                    message: 'Point de regroupement, alerte si quelqu\'un décroche et frais partagés de la sortie.',
                    actions: [
                      FilledButton.tonalIcon(
                        onPressed: () => showCreateGroupDialog(context),
                        icon: const Icon(Icons.add_rounded, size: 18),
                        label: const Text('Créer'),
                      ),
                      OutlinedButton.icon(
                        onPressed: () => showJoinGroupDialog(context),
                        icon: const Icon(Icons.login_rounded, size: 18),
                        label: const Text('Rejoindre'),
                      ),
                    ],
                  )
                else
                  for (final g in groups) ...[
                    _GroupCard(group: g, myUid: me.uid),
                    const SizedBox(height: CmSpacing.sm),
                  ],
                // ------------------------------------- Mes signalements
                if (myReports.isNotEmpty) ...[
                  SectionHeader(
                    'Mes signalements',
                    padding: const EdgeInsets.fromLTRB(CmSpacing.xs, CmSpacing.xl, 0, CmSpacing.sm),
                  ),
                  SocialCard(
                    padding: const EdgeInsets.symmetric(vertical: CmSpacing.xs),
                    child: Column(
                      children: [for (final r in myReports) _MyReportTile(report: r, me: myPos)],
                    ),
                  ),
                ],
                // ---------------------------------------------------- Fil
                SectionHeader(
                  'Dernières balades des potes',
                  padding: const EdgeInsets.fromLTRB(CmSpacing.xs, CmSpacing.xl, 0, CmSpacing.sm),
                ),
                if (feed.isEmpty)
                  _EmptyBlock(
                    icon: Icons.route_rounded,
                    title: 'Rien dans le fil pour l\'instant',
                    message: 'Quand tes potes partagent une balade ou un itinéraire, ça apparaît ici. '
                        'Partage les tiennes depuis l\'historique ou l\'onglet Balades !',
                  )
                else
                  for (final item in feed) ...[
                    FeedCard(item: item),
                    const SizedBox(height: CmSpacing.md),
                  ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

Future<void> _shareMyCode(UserProfile me) => SharePlus.instance.share(ShareParams(
      text: 'Ajoute-moi sur Cono Moto pour qu\'on se voie sur la carte pendant les balades ! '
          'Onglet Potes › Ajouter, mon code ami : ${me.code}',
      subject: 'Mon code ami Cono Moto',
    ));

// ---------------------------------------------------------------------------
// Carte profil
// ---------------------------------------------------------------------------

class _ProfileCard extends ConsumerWidget {
  const _ProfileCard({required this.me});

  final UserProfile me;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final shareLive = ref.watch(settingsProvider.select((s) => s.shareLiveWithFriends));
    final liveNow = ref.watch(liveSyncProvider.select((s) => s.sharingWithFriends));
    return SocialCard(
      gradient: LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [me.color.withValues(alpha: 0.30), scheme.surfaceContainer, scheme.surfaceContainer],
        stops: const [0, 0.55, 1],
      ),
      border: Border.all(color: me.color.withValues(alpha: 0.25)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              GestureDetector(
                onTap: () => showEditProfileSheet(context, me),
                child: RiderAvatar(name: me.name, color: me.color, size: 62, riding: liveNow),
              ),
              const SizedBox(width: CmSpacing.lg),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(me.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: t.headlineSmall),
                    Row(
                      children: [
                        Icon(Icons.two_wheeler, size: 16, color: scheme.onSurfaceVariant),
                        const SizedBox(width: 4),
                        Flexible(
                          child: Text(
                            me.bike.isEmpty ? 'Moto non renseignée' : me.bike,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: t.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              IconButton(
                tooltip: 'Modifier mon profil',
                onPressed: () => showEditProfileSheet(context, me),
                icon: const Icon(Icons.edit_rounded),
              ),
            ],
          ),
          const SizedBox(height: CmSpacing.lg),
          Text('TON CODE AMI',
              style: t.labelSmall?.copyWith(color: scheme.onSurfaceVariant, fontWeight: FontWeight.w800, letterSpacing: 1)),
          const SizedBox(height: CmSpacing.sm),
          CodeTiles(code: me.code, color: me.color, tileSize: 40),
          const SizedBox(height: CmSpacing.md),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(minimumSize: const Size(0, 44)),
                  onPressed: () => copyToClipboard(context, me.code, message: 'Code ami copié'),
                  icon: const Icon(Icons.copy_rounded, size: 18),
                  label: const Text('Copier'),
                ),
              ),
              const SizedBox(width: CmSpacing.sm),
              Expanded(
                child: FilledButton.icon(
                  style: FilledButton.styleFrom(minimumSize: const Size(0, 44)),
                  onPressed: () => _shareMyCode(me),
                  icon: const Icon(Icons.share_rounded, size: 18),
                  label: const Text('Partager'),
                ),
              ),
            ],
          ),
          const SizedBox(height: CmSpacing.md),
          const Divider(),
          Padding(
            padding: const EdgeInsets.only(top: CmSpacing.sm),
            child: Row(
              children: [
                Icon(
                  liveNow ? Icons.sensors_rounded : Icons.sensors_off_rounded,
                  color: liveNow ? CmColors.green : (shareLive ? CmColors.teal : scheme.onSurfaceVariant),
                ),
                const SizedBox(width: CmSpacing.md),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Ma position pendant les balades', style: t.titleSmall?.copyWith(fontWeight: FontWeight.w700)),
                      Text(
                        liveNow
                            ? 'En direct : tes potes te voient en ce moment'
                            : (shareLive ? 'Partagée avec tes potes dès que tu roules' : 'Tu roules incognito'),
                        style: t.bodySmall?.copyWith(color: liveNow ? CmColors.green : scheme.onSurfaceVariant),
                      ),
                    ],
                  ),
                ),
                Switch(
                  value: shareLive,
                  onChanged: (v) => ref.read(settingsProvider.notifier).update((s) => s.copyWith(shareLiveWithFriends: v)),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _QuickActions extends StatelessWidget {
  const _QuickActions();

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: _ActionTile(
            icon: Icons.person_add_alt_1_rounded,
            label: 'Ajouter\nun pote',
            color: CmColors.orange,
            onTap: () => showAddFriendDialog(context),
          ),
        ),
        const SizedBox(width: CmSpacing.sm),
        Expanded(
          child: _ActionTile(
            icon: Icons.group_add_rounded,
            label: 'Nouveau\ngroupe',
            color: CmColors.teal,
            onTap: () => showCreateGroupDialog(context),
          ),
        ),
        const SizedBox(width: CmSpacing.sm),
        Expanded(
          child: _ActionTile(
            icon: Icons.share_location_rounded,
            label: 'Lien de\nsuivi',
            color: CmColors.sky,
            onTap: () => showShareLocationSheet(context),
          ),
        ),
      ],
    );
  }
}

class _ActionTile extends StatelessWidget {
  const _ActionTile({required this.icon, required this.label, required this.color, required this.onTap});

  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return SocialCard(
      onTap: onTap,
      padding: const EdgeInsets.symmetric(vertical: CmSpacing.md, horizontal: CmSpacing.sm),
      child: Column(
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(color: color.withValues(alpha: 0.16), shape: BoxShape.circle),
            child: Icon(icon, color: color),
          ),
          const SizedBox(height: CmSpacing.sm),
          Text(
            label,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.labelMedium?.copyWith(fontWeight: FontWeight.w800, height: 1.15),
          ),
        ],
      ),
    );
  }
}

class _ActiveLinkBanner extends StatelessWidget {
  const _ActiveLinkBanner({required this.share, required this.count});

  final LiveShare share;
  final int count;

  @override
  Widget build(BuildContext context) {
    return SocialCard(
      color: CmColors.sky.withValues(alpha: 0.14),
      border: Border.all(color: CmColors.sky.withValues(alpha: 0.4)),
      padding: const EdgeInsets.symmetric(horizontal: CmSpacing.lg, vertical: CmSpacing.md),
      onTap: () => showShareLocationSheet(context),
      child: Row(
        children: [
          const Icon(Icons.share_location_rounded, color: CmColors.sky),
          const SizedBox(width: CmSpacing.md),
          Expanded(
            child: Text(
              count > 1
                  ? '$count liens de suivi actifs'
                  : 'Ta position est partagée par lien · encore ${Fmt.duration(share.remaining())}',
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
          ),
          const Icon(Icons.chevron_right_rounded),
        ],
      ),
    );
  }
}

class _EmptyBlock extends StatelessWidget {
  const _EmptyBlock({required this.icon, required this.title, required this.message, this.actions = const []});

  final IconData icon;
  final String title;
  final String message;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return SocialCard(
      child: Column(
        children: [
          Container(
            width: 56,
            height: 56,
            decoration: BoxDecoration(color: CmColors.orange.withValues(alpha: 0.12), shape: BoxShape.circle),
            child: Icon(icon, color: CmColors.orange, size: 28),
          ),
          const SizedBox(height: CmSpacing.md),
          Text(title, textAlign: TextAlign.center, style: t.titleMedium?.copyWith(fontWeight: FontWeight.w800)),
          const SizedBox(height: 4),
          Text(
            message,
            textAlign: TextAlign.center,
            style: t.bodySmall?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
          ),
          if (actions.isNotEmpty) ...[
            const SizedBox(height: CmSpacing.lg),
            Wrap(spacing: CmSpacing.sm, runSpacing: CmSpacing.sm, alignment: WrapAlignment.center, children: actions),
          ],
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Lignes
// ---------------------------------------------------------------------------

class _FriendTile extends ConsumerWidget {
  const _FriendTile({required this.friend, required this.me});

  final Friend friend;
  final GeoPoint? me;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final f = friend;
    final status = FriendStatus.of(f, me: me);
    final live = f.recentLive();
    final sos = f.isSos();
    return ListTile(
      onTap: () => showFriendSheet(context, f.uid),
      tileColor: sos ? CmColors.red.withValues(alpha: 0.12) : null,
      leading: RiderAvatar(name: f.name, color: f.color, size: 46, riding: f.isRiding(), sos: sos),
      title: Row(
        children: [
          Flexible(
            child: Text(f.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w800)),
          ),
          if (f.bike != null) ...[
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                f.bike!,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
              ),
            ),
          ],
        ],
      ),
      subtitle: Text.rich(
        TextSpan(children: [
          TextSpan(
            text: status.label,
            style: TextStyle(color: status.color == Colors.grey ? null : status.color, fontWeight: FontWeight.w700),
          ),
          if (status.distance != null) TextSpan(text: ' · ${status.distance}'),
        ]),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: live == null
          ? const Icon(Icons.chevron_right_rounded)
          : IconButton(
              tooltip: 'Voir sur la carte',
              icon: Icon(Icons.map_rounded, color: sos ? CmColors.red : null),
              onPressed: () => showOnMap(context, ref, live.location),
            ),
    );
  }
}

class _GroupCard extends ConsumerWidget {
  const _GroupCard({required this.group, required this.myUid});

  final Group group;
  final String myUid;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final g = group;
    final t = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final friends = {for (final f in ref.watch(friendsProvider)) f.uid: f};
    final riding = g.members.where((m) => friends[m.uid]?.isRiding() ?? false).length;
    final balance = g.balances[myUid] ?? 0;
    final rallyFresh = g.rally != null && DateTime.now().toUtc().difference(g.rally!.setAt.toUtc()) < rallyMaxAge;
    final initial = g.name.trim().isEmpty ? '?' : g.name.trim()[0].toUpperCase();

    return SocialCard(
      onTap: () => Navigator.of(context).push(GroupScreen.route(g.id)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 48,
                height: 48,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(15),
                  gradient: const LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [CmColors.teal, CmColors.sky],
                  ),
                ),
                child: Text(initial, style: CmTheme.numbers(size: 26, color: Colors.white)),
              ),
              const SizedBox(width: CmSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(g.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: t.titleMedium?.copyWith(fontWeight: FontWeight.w800)),
                    Text(
                      '${g.members.length} membre${g.members.length > 1 ? 's' : ''}${riding > 0 ? ' · $riding en balade' : ''}',
                      style: t.bodySmall?.copyWith(color: riding > 0 ? CmColors.green : scheme.onSurfaceVariant),
                    ),
                  ],
                ),
              ),
              AvatarStack(people: [for (final m in g.members) (m.name, friends[m.uid]?.color ?? m.color)], size: 30, max: 4),
            ],
          ),
          if (rallyFresh || g.expenses.isNotEmpty) ...[
            const SizedBox(height: CmSpacing.md),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                if (rallyFresh) SocialPill(label: 'Regroupement : ${g.rally!.label}', icon: Icons.flag_rounded, color: CmColors.sky),
                if (g.expenses.isNotEmpty)
                  SocialPill(
                    label: balance == 0
                        ? 'Comptes à jour'
                        : (balance > 0
                            ? 'On te doit ${Fmt.euros(ExpenseMath.toEuros(balance))}'
                            : 'Tu dois ${Fmt.euros(ExpenseMath.toEuros(-balance))}'),
                    icon: Icons.payments_rounded,
                    color: balance == 0 ? CmColors.teal : (balance > 0 ? CmColors.green : CmColors.red),
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _MyReportTile extends ConsumerWidget {
  const _MyReportTile({required this.report, required this.me});

  final RoadReport report;
  final GeoPoint? me;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final r = report;
    final parts = <String>[
      Fmt.ago(r.createdAt),
      if (me != null) 'à ${Fmt.distance(Geo.distance(me!, r.location))}',
      if (r.expiresAt != null) 'jusqu\'au ${Fmt.dateTime(r.expiresAt!)}',
    ];
    return ListTile(
      onTap: () => showReportDetailsSheet(context, r),
      leading: Container(
        width: 42,
        height: 42,
        decoration: BoxDecoration(color: r.type.color, shape: BoxShape.circle),
        child: Icon(r.type.icon, color: Colors.white, size: 22),
      ),
      title: Text(
        r.comment.isEmpty ? r.type.label : '${r.type.label} · ${r.comment}',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontWeight: FontWeight.w700),
      ),
      subtitle: Text(parts.join(' · '), maxLines: 1, overflow: TextOverflow.ellipsis),
      trailing: IconButton(
        tooltip: 'Retirer',
        icon: const Icon(Icons.delete_outline_rounded),
        onPressed: () async {
          try {
            await ref.read(socialActionsProvider).deleteReport(r.id);
            if (context.mounted) showCmSnack(context, 'Signalement retiré');
          } on SocialException catch (e) {
            if (context.mounted) showCmSnack(context, e.message, error: true);
          }
        },
      ),
    );
  }
}
