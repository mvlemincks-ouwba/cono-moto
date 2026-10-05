import 'package:flutter/material.dart';

import '../../core/geo.dart';
import '../../core/theme.dart';
import '../../data/models/planned_route.dart';
import '../../data/models/ride.dart';
import '../../data/models/shared.dart';
import 'expenses.dart';

/// Modèles du module « Potes » et conversion depuis/vers les valeurs brutes
/// de la Realtime Database. Aucune dépendance à Firebase : tout est testable
/// avec de simples `Map`.

// ---------------------------------------------------------------------------
// Lecture tolérante des valeurs RTDB (Map<Object?, Object?>, nombres int/double…)
// ---------------------------------------------------------------------------

double? asDouble(Object? v) => v is num ? v.toDouble() : (v is String ? double.tryParse(v) : null);
int? asInt(Object? v) => v is num ? v.toInt() : (v is String ? int.tryParse(v) : null);
String? asString(Object? v) => v is String ? v : null;
bool asBool(Object? v) => v == true;

DateTime? asTime(Object? v) {
  final ms = asInt(v);
  return ms == null ? null : DateTime.fromMillisecondsSinceEpoch(ms, isUtc: true);
}

/// Convertit récursivement une valeur RTDB en JSON Dart standard
/// (`Map<String, dynamic>`, `List<dynamic>`).
Object? deepJson(Object? v) {
  if (v is Map) return {for (final e in v.entries) '${e.key}': deepJson(e.value)};
  if (v is List) return [for (final x in v) deepJson(x)];
  return v;
}

/// Enfants d'un nœud RTDB sous forme de paires (clé, valeur). Gère les
/// tableaux (clés numériques) renvoyés par le SDK.
Iterable<MapEntry<String, Object?>> children(Object? raw) sync* {
  if (raw is Map) {
    for (final e in raw.entries) {
      yield MapEntry('${e.key}', e.value);
    }
  } else if (raw is List) {
    for (var i = 0; i < raw.length; i++) {
      if (raw[i] != null) yield MapEntry('$i', raw[i]);
    }
  }
}

/// Clés dont la valeur vaut `true` (ex : friends/{uid}, userGroups/{uid}).
List<String> trueKeys(Object? raw) => [
      for (final e in children(raw))
        if (e.value == true) e.key
    ]..sort();

/// Couleur par défaut d'un utilisateur selon son uid (stable).
int defaultColorFor(String uid) {
  var h = 0;
  for (final c in uid.codeUnits) {
    h = (h * 31 + c) & 0x7fffffff;
  }
  return CmColors.friendPalette[h % CmColors.friendPalette.length].toARGB32();
}

/// Initiales d'un pseudo (« Max Verstappen » → « MV », « Ju » → « JU »).
String initialsOf(String name) {
  final parts = name.trim().split(RegExp(r'\s+')).where((p) => p.isNotEmpty).toList();
  if (parts.isEmpty) return '?';
  if (parts.length == 1) {
    final p = parts.first;
    return p.substring(0, p.length >= 2 ? 2 : 1).toUpperCase();
  }
  return (parts[0][0] + parts[1][0]).toUpperCase();
}

// ---------------------------------------------------------------------------
// Profil
// ---------------------------------------------------------------------------

/// Profil public d'un motard : users/{uid}/profile.
@immutable
class UserProfile {
  const UserProfile({
    required this.uid,
    required this.name,
    required this.colorValue,
    this.bike = '',
    this.code = '',
    this.createdAt,
  });

  final String uid;
  final String name;
  final int colorValue;
  final String bike;

  /// Code ami (6 caractères) à donner aux potes.
  final String code;
  final DateTime? createdAt;

  Color get color => Color(colorValue);
  String get initials => initialsOf(name);

  UserProfile copyWith({String? name, int? colorValue, String? bike, String? code}) => UserProfile(
        uid: uid,
        name: name ?? this.name,
        colorValue: colorValue ?? this.colorValue,
        bike: bike ?? this.bike,
        code: code ?? this.code,
        createdAt: createdAt,
      );

  Map<String, Object?> toMap() => {
        'name': name,
        'color': colorValue,
        'bike': bike,
        'code': code,
        'createdAt': (createdAt ?? DateTime.now()).millisecondsSinceEpoch,
      };

