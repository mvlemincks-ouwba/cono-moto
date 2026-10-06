import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/settings.dart';

/// Place d'un élément dans le compteur.
enum DashKind {
  /// En très grand en haut (vitesse).
  hero,

  /// Cadran (angle, accélérations) : un ou deux au milieu.
  gauge,

  /// Petite tuile chiffrée, trois par ligne en bas.
  tile,
}

/// Éléments disponibles pour composer une vue compteur.
enum DashItem {
  speed('Vitesse', DashKind.hero, Icons.speed_rounded),
  lean('Angle d\'inclinaison', DashKind.gauge, Icons.two_wheeler_rounded),
  gforce('Accélération et freinage (G)', DashKind.gauge, Icons.radar_rounded),
  distance('Distance', DashKind.tile, Icons.route_rounded),
  movingTime('Temps en route', DashKind.tile, Icons.timer_outlined),
  elapsed('Durée totale (chrono)', DashKind.tile, Icons.timelapse_rounded),
  avgSpeed('Vitesse moyenne', DashKind.tile, Icons.av_timer_rounded),
  maxSpeed('Vitesse max', DashKind.tile, Icons.bolt_rounded),
  maxLean('Angles max', DashKind.tile, Icons.rotate_90_degrees_ccw_rounded),
  maxG('G max (accél. / frein)', DashKind.tile, Icons.compress_rounded),
  liveG('G en direct', DashKind.tile, Icons.swap_vert_rounded),
  curves('Virages', DashKind.tile, Icons.turn_slight_right_rounded),
  hardBrakes('Freinages forts', DashKind.tile, Icons.warning_amber_rounded),
  elevationGain('Dénivelé (D+)', DashKind.tile, Icons.terrain_rounded),
  altitude('Altitude', DashKind.tile, Icons.landscape_rounded),
  autonomy('Autonomie', DashKind.tile, Icons.local_gas_station_rounded),
  clock('Heure', DashKind.tile, Icons.schedule_rounded);

  const DashItem(this.label, this.kind, this.icon);

  final String label;
  final DashKind kind;
  final IconData icon;

  static DashItem? fromName(String name) => DashItem.values.where((i) => i.name == name).firstOrNull;
}

/// Une vue compteur (« Balade », « Piste »…) : les éléments affichés, dans l'ordre.
@immutable
class DashView {
  const DashView({required this.id, required this.name, required this.emoji, required this.items});

  factory DashView.fromJson(Map<String, dynamic> json) => DashView(
    id: json['id'] as String,
    name: (json['name'] as String?)?.trim().isNotEmpty == true ? (json['name'] as String).trim() : 'Ma vue',
    emoji: (json['emoji'] as String?) ?? '🏍️',
    items: sanitizeItems([for (final n in (json['items'] as List?) ?? const []) ?DashItem.fromName('$n')]),
  );

  static const maxGauges = 2;
  static const maxTiles = 9;

  final String id;
  final String name;
  final String emoji;
  final List<DashItem> items;

  bool get showsSpeed => items.contains(DashItem.speed);
  List<DashItem> get gauges => [
    for (final i in items)
      if (i.kind == DashKind.gauge) i,
  ];
  List<DashItem> get tiles => [
    for (final i in items)
      if (i.kind == DashKind.tile) i,
  ];
  String get title => '$emoji $name';

  DashView copyWith({String? id, String? name, String? emoji, List<DashItem>? items}) => DashView(
    id: id ?? this.id,
    name: name ?? this.name,
    emoji: emoji ?? this.emoji,
    items: items == null ? this.items : sanitizeItems(items),
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'emoji': emoji,
    'items': [for (final i in items) i.name],
  };

  /// Sans doublon, au plus [maxGauges] cadrans et [maxTiles] tuiles.
  static List<DashItem> sanitizeItems(Iterable<DashItem> items) {
    final out = <DashItem>[];
    var gauges = 0;
    var tiles = 0;
    for (final i in items) {
      if (out.contains(i)) continue;
      if (i.kind == DashKind.gauge && gauges++ >= maxGauges) continue;
      if (i.kind == DashKind.tile && tiles++ >= maxTiles) continue;
      out.add(i);
    }
    return out;
  }

  @override
  bool operator ==(Object other) =>
      other is DashView &&
      other.id == id &&
      other.name == name &&
      other.emoji == emoji &&
      listEquals(other.items, items);

  @override
  int get hashCode => Object.hash(id, name, emoji, Object.hashAll(items));
}

