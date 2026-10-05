import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/geo.dart';
import '../../core/settings.dart';
import '../../services/routing/geocoder.dart';

/// Destination choisie récemment dans « Où on va ? ».
@immutable
class RecentDestination {
  const RecentDestination({required this.name, required this.point, required this.usedAt, this.detail});

  final String name;
  final String? detail;
  final GeoPoint point;
  final DateTime usedAt;

  String get label => detail == null || detail!.isEmpty ? name : '$name, $detail';

  factory RecentDestination.fromPlace(Place p, DateTime now) =>
      RecentDestination(name: p.name, detail: p.detail, point: p.point, usedAt: now.toUtc());

  Place toPlace() => Place(name: name, detail: detail, point: point);

  Map<String, dynamic> toJson() => {
    'name': name,
    if (detail != null) 'detail': detail,
    'lat': point.lat,
    'lng': point.lng,
    'at': usedAt.millisecondsSinceEpoch,
  };

  static RecentDestination? fromJson(Object? j) {
    if (j is! Map) return null;
    final name = j['name'];
    final lat = j['lat'];
    final lng = j['lng'];
    if (name is! String || name.trim().isEmpty || lat is! num || lng is! num) return null;
    final at = j['at'];
    return RecentDestination(
      name: name,
      detail: j['detail'] is String ? j['detail'] as String : null,
      point: GeoPoint(lat.toDouble(), lng.toDouble()),
      usedAt: DateTime.fromMillisecondsSinceEpoch(at is num ? at.toInt() : 0, isUtc: true),
    );
  }
}

/// Règles de la liste des destinations récentes (logique pure).
class RecentDestinations {
  RecentDestinations._();

  static const maxCount = 8;

  /// Deux destinations à moins de [radiusM] l'une de l'autre sont la même.
  static bool same(RecentDestination a, RecentDestination b, {double radiusM = 80}) =>
      Geo.distance(a.point, b.point) <= radiusM ||
      (a.label.toLowerCase() == b.label.toLowerCase() && Geo.distance(a.point, b.point) <= 2000);

  /// Ajoute [d] en tête (en retirant son doublon éventuel), au plus [max].
  static List<RecentDestination> add(List<RecentDestination> list, RecentDestination d, {int max = maxCount}) => [
    d,
    for (final e in list)
      if (!same(e, d)) e,
  ].take(max).toList();

  static List<RecentDestination> remove(List<RecentDestination> list, RecentDestination d) => [
    for (final e in list)
      if (!same(e, d, radiusM: 5)) e,
  ];

  static String encode(List<RecentDestination> list) => jsonEncode([for (final d in list) d.toJson()]);

  /// Lecture tolérante (données abîmées → liste vide ou entrées ignorées).
  static List<RecentDestination> decode(String? raw) {
    if (raw == null || raw.isEmpty) return const [];
    try {
      final j = jsonDecode(raw);
      if (j is! List) return const [];
      return [for (final e in j) ?RecentDestination.fromJson(e)].take(maxCount).toList();
    } catch (_) {
      return const [];
    }
  }
}

/// Destinations récentes, gardées dans les préférences du téléphone.
class RecentDestinationsNotifier extends Notifier<List<RecentDestination>> {
  static const prefsKey = 'nav.recentDestinations';

  @override
  List<RecentDestination> build() {
    try {
      return RecentDestinations.decode(ref.watch(sharedPreferencesProvider).getString(prefsKey));
    } catch (_) {
      return const [];
    }
  }

  Future<void> add(Place place, {DateTime? now}) =>
      _save(RecentDestinations.add(state, RecentDestination.fromPlace(place, now ?? DateTime.now())));

  Future<void> remove(RecentDestination d) => _save(RecentDestinations.remove(state, d));

  Future<void> clear() => _save(const []);

  Future<void> _save(List<RecentDestination> next) async {
    state = next;
    try {
      await ref.read(sharedPreferencesProvider).setString(prefsKey, RecentDestinations.encode(next));
    } catch (e) {
      debugPrint('Destinations récentes : $e');
    }
  }
}

final recentDestinationsProvider = NotifierProvider<RecentDestinationsNotifier, List<RecentDestination>>(
  RecentDestinationsNotifier.new,
);