  static UserProfile? fromMap(String uid, Object? raw) {
    if (raw is! Map) return null;
    final name = asString(raw['name'])?.trim();
    if (name == null || name.isEmpty) return null;
    return UserProfile(
      uid: uid,
      name: name,
      colorValue: asInt(raw['color']) ?? defaultColorFor(uid),
      bike: asString(raw['bike']) ?? '',
      code: asString(raw['code']) ?? '',
      createdAt: asTime(raw['createdAt']),
    );
  }

  static const maxNameLength = 24;
  static const maxBikeLength = 40;
}

// ---------------------------------------------------------------------------
// Position en direct
// ---------------------------------------------------------------------------

/// Contenu de live/{uid}.
@immutable
class LiveState {
  const LiveState({
    required this.uid,
    required this.location,
    required this.updatedAt,
    this.speedKmh = 0,
    this.heading,
    this.leanDeg,
    this.riding = false,
    this.name,
    this.colorValue,
    this.bike,
    this.sos = false,
    this.sosMessage,
    this.sosAt,
  });

  final String uid;
  final GeoPoint location;
  final DateTime updatedAt;
  final double speedKmh;
  final double? heading;
  final double? leanDeg;
  final bool riding;
  final String? name;
  final int? colorValue;
  final String? bike;
  final bool sos;
  final String? sosMessage;
  final DateTime? sosAt;

  /// Au-delà de cet âge, la position n'est plus affichée.
  static const maxAge = Duration(hours: 12);

  bool isOlderThan(Duration d, {DateTime? now}) =>
      (now ?? DateTime.now()).toUtc().difference(updatedAt.toUtc()) > d;

  static LiveState? fromMap(String uid, Object? raw) {
    if (raw is! Map) return null;
    final lat = asDouble(raw['lat']);
    final lng = asDouble(raw['lng']);
    final ts = asTime(raw['ts']);
    if (lat == null || lng == null || ts == null) return null;
    if (lat.abs() > 90 || lng.abs() > 180) return null;
    return LiveState(
      uid: uid,
      location: GeoPoint(lat, lng),
      updatedAt: ts,
      speedKmh: (asDouble(raw['speed']) ?? 0).clamp(0, 400).toDouble(),
      heading: asDouble(raw['heading']),
      leanDeg: asDouble(raw['lean']),
      riding: asBool(raw['riding']),
      name: asString(raw['name']),
      colorValue: asInt(raw['color']),
      bike: asString(raw['bike']),
      sos: asBool(raw['sos']),
      sosMessage: asString(raw['sosMessage']),
      sosAt: asTime(raw['sosAt']),
    );
  }
}

/// Un pote : profil + dernière position connue.
@immutable
class Friend {
  const Friend({required this.uid, this.profile, this.live});

  final String uid;
  final UserProfile? profile;
  final LiveState? live;

  String get name {
    final p = profile?.name;
    if (p != null && p.isNotEmpty) return p;
    final l = live?.name;
    if (l != null && l.isNotEmpty) return l;
    return 'Pote';
  }

  int get colorValue => profile?.colorValue ?? live?.colorValue ?? defaultColorFor(uid);
  Color get color => Color(colorValue);
  String get initials => initialsOf(name);
  String? get bike {
    final b = (profile?.bike.isNotEmpty == true) ? profile!.bike : live?.bike;
    return (b == null || b.isEmpty) ? null : b;
  }

  /// Position récente (moins de 12 h).
  LiveState? recentLive({DateTime? now}) {
    final l = live;
    if (l == null || l.isOlderThan(LiveState.maxAge, now: now)) return null;
    return l;
  }

  bool isRiding({DateTime? now}) {
    final l = recentLive(now: now);
    return l != null && l.riding && !l.isOlderThan(const Duration(minutes: 10), now: now);
  }

  bool isSos({DateTime? now}) => recentLive(now: now)?.sos ?? false;

  /// Conversion vers le modèle partagé utilisé par la carte. Null si pas de
  /// position récente.
  FriendLive? toFriendLive({DateTime? now}) {
    final l = recentLive(now: now);
    if (l == null) return null;
    return FriendLive(
      uid: uid,
      name: name,
      location: l.location,
      updatedAt: l.updatedAt,
      colorValue: colorValue,
      speedKmh: l.speedKmh,
      heading: l.heading,
      leanDeg: l.leanDeg,
      riding: l.riding,
      bikeName: bike,
      sos: l.sos,
    );
  }
}

