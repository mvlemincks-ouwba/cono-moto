import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:share_plus/share_plus.dart';

import '../../../core/format.dart';
import '../../../core/geo.dart';
import '../../../core/location.dart';
import '../../../core/settings.dart';
import '../../../core/theme.dart';
import '../../../core/ui/widgets.dart';
import '../../../services/social/codes.dart';
import '../../../services/social/social_api.dart';
import '../expenses.dart';
import '../social_models.dart';
import '../social_providers.dart';
import '../social_sheets.dart';
import 'expenses_view.dart';
import 'social_widgets.dart';

/// Détail d'un groupe : équipe (membres, regroupement) et frais partagés.
class GroupScreen extends ConsumerWidget {
  const GroupScreen({super.key, required this.groupId, this.initialTab = 0});

  final String groupId;
  final int initialTab;

  static Route<void> route(String groupId, {int initialTab = 0}) =>
      MaterialPageRoute(builder: (_) => GroupScreen(groupId: groupId, initialTab: initialTab));

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(groupProvider(groupId));
    final me = ref.watch(myUidProvider);
    final g = async.value;
    if (g == null || me == null || !g.hasMember(me)) {
      return Scaffold(
        appBar: AppBar(),
        body: async.isLoading
            ? const Center(child: CircularProgressIndicator())
            : EmptyState(
                icon: Icons.group_off_rounded,
                title: 'Groupe introuvable',
                message: 'Il a peut-être été supprimé, ou tu n\'en fais plus partie.',
                action: FilledButton(onPressed: () => Navigator.pop(context), child: const Text('Retour')),
              ),
      );
    }
    return DefaultTabController(
      length: 2,
      initialIndex: initialTab,
      child: Scaffold(
        appBar: AppBar(
          title: Text(g.name, maxLines: 1, overflow: TextOverflow.ellipsis),
          actions: [
            IconButton(
              tooltip: 'Inviter',
              icon: const Icon(Icons.person_add_alt_1_rounded),
              onPressed: () => _shareInvite(context, g),
            ),
            PopupMenuButton<String>(
              onSelected: (v) => _menu(context, ref, g, me, v),
              itemBuilder: (_) => [
                const PopupMenuItem(value: 'rename', child: Text('Renommer')),
                const PopupMenuItem(value: 'leave', child: Text('Quitter le groupe')),
                if (g.createdBy == me) const PopupMenuItem(value: 'delete', child: Text('Supprimer le groupe')),
              ],
            ),
          ],
          bottom: TabBar(
            indicatorColor: CmColors.orange,
            labelColor: CmColors.orange,
            tabs: [
              const Tab(icon: Icon(Icons.groups_rounded), text: 'Équipe'),
              Tab(
                icon: const Icon(Icons.payments_rounded),
                text: g.expenses.isEmpty ? 'Frais' : 'Frais · ${Fmt.euros(ExpenseMath.toEuros(ExpenseMath.total(g.expenses)))}',
              ),
            ],
          ),
        ),
        body: TabBarView(
          children: [
            _TeamTab(group: g),
            ExpensesView(group: g),
          ],
        ),
      ),
    );
  }

  static String inviteText(Group g) =>
      'Rejoins le groupe « ${g.name} » sur Cono Moto ! Onglet Potes › Rejoindre un groupe, '
      'code : ${SocialCodes.formatGroupCode(g.id)}';

  static Future<void> _shareInvite(BuildContext context, Group g) async {
    await SharePlus.instance.share(ShareParams(text: inviteText(g), subject: 'Groupe ${g.name} sur Cono Moto'));
  }

  Future<void> _menu(BuildContext context, WidgetRef ref, Group g, String me, String action) async {
    final actions = ref.read(socialActionsProvider);
    try {
      switch (action) {
        case 'rename':
          final name = await promptText(context, title: 'Renommer le groupe', initial: g.name, label: 'Nom du groupe');
          if (name != null && name.trim().length >= 2) await actions.renameGroup(g.id, name);
        case 'leave':
          final balance = g.balances[me] ?? 0;
          final ok = await confirmAction(
            context,
            title: 'Quitter « ${g.name} » ?',
            message: balance != 0
                ? 'Attention, tes comptes ne sont pas soldés (${balance > 0 ? '+' : ''}${Fmt.euros(ExpenseMath.toEuros(balance))}). '
                    'Tu pourras revenir avec le code du groupe.'
                : 'Tu pourras revenir avec le code du groupe.',
            confirm: 'Quitter',
          );
          if (!ok) return;
          await actions.leaveGroup(g.id);
          if (context.mounted) Navigator.pop(context);
        case 'delete':
          final ok = await confirmAction(
            context,
            title: 'Supprimer « ${g.name} » ?',
            message: 'Le groupe, son point de regroupement et toutes ses dépenses seront supprimés pour tout le monde.',
            confirm: 'Supprimer',
          );
          if (!ok) return;
          await actions.deleteGroup(g.id);
          if (context.mounted) Navigator.pop(context);
      }
    } on SocialException catch (e) {
      if (context.mounted) showCmSnack(context, e.message, error: true);
    }
  }
}

