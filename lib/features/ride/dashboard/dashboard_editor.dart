import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme.dart';
import '../../../core/ui/widgets.dart';
import 'dashboard_body.dart';
import 'dashboard_model.dart';

/// Liste des vues compteur : choisir, réordonner, créer, modifier.
class DashboardViewsScreen extends ConsumerWidget {
  const DashboardViewsScreen({super.key});

  static Route<void> route() => MaterialPageRoute(builder: (_) => const DashboardViewsScreen());

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final dash = ref.watch(dashboardProvider);
    final ctrl = ref.read(dashboardProvider.notifier);
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Vues du compteur'),
        actions: [
          PopupMenuButton<String>(
            onSelected: (_) => _confirmReset(context, ref),
            itemBuilder: (_) => const [PopupMenuItem(value: 'reset', child: Text('Revenir aux vues de départ'))],
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => Navigator.of(context).push(
          DashViewEditorScreen.route(
            DashView(
              id: ctrl.newId(),
              name: 'Ma vue',
              emoji: '🏍️',
              items: const [DashItem.speed, DashItem.lean, DashItem.distance, DashItem.movingTime, DashItem.avgSpeed],
            ),
            isNew: true,
          ),
        ),
        icon: const Icon(Icons.add_rounded),
        label: const Text('Nouvelle vue'),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 96),
        children: [
          Text(
            'En balade, passe d\'une vue à l\'autre d\'un geste sur le compteur ou avec les flèches. '
            'Touche une vue pour choisir ce qu\'elle affiche, et maintiens-la pour changer l\'ordre.',
            style: TextStyle(color: muted),
          ),
          const SizedBox(height: 12),
          ReorderableListView(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            buildDefaultDragHandles: false,
            onReorderItem: ctrl.move,
            children: [
              for (var i = 0; i < dash.views.length; i++)
                Card(
                  key: ValueKey(dash.views[i].id),
                  margin: const EdgeInsets.only(bottom: 8),
                  child: ListTile(
                    contentPadding: const EdgeInsets.fromLTRB(16, 4, 4, 4),
                    leading: Text(dash.views[i].emoji, style: const TextStyle(fontSize: 28)),
                    title: Row(
                      children: [
                        Flexible(
                          child: Text(dash.views[i].name, style: const TextStyle(fontWeight: FontWeight.w800)),
                        ),
                        if (dash.views[i].id == dash.activeId) ...[
                          const SizedBox(width: 8),
                          const Pill(label: 'Affichée', color: CmColors.orange),
                        ],
                      ],
                    ),
                    subtitle: Text(summary(dash.views[i]), maxLines: 2, overflow: TextOverflow.ellipsis),
                    trailing: ReorderableDragStartListener(
                      index: i,
                      child: const Padding(padding: EdgeInsets.all(12), child: Icon(Icons.drag_handle_rounded)),
                    ),
                    onTap: () => Navigator.of(context).push(DashViewEditorScreen.route(dash.views[i])),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }

  /// « Vitesse, Angle, Distance… »
  static String summary(DashView v) => [
    for (final i in v.items)
      switch (i) {
        DashItem.speed => 'Vitesse',
        DashItem.lean => 'Angle',
        DashItem.gforce => 'Cercle des G',
        _ => i.label,
      },
  ].join(' · ');

  Future<void> _confirmReset(BuildContext context, WidgetRef ref) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Revenir aux vues de départ ?'),
        content: const Text('Tes vues personnalisées seront remplacées par Balade, Piste, Trail et Tranquille.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Annuler')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Remplacer')),
        ],
      ),
    );
    if (ok == true) await ref.read(dashboardProvider.notifier).resetToDefaults();
  }
}

/// Création ou modification d'une vue compteur.
class DashViewEditorScreen extends ConsumerStatefulWidget {
  const DashViewEditorScreen({super.key, required this.view, this.isNew = false});

  final DashView view;
  final bool isNew;

  static Route<void> route(DashView view, {bool isNew = false}) => MaterialPageRoute(
    builder: (_) => DashViewEditorScreen(view: view, isNew: isNew),
  );

  @override
  ConsumerState<DashViewEditorScreen> createState() => _DashViewEditorScreenState();
}

class _DashViewEditorScreenState extends ConsumerState<DashViewEditorScreen> {
  late final _name = TextEditingController(text: widget.view.name);
  late String _emoji = widget.view.emoji;
  late List<DashItem> _items = [...widget.view.items];

  DashView get _current => widget.view.copyWith(name: _name.text.trim(), emoji: _emoji, items: _items);

  List<DashItem> get _tiles => [
    for (final i in _items)
      if (i.kind == DashKind.tile) i,
  ];

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  void _toggle(DashItem item, bool on) {
    setState(() {
      if (on) {
        // Vitesse et cadrans gardent leur place en haut, les tuiles vont à la fin.
        _items = DashView.sanitizeItems(item.kind == DashKind.tile ? [..._items, item] : [item, ..._items]);
      } else {
        _items = [
          for (final i in _items)
            if (i != item) i,
        ];
      }
    });
  }