/// Positions en direct à afficher : potes ayant une position de moins de 12 h,
/// SOS d'abord, puis ceux qui roulent, puis par nom.
List<FriendLive> liveFriends(Iterable<Friend> friends, {DateTime? now}) {
  final out = [
    for (final f in friends) ?f.toFriendLive(now: now),
  ];
  out.sort((a, b) {
    if (a.sos != b.sos) return a.sos ? -1 : 1;
    if (a.riding != b.riding) return a.riding ? -1 : 1;
    return a.name.toLowerCase().compareTo(b.name.toLowerCase());
  });
  return out;
}

// ---------------------------------------------------------------------------
// Signalements
// ---------------------------------------------------------------------------

/// Durées de vie proposées pour un signalement.
const reportLifetimeChoices = <Duration>[
  Duration(hours: 1),
  Duration(hours: 2),
  Duration(hours: 3),
  Duration(hours: 24),
  Duration(days: 7),
  Duration(days: 30),
];

/// Durée de vie par défaut d'un signalement selon son type.
Duration defaultReportLifetime(ReportType type) => switch (type) {
      ReportType.police => const Duration(hours: 2),
      ReportType.accident => const Duration(hours: 3),
      ReportType.animal => const Duration(hours: 1),
      ReportType.danger => const Duration(hours: 24),
      ReportType.huile => const Duration(hours: 24),
      ReportType.gravillons => const Duration(days: 7),
      ReportType.travaux => const Duration(days: 7),
      ReportType.routeDegradee => const Duration(days: 30),
      ReportType.superSpot => const Duration(days: 30),
    };

/// « 2 h », « 24 h », « 7 j ».
String lifetimeLabel(Duration d) {
  if (d.inHours < 1) return '${d.inMinutes} min';
  if (d.inHours <= 24) return '${d.inHours} h';
  return '${d.inDays} j';
}

/// Contenu de reports/{uid}/{id}.
Map<String, Object?> reportToMap({
  required ReportType type,
  required GeoPoint at,
  required String comment,
  required DateTime createdAt,
  required Duration lifetime,
  required String authorName,
}) =>
    {
      'type': type.name,
      'lat': at.lat,
      'lng': at.lng,
      'comment': comment.trim(),
      'ts': createdAt.millisecondsSinceEpoch,
      'expiresAt': createdAt.add(lifetime).millisecondsSinceEpoch,
      'authorName': authorName,
    };

RoadReport? reportFromMap(String authorUid, String id, Object? raw) {
  if (raw is! Map) return null;
  final lat = asDouble(raw['lat']);
  final lng = asDouble(raw['lng']);
  final ts = asTime(raw['ts']);
  if (lat == null || lng == null || ts == null) return null;
  return RoadReport(
    id: id,
    type: ReportType.fromName(asString(raw['type'])),
    location: GeoPoint(lat, lng),
    createdAt: ts,
    authorUid: authorUid,
    authorName: asString(raw['authorName']) ?? 'Un pote',
    comment: asString(raw['comment']) ?? '',
    expiresAt: asTime(raw['expiresAt']),
  );
}

/// Tous les signalements d'un auteur (nœud reports/{uid}).
List<RoadReport> reportsFromMap(String authorUid, Object? raw) => [
      for (final e in children(raw)) ?reportFromMap(authorUid, e.key, e.value),
    ];

bool reportIsActive(RoadReport r, {DateTime? now}) {
  final exp = r.expiresAt;
  if (exp == null) return true;
  return (now ?? DateTime.now()).toUtc().isBefore(exp.toUtc());
}

/// Signalements non expirés, du plus récent au plus ancien.
List<RoadReport> activeReports(Iterable<RoadReport> reports, {DateTime? now}) =>
    reports.where((r) => reportIsActive(r, now: now)).toList()
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));

// ---------------------------------------------------------------------------
// Groupes
// ---------------------------------------------------------------------------

@immutable
class GroupMember {
  const GroupMember({required this.uid, required this.name, required this.colorValue, this.joinedAt});

  final String uid;
  final String name;
  final int colorValue;
  final DateTime? joinedAt;

  Color get color => Color(colorValue);
  String get initials => initialsOf(name);
}

@immutable
class Group {
  const Group({
    required this.id,
    required this.name,
    required this.createdBy,
    this.createdAt,
    this.members = const [],
    this.rally,
    this.expenses = const [],
    this.settlements = const [],
  });