/// Vues proposées au départ (modifiables, et on peut en créer d'autres).
const defaultDashViews = <DashView>[
  DashView(
    id: 'balade',
    name: 'Balade',
    emoji: '🛣️',
    items: [
      DashItem.speed,
      DashItem.lean,
      DashItem.distance,
      DashItem.movingTime,
      DashItem.avgSpeed,
      DashItem.autonomy,
      DashItem.maxSpeed,
      DashItem.curves,
    ],
  ),
  DashView(
    id: 'piste',
    name: 'Piste',
    emoji: '🏁',
    items: [
      DashItem.speed,
      DashItem.lean,
      DashItem.gforce,
      DashItem.maxLean,
      DashItem.maxG,
      DashItem.maxSpeed,
      DashItem.elapsed,
      DashItem.hardBrakes,
      DashItem.distance,
    ],
  ),
  DashView(
    id: 'trail',
    name: 'Trail',
    emoji: '🏔️',
    items: [
      DashItem.speed,
      DashItem.lean,
      DashItem.altitude,
      DashItem.elevationGain,
      DashItem.distance,
      DashItem.movingTime,
      DashItem.autonomy,
      DashItem.clock,
    ],
  ),
  DashView(
    id: 'tranquille',
    name: 'Tranquille',
    emoji: '😌',
    items: [
      DashItem.speed,
      DashItem.distance,
      DashItem.clock,
      DashItem.autonomy,
      DashItem.movingTime,
      DashItem.avgSpeed,
    ],
  ),
];

/// Emojis proposés pour nommer une vue.
const dashViewEmojis = ['🛣️', '🏁', '🏔️', '😌', '🏍️', '🌲', '🌧️', '🌙', '⚡', '🧭', '☕', '👥'];

@immutable
class DashboardState {
  const DashboardState({required this.views, required this.activeId});

  final List<DashView> views;
  final String activeId;

  DashView get active => views.firstWhere((v) => v.id == activeId, orElse: () => views.first);
  int get activeIndex => views.indexOf(active);
}

/// Vues compteur de l'utilisateur, enregistrées sur le téléphone.
class DashboardController extends Notifier<DashboardState> {
  static const viewsKey = 'dash.views';
  static const activeKey = 'dash.active';

  @override
  DashboardState build() {
    final prefs = ref.read(sharedPreferencesProvider);
    var views = defaultDashViews;
    final raw = prefs.getString(viewsKey);
    if (raw != null) {
      try {
        final parsed = [for (final j in jsonDecode(raw) as List) DashView.fromJson(Map<String, dynamic>.from(j as Map))]
            .where((v) => v.items.isNotEmpty)
            .toList();
        if (parsed.isNotEmpty) views = parsed;
      } catch (e) {
        debugPrint('Vues compteur illisibles, retour aux vues par défaut : $e');
      }
    }
    final active = prefs.getString(activeKey);
    return DashboardState(views: views, activeId: views.any((v) => v.id == active) ? active! : views.first.id);
  }

  void select(String id) {
    if (id == state.activeId || !state.views.any((v) => v.id == id)) return;
    state = DashboardState(views: state.views, activeId: id);
    ref.read(sharedPreferencesProvider).setString(activeKey, id);
  }

  void selectIndex(int index) => select(state.views[index.clamp(0, state.views.length - 1)].id);

  /// Ajoute ou remplace [view] (et la rend active).
  Future<void> save(DashView view) async {
    if (view.items.isEmpty) return;
    final views = [...state.views];
    final i = views.indexWhere((v) => v.id == view.id);
    if (i >= 0) {
      views[i] = view;
    } else {
      views.add(view);
    }
    await _persist(views, view.id);
  }

  /// Supprime une vue (il en reste toujours au moins une).
  Future<void> delete(String id) async {
    if (state.views.length <= 1) return;
    final views = [
      for (final v in state.views)
        if (v.id != id) v,
    ];
    await _persist(views, state.activeId == id ? views.first.id : state.activeId);
  }

  Future<void> move(int from, int to) async {
    final views = [...state.views];
    final v = views.removeAt(from);
    views.insert(to.clamp(0, views.length), v);
    await _persist(views, state.activeId);
  }

  Future<void> resetToDefaults() => _persist(defaultDashViews, defaultDashViews.first.id);

  /// Identifiant libre pour une nouvelle vue.
  String newId() {
    var n = state.views.length + 1;
    while (state.views.any((v) => v.id == 'vue$n')) {
      n++;
    }
    return 'vue$n';
  }

  Future<void> _persist(List<DashView> views, String activeId) async {
    state = DashboardState(views: views, activeId: activeId);
    final prefs = ref.read(sharedPreferencesProvider);
    await prefs.setString(viewsKey, jsonEncode([for (final v in views) v.toJson()]));
    await prefs.setString(activeKey, activeId);
  }
}

final dashboardProvider = NotifierProvider<DashboardController, DashboardState>(DashboardController.new);