/// Petite boîte de saisie de texte.
Future<String?> promptText(
  BuildContext context, {
  required String title,
  required String label,
  String initial = '',
  String? hint,
  String confirm = 'OK',
  TextCapitalization capitalization = TextCapitalization.sentences,
  int maxLength = 40,
}) async {
  final ctrl = TextEditingController(text: initial);
  final res = await showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: TextField(
        controller: ctrl,
        autofocus: true,
        maxLength: maxLength,
        textCapitalization: capitalization,
        decoration: InputDecoration(labelText: label, hintText: hint, counterText: ''),
        onSubmitted: (v) => Navigator.pop(ctx, v),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Annuler')),
        FilledButton(onPressed: () => Navigator.pop(ctx, ctrl.text), child: Text(confirm)),
      ],
    ),
  );
  ctrl.dispose();
  return res;
}

class _TeamTab extends ConsumerWidget {
  const _TeamTab({required this.group});

  final Group group;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final g = group;
    final me = ref.watch(myUidProvider);
    final myPos = ref.watch(myPositionProvider);
    final friends = {for (final f in ref.watch(friendsProvider)) f.uid: f};
    final t = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final ridingCount = g.members.where((m) => friends[m.uid]?.isRiding() ?? false).length;

    return ListView(
      padding: const EdgeInsets.fromLTRB(CmSpacing.lg, CmSpacing.lg, CmSpacing.lg, CmSpacing.xxl),
      children: [
        // ------------------------------------------------------ Invitation
        SocialCard(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [CmColors.orange.withValues(alpha: 0.22), scheme.surfaceContainer],
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text('Code d\'invitation', style: t.labelLarge?.copyWith(color: scheme.onSurfaceVariant)),
                  ),
                  SocialPill(
                    label: ridingCount > 0 ? '$ridingCount en balade' : '${g.members.length} membre${g.members.length > 1 ? 's' : ''}',
                    icon: ridingCount > 0 ? Icons.two_wheeler : Icons.groups_rounded,
                    color: ridingCount > 0 ? CmColors.green : CmColors.orange,
                  ),
                ],
              ),
              const SizedBox(height: CmSpacing.sm),
              CodeTiles(code: SocialCodes.formatGroupCode(g.id), tileSize: 30),
              const SizedBox(height: CmSpacing.md),
              Wrap(
                spacing: CmSpacing.xs,
                children: [
                  TextButton.icon(
                    onPressed: () => copyToClipboard(context, SocialCodes.formatGroupCode(g.id), message: 'Code copié'),
                    icon: const Icon(Icons.copy_rounded, size: 18),
                    label: const Text('Copier'),
                  ),
                  TextButton.icon(
                    onPressed: () => GroupScreen._shareInvite(context, g),
                    icon: const Icon(Icons.share_rounded, size: 18),
                    label: const Text('Partager'),
                  ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: CmSpacing.md),
        _RallyCard(group: g, myPos: myPos),
        SectionHeader(
          'Membres · ${g.members.length}',
          padding: const EdgeInsets.fromLTRB(CmSpacing.xs, CmSpacing.xl, 0, CmSpacing.sm),
        ),
        SocialCard(
          padding: const EdgeInsets.symmetric(vertical: CmSpacing.xs),
          child: Column(
            children: [
              for (final m in g.members) _MemberTile(member: m, friend: friends[m.uid], isMe: m.uid == me, myPos: myPos),
            ],
          ),
        ),
        const SizedBox(height: CmSpacing.md),
        Text(
          'Pendant la balade, tu es prévenu si un membre qui roule se retrouve à plus de '
          '${_km(ref.watch(settingsProvider.select((s) => s.stragglerAlertKm)))} km de toi (réglable dans les réglages).',
          style: t.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
        ),
      ],
    );
  }
}

String _km(double km) => Fmt.number(km, decimals: km % 1 == 0 ? 0 : 1);

class _MemberTile extends ConsumerWidget {
  const _MemberTile({required this.member, required this.friend, required this.isMe, required this.myPos});