  /// Identifiant = code d'invitation.
  final String id;
  final String name;
  final String createdBy;
  final DateTime? createdAt;
  final List<GroupMember> members;
  final RallyPoint? rally;
  final List<Expense> expenses;
  final List<Settlement> settlements;

  bool hasMember(String uid) => members.any((m) => m.uid == uid);

  GroupMember? member(String uid) => members.where((m) => m.uid == uid).firstOrNull;

  /// Nom d'un membre (y compris un ancien membre resté dans les dépenses).
  String nameOf(String uid, {String fallback = 'Ancien membre'}) => member(uid)?.name ?? fallback;

  /// uids concernés par les comptes : membres actuels + anciens membres
  /// présents dans les dépenses ou remboursements.
  List<String> get accountUids {
    final s = <String>{
      for (final m in members) m.uid,
      for (final e in expenses) ...[e.paidBy, ...e.participants],
      for (final st in settlements) ...[st.from, st.to],
    };
    return s.toList();
  }

  Map<String, int> get balances =>
      ExpenseMath.balances(members: accountUids, expenses: expenses, settlements: settlements);

  List<Transfer> get transfers => ExpenseMath.settle(balances);

  static Group? fromMap(String gid, Object? raw) {
    if (raw is! Map) return null;
    final name = asString(raw['name']);
    if (name == null) return null;
    final members = <GroupMember>[
      for (final e in children(raw['members']))
        if (e.value is Map)
          GroupMember(
            uid: e.key,
            name: asString((e.value as Map)['name'])?.trim().isNotEmpty == true
                ? (asString((e.value as Map)['name'])!).trim()
                : 'Motard',
            colorValue: asInt((e.value as Map)['color']) ?? defaultColorFor(e.key),
            joinedAt: asTime((e.value as Map)['joinedAt']),
          ),
    ]..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));

    RallyPoint? rally;
    final r = raw['rally'];
    if (r is Map) {
      final lat = asDouble(r['lat']), lng = asDouble(r['lng']);
      if (lat != null && lng != null) {
        final setByUid = asString(r['setBy']) ?? '';
        final setByName = asString(r['setByName']) ??
            members.where((m) => m.uid == setByUid).map((m) => m.name).firstOrNull ??
            'un pote';
        rally = RallyPoint(
          groupId: gid,
          groupName: name,
          location: GeoPoint(lat, lng),
          label: (asString(r['label'])?.trim().isNotEmpty ?? false) ? asString(r['label'])!.trim() : 'Regroupement',
          setBy: setByName,
          setAt: asTime(r['setAt']) ?? DateTime.now().toUtc(),
        );
      }
    }

    final expenses = [
      for (final e in children(raw['expenses'])) ?Expense.fromMap(e.key, e.value),
    ]..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    final settlements = [
      for (final e in children(raw['settlements'])) ?Settlement.fromMap(e.key, e.value),
    ]..sort((a, b) => b.createdAt.compareTo(a.createdAt));

    return Group(
      id: gid,
      name: name,
      createdBy: asString(raw['createdBy']) ?? '',
      createdAt: asTime(raw['createdAt']),
      members: members,
      rally: rally,
      expenses: expenses,
      settlements: settlements,
    );
  }
}

/// Contenu de groups/{gid}/rally.
Map<String, Object?> rallyToMap({
  required GeoPoint at,
  required String label,
  required String setByUid,
  required String setByName,
  required DateTime setAt,
}) =>
    {
      'lat': at.lat,
      'lng': at.lng,
      'label': label.trim().isEmpty ? 'Regroupement' : label.trim(),
      'setBy': setByUid,
      'setByName': setByName,
      'setAt': setAt.millisecondsSinceEpoch,
    };

// ---------------------------------------------------------------------------
// Partage de position par lien web
// ---------------------------------------------------------------------------

/// Un de mes liens de suivi (userShares/{uid}/{token} = expiresAt).
@immutable
class LiveShare {
  const LiveShare({required this.token, required this.expiresAt});

  final String token;
  final DateTime expiresAt;

  bool isActive({DateTime? now}) => (now ?? DateTime.now()).toUtc().isBefore(expiresAt.toUtc());

  Duration remaining({DateTime? now}) {
    final d = expiresAt.toUtc().difference((now ?? DateTime.now()).toUtc());
    return d.isNegative ? Duration.zero : d;
  }
}