  void _reorderTiles(int from, int to) {
    final tiles = _tiles;
    final moved = tiles.removeAt(from);
    tiles.insert(to, moved);
    setState(
      () => _items = [
        for (final i in _items)
          if (i.kind != DashKind.tile) i,
        ...tiles,
      ],
    );
  }

  Future<void> _save() async {
    if (_items.isEmpty) {
      showCmSnack(context, 'Choisis au moins une information à afficher.');
      return;
    }
    final view = _current.copyWith(name: _name.text.trim().isEmpty ? 'Ma vue' : _name.text.trim());
    final ctrl = ref.read(dashboardProvider.notifier);
    await ctrl.save(view);
    ctrl.select(view.id);
    if (mounted) Navigator.of(context).pop();
  }

  Future<void> _delete() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Supprimer « ${widget.view.name} » ?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Annuler')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: CmColors.red),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Supprimer'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await ref.read(dashboardProvider.notifier).delete(widget.view.id);
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    final canDelete = !widget.isNew && ref.watch(dashboardProvider.select((d) => d.views.length)) > 1;
    final tiles = _tiles;
    final available = [
      for (final i in DashItem.values)
        if (i.kind == DashKind.tile && !_items.contains(i)) i,
    ];
    final fullTiles = tiles.length >= DashView.maxTiles;

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.isNew ? 'Nouvelle vue' : 'Modifier la vue'),
        actions: [
          if (canDelete)
            IconButton(onPressed: _delete, tooltip: 'Supprimer la vue', icon: const Icon(Icons.delete_outline_rounded)),
          TextButton(onPressed: _save, child: const Text('Enregistrer')),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 32),
        children: [
          // Aperçu en direct, avec le thème du compteur.
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(CmSpacing.radius),
              child: Theme(
                data: CmTheme.dark(),
                child: ColoredBox(
                  color: CmColors.asphalt900,
                  child: SizedBox(
                    height: 340,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      child: DashPage(view: _current),
                    ),
                  ),
                ),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
            child: TextField(
              controller: _name,
              textCapitalization: TextCapitalization.sentences,
              maxLength: 24,
              decoration: const InputDecoration(labelText: 'Nom de la vue', hintText: 'Piste, Trail, Rando…'),
              onChanged: (_) => setState(() {}),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final e in dashViewEmojis)
                  ChoiceChip(
                    label: Text(e, style: const TextStyle(fontSize: 20)),
                    selected: e == _emoji,
                    onSelected: (_) => setState(() => _emoji = e),
                  ),
              ],
            ),
          ),
          const SectionHeader('En grand'),
          SwitchListTile(
            secondary: Icon(DashItem.speed.icon),
            title: const Text('Vitesse'),
            value: _items.contains(DashItem.speed),
            onChanged: (v) => _toggle(DashItem.speed, v),
          ),
          const SectionHeader('Cadrans'),
          SwitchListTile(
            secondary: Icon(DashItem.lean.icon),
            title: const Text('Angle d\'inclinaison'),
            subtitle: const Text('L\'angle en direct et tes max à gauche et à droite'),
            value: _items.contains(DashItem.lean),
            onChanged: (v) => _toggle(DashItem.lean, v),
          ),
          SwitchListTile(
            secondary: Icon(DashItem.gforce.icon),
            title: const Text('Cercle des G'),
            subtitle: const Text('Accélération et freinage en G, force en virage, et tes max'),
            value: _items.contains(DashItem.gforce),
            onChanged: (v) => _toggle(DashItem.gforce, v),
          ),
          SectionHeader('Tuiles (${tiles.length}/${DashView.maxTiles})'),
          if (tiles.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Text('Aucune tuile : ajoute-en ci-dessous.', style: TextStyle(color: muted)),
            )
          else
            ReorderableListView(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              buildDefaultDragHandles: false,
              onReorderItem: _reorderTiles,
              children: [
                for (var i = 0; i < tiles.length; i++)
                  ListTile(
                    key: ValueKey(tiles[i]),
                    leading: Icon(tiles[i].icon),
                    title: Text(tiles[i].label),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          tooltip: 'Retirer',
                          onPressed: () => _toggle(tiles[i], false),
                          icon: const Icon(Icons.remove_circle_outline_rounded),
                        ),
                        ReorderableDragStartListener(
                          index: i,
                          child: const Padding(padding: EdgeInsets.all(8), child: Icon(Icons.drag_handle_rounded)),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          if (available.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    fullTiles ? 'Maximum atteint : retire une tuile pour en ajouter une autre.' : 'Ajouter une tuile',
                    style: TextStyle(color: muted, fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final i in available)
                        ActionChip(
                          avatar: Icon(i.icon, size: 18),
                          label: Text(i.label),
                          onPressed: fullTiles ? null : () => _toggle(i, true),
                        ),
                    ],
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