  final GroupMember member;
  final Friend? friend;
  final bool isMe;
  final GeoPoint? myPos;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final f = friend;
    final status = f == null ? null : FriendStatus.of(f, me: myPos);
    final live = f?.recentLive();
    return ListTile(
      onTap: live == null ? null : () => showOnMap(context, ref, live.location),
      leading: RiderAvatar(
        name: member.name,
        color: f?.color ?? member.color,
        size: 42,
        riding: f?.isRiding() ?? false,
        sos: f?.isSos() ?? false,
      ),
      title: Text(isMe ? '${member.name} (toi)' : member.name, style: const TextStyle(fontWeight: FontWeight.w700)),
      subtitle: isMe
          ? const Text('C\'est toi !')
          : status == null
              ? const Text('Position pas encore partagée')
              : Text(
                  [status.label, ?status.distance].join(' · '),
                  style: TextStyle(color: status.color == Colors.grey ? null : status.color, fontWeight: FontWeight.w600),
                ),
      trailing: live == null || isMe
          ? null
          : IconButton(
              tooltip: 'Voir sur la carte',
              icon: const Icon(Icons.map_rounded),
              onPressed: () => showOnMap(context, ref, live.location),
            ),
    );
  }
}

class _RallyCard extends ConsumerWidget {
  const _RallyCard({required this.group, required this.myPos});

  final Group group;
  final GeoPoint? myPos;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final r = group.rally;
    if (r == null) {
      return SocialCard(
        child: Row(
          children: [
            Container(
              width: 46,
              height: 46,
              decoration: BoxDecoration(color: CmColors.sky.withValues(alpha: 0.15), borderRadius: BorderRadius.circular(14)),
              child: const Icon(Icons.flag_outlined, color: CmColors.sky),
            ),
            const SizedBox(width: CmSpacing.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Pas de point de regroupement', style: t.titleSmall?.copyWith(fontWeight: FontWeight.w800)),
                  Text(
                    'Fixe-le ici, ou par un appui long sur la carte.',
                    style: t.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                  ),
                ],
              ),
            ),
            const SizedBox(width: CmSpacing.sm),
            FilledButton.tonal(
              onPressed: () => _setHere(context, ref),
              style: FilledButton.styleFrom(minimumSize: const Size(0, 44)),
              child: const Text('Ici'),
            ),
          ],
        ),
      );
    }
    final dist = myPos == null ? null : Geo.distance(myPos!, r.location);
    final expired = DateTime.now().toUtc().difference(r.setAt.toUtc()) >= rallyMaxAge;
    return SocialCard(
      border: Border.all(color: CmColors.sky.withValues(alpha: 0.4)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 46,
                height: 46,
                decoration: BoxDecoration(color: CmColors.sky, borderRadius: BorderRadius.circular(14)),
                child: const Icon(Icons.flag_rounded, color: Colors.white),
              ),
              const SizedBox(width: CmSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('POINT DE REGROUPEMENT',
                        style: t.labelSmall?.copyWith(color: CmColors.sky, fontWeight: FontWeight.w800, letterSpacing: 0.8)),
                    Text(r.label, style: t.titleMedium?.copyWith(fontWeight: FontWeight.w800)),
                    Text(
                      'Fixé par ${r.setBy} ${Fmt.ago(r.setAt)}${dist != null ? ' · à ${Fmt.distance(dist)}' : ''}',
                      style: t.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                    ),
                  ],
                ),
              ),
            ],
          ),
          if (expired) ...[
            const SizedBox(height: CmSpacing.sm),
            Text('Fixé il y a plus de 3 jours : il n\'apparaît plus sur la carte.',
                style: t.bodySmall?.copyWith(color: CmColors.amber)),
          ],
          const SizedBox(height: CmSpacing.md),
          Row(
            children: [
              Expanded(
                child: FilledButton.icon(
                  style: FilledButton.styleFrom(backgroundColor: CmColors.sky, minimumSize: const Size(0, 44)),
                  onPressed: () => showOnMap(context, ref, r.location),
                  icon: const Icon(Icons.map_rounded, size: 18),
                  label: const Text('Voir sur la carte'),
                ),
              ),
              const SizedBox(width: CmSpacing.sm),
              IconButton.filledTonal(
                tooltip: 'Déplacer ici (ma position)',
                onPressed: () => _setHere(context, ref),
                icon: const Icon(Icons.my_location_rounded),
              ),
              IconButton.filledTonal(
                tooltip: 'Retirer',
                onPressed: () async {
                  try {
                    await ref.read(socialActionsProvider).clearRally(group.id);
                  } on SocialException catch (e) {
                    if (context.mounted) showCmSnack(context, e.message, error: true);
                  }
                },
                icon: const Icon(Icons.close_rounded),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _setHere(BuildContext context, WidgetRef ref) async {
    var p = ref.read(positionHubProvider)?.point;
    p ??= (await ref.read(locationServiceProvider).current())?.point;
    if (!context.mounted) return;
    if (p == null) {
      showCmSnack(context, 'Position introuvable. Active le GPS ou fais un appui long sur la carte.', error: true);
      return;
    }
    await showSetRallyPointSheet(context, at: p, groupId: group.id);
  }
}