List<LiveShare> sharesFromMap(Object? raw) => [
      for (final e in children(raw))
        if (asTime(e.value) != null) LiveShare(token: e.key, expiresAt: asTime(e.value)!),
    ]..sort((a, b) => b.expiresAt.compareTo(a.expiresAt));

// ---------------------------------------------------------------------------
// Balades partagées
// ---------------------------------------------------------------------------

/// Copie d'une balade planifiée en balade « partagée par un pote ».
PlannedRoute asFriendRoute(PlannedRoute r, {required String author}) => PlannedRoute(
      id: r.id,
      name: r.name,
      createdAt: r.createdAt,
      points: r.points,
      style: r.style,
      source: RouteSource.friend,
      waypoints: r.waypoints,
      distanceM: r.distanceM,
      durationS: r.durationS,
      curvatureScore: r.curvatureScore,
      elevationGainM: r.elevationGainM,
      maneuvers: r.maneuvers,
      description: r.description,
      author: author,
      favorite: false,
    );

/// Contenu de sharedRoutes/{uid}/{routeId}.
Map<String, Object?> sharedRouteToMap(PlannedRoute route, {required String authorName, required DateTime sharedAt}) {
  final json = Map<String, Object?>.from(route.toJson())
    ..['author'] = authorName
    ..['favorite'] = false
    ..['sharedAt'] = sharedAt.millisecondsSinceEpoch;
  json.removeWhere((k, v) => v == null);
  return json;
}

/// Balade planifiée partagée par un pote (avec la date de partage pour le tri).
@immutable
class SharedRouteEntry {
  const SharedRouteEntry({required this.authorUid, required this.route, required this.sharedAt});

  final String authorUid;
  final PlannedRoute route;
  final DateTime sharedAt;
}

SharedRouteEntry? sharedRouteFromMap(String authorUid, String id, Object? raw, {String? authorName}) {
  if (raw is! Map) return null;
  try {
    final json = deepJson(raw) as Map<String, dynamic>;
    json['id'] = (json['id'] as String?) ?? id;
    final route = PlannedRoute.fromJson(json);
    if (route.points.length < 2) return null;
    return SharedRouteEntry(
      authorUid: authorUid,
      route: asFriendRoute(route, author: authorName ?? route.author ?? 'Un pote'),
      sharedAt: asTime(json['sharedAt']) ?? route.createdAt,
    );
  } catch (_) {
    return null;
  }
}

/// Balade enregistrée partagée par un pote (sharedRides/{uid}/{rideId}).
@immutable
class FriendRide {
  const FriendRide({
    required this.id,
    required this.authorUid,
    required this.authorName,
    required this.authorColorValue,
    required this.name,
    required this.startedAt,
    required this.sharedAt,
    this.distanceM = 0,
    this.movingTimeS = 0,
    this.maxSpeedKmh = 0,
    this.avgSpeedKmh = 0,
    this.maxLeanDeg = 0,
    this.elevationGainM = 0,
    this.previewPolyline = '',
  });

  final String id;
  final String authorUid;
  final String authorName;
  final int authorColorValue;
  final String name;
  final DateTime startedAt;
  final DateTime sharedAt;
  final double distanceM;
  final int movingTimeS;
  final double maxSpeedKmh;
  final double avgSpeedKmh;
  final double maxLeanDeg;
  final double elevationGainM;
  final String previewPolyline;

  Color get authorColor => Color(authorColorValue);

  List<GeoPoint> get previewPoints {
    if (previewPolyline.isEmpty) return const [];
    try {
      return Geo.decodePolyline(previewPolyline);
    } catch (_) {
      return const [];
    }
  }

  FriendRide withAuthor(String name, int colorValue) => FriendRide(
        id: id,
        authorUid: authorUid,
        authorName: name,
        authorColorValue: colorValue,
        name: this.name,
        startedAt: startedAt,
        sharedAt: sharedAt,
        distanceM: distanceM,
        movingTimeS: movingTimeS,
        maxSpeedKmh: maxSpeedKmh,
        avgSpeedKmh: avgSpeedKmh,
        maxLeanDeg: maxLeanDeg,
        elevationGainM: elevationGainM,
        previewPolyline: previewPolyline,
      );

  static FriendRide? fromMap(String authorUid, String id, Object? raw) {
    if (raw is! Map) return null;
    final started = asTime(raw['startedAt']);
    if (started == null) return null;
    return FriendRide(
      id: id,
      authorUid: authorUid,
      authorName: asString(raw['authorName']) ?? 'Un pote',
      authorColorValue: asInt(raw['authorColor']) ?? defaultColorFor(authorUid),
      name: asString(raw['name']) ?? 'Balade',
      startedAt: started,
      sharedAt: asTime(raw['sharedAt']) ?? started,
      distanceM: asDouble(raw['distanceM']) ?? 0,
      movingTimeS: asInt(raw['movingTimeS']) ?? 0,
      maxSpeedKmh: asDouble(raw['maxSpeedKmh']) ?? 0,
      avgSpeedKmh: asDouble(raw['avgSpeedKmh']) ?? 0,
      maxLeanDeg: asDouble(raw['maxLeanDeg']) ?? 0,
      elevationGainM: asDouble(raw['elevationGainM']) ?? 0,
      previewPolyline: asString(raw['previewPolyline']) ?? '',
    );
  }
}

/// Contenu de sharedRides/{uid}/{rideId}.
Map<String, Object?> sharedRideToMap(
  Ride ride, {
  required String authorName,
  required int authorColor,
  required DateTime sharedAt,
}) {
  var preview = ride.previewPolyline;
  // Garde-fou de taille : on simplifie un aperçu trop détaillé.
  if (preview.length > 6000) {
    final pts = ride.previewPoints;
    var tol = 15.0;
    var simplified = Geo.simplify(pts, tol);
    while (Geo.encodePolyline(simplified).length > 6000 && tol < 2000) {
      tol *= 2;
      simplified = Geo.simplify(pts, tol);
    }
    preview = Geo.encodePolyline(simplified);
  }
  return {
    'name': ride.name,
    'startedAt': ride.startedAt.millisecondsSinceEpoch,
    if (ride.endedAt != null) 'endedAt': ride.endedAt!.millisecondsSinceEpoch,
    'distanceM': ride.stats.distanceM,
    'movingTimeS': ride.stats.movingTimeS,
    'maxSpeedKmh': ride.stats.maxSpeedKmh,
    'avgSpeedKmh': ride.stats.avgMovingSpeedKmh,
    'maxLeanDeg': ride.stats.maxLeanDeg,
    'elevationGainM': ride.stats.elevationGainM,
    'previewPolyline': preview,
    'authorName': authorName,
    'authorColor': authorColor,
    'sharedAt': sharedAt.millisecondsSinceEpoch,
  };
}

// ---------------------------------------------------------------------------
// Mises à jour multi-chemins (atomiques) — construites ici pour être testées.
// ---------------------------------------------------------------------------

class SocialUpdates {
  SocialUpdates._();

  /// Création du profil + réservation du code ami.
  static Map<String, Object?> createProfile(UserProfile p) => {
        'users/${p.uid}/profile': p.toMap(),
        'friendCodes/${p.code}': p.uid,
      };

  /// Lien d'amitié mutuel. La preuve (code ami du pote ou groupe commun)
  /// permet aux règles de sécurité de vérifier que j'ai le droit de m'ajouter
  /// dans sa liste.
  static Map<String, Object?> linkFriends(String me, String friend, {String? code, String? groupId}) => {
        'friends/$me/$friend': true,
        'friends/$friend/$me': true,
        'friendProofs/$friend/$me': {
          'code': ?code,
          'group': ?groupId,
        },
      };

  static Map<String, Object?> unlinkFriends(String me, String friend) => {
        'friends/$me/$friend': null,
        'friends/$friend/$me': null,
      };

  static Map<String, Object?> memberEntry(UserProfile me, DateTime now) => {
        'name': me.name,
        'color': me.colorValue,
        'joinedAt': now.millisecondsSinceEpoch,
      };

  static Map<String, Object?> createGroup(String gid, String name, UserProfile me, DateTime now) => {
        'groups/$gid': {
          'name': name.trim(),
          'createdBy': me.uid,
          'createdAt': now.millisecondsSinceEpoch,
          'members': {me.uid: memberEntry(me, now)},
        },
        'userGroups/${me.uid}/$gid': true,
      };

  static Map<String, Object?> joinGroup(String gid, UserProfile me, DateTime now) => {
        'groups/$gid/members/${me.uid}': memberEntry(me, now),
        'userGroups/${me.uid}/$gid': true,
      };

  static Map<String, Object?> leaveGroup(String gid, String me) => {
        'groups/$gid/members/$me': null,
        'userGroups/$me/$gid': null,
      };
}
