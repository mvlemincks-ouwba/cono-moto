// Logique pure du module essence : statistiques de prix, tri des stations,
// fraîcheur des prix, calculs d'un plein et consommation « plein à plein ».
import 'dart:math' as math;

import '../../core/geo.dart';
import '../../data/models/garage.dart';
import '../../data/models/shared.dart';

/// Au-delà, un prix est considéré comme périmé.
const priceStaleAfter = Duration(days: 3);

/// Fraîcheur d'un prix affiché.
enum PriceFreshness {
  /// Mis à jour il y a moins de 24 h.
  fresh,

  /// Entre 24 h et 3 jours.
  recent,

  /// Plus de 3 jours : à prendre avec des pincettes.
  stale,

  /// Date inconnue.
  unknown,
}

PriceFreshness priceFreshness(DateTime? updatedAt, {required DateTime now}) {
  if (updatedAt == null) return PriceFreshness.unknown;
  final age = now.toUtc().difference(updatedAt.toUtc());
  if (age > priceStaleAfter) return PriceFreshness.stale;
  if (age > const Duration(hours: 24)) return PriceFreshness.recent;
  return PriceFreshness.fresh;
}

bool isPriceStale(DateTime? updatedAt, {required DateTime now}) =>
    priceFreshness(updatedAt, now: now) == PriceFreshness.stale;

/// Station telle qu'affichée dans la liste (autour de moi ou sur le trajet).
class StationEntry {
  const StationEntry(this.station, {this.distanceAlongM, this.offRouteM, this.alongFromRider = false});

  final FuelStation station;

  /// Position le long de l'itinéraire (mode « sur le trajet »).
  final double? distanceAlongM;

  /// [distanceAlongM] est compté depuis la position du motard (« dans 12 km »)
  /// et non depuis le départ de l'itinéraire (« au km 12 »).
  final bool alongFromRider;

  /// Écart à l'itinéraire (mode « sur le trajet »).
  final double? offRouteM;

  bool get onRoute => distanceAlongM != null;

  /// Détour aller-retour estimé (mode trajet).
  double? get detourM => offRouteM == null ? null : offRouteM! * 2;

  /// Distance utilisée pour départager : détour sur le trajet, sinon distance.
  double get proximityM => detourM ?? station.distanceM ?? double.infinity;
}

/// Résumé des prix d'un carburant dans une zone.
class PriceSummary {
  const PriceSummary({
    required this.count,
    required this.min,
    required this.max,
    required this.average,
    required this.cheapest,
  });

  /// Nombre de stations prises en compte pour la moyenne.
  final int count;
  final double min;
  final double max;
  final double average;
  final StationEntry cheapest;

  /// Économie au litre de [price] par rapport à la moyenne (positif = moins cher).
  double savingPerLiter(double price) => average - price;

  /// Économie pour [liters] litres par rapport à la moyenne.
  double savingFor(double price, double liters) => savingPerLiter(price) * liters;
}

/// Calcule min/moyenne/max pour [fuel] et la station la moins chère.
///
/// Les prix périmés (> 3 jours) sont ignorés s'il reste au moins un prix frais.
PriceSummary? summarizePrices(List<StationEntry> entries, FuelType fuel, {required DateTime now}) {
  final priced = entries.where((e) => e.station.priceFor(fuel) != null).toList();
  if (priced.isEmpty) return null;
  final fresh = priced.where((e) => !isPriceStale(e.station.updatedAt[fuel], now: now)).toList();
  final pool = fresh.isNotEmpty ? fresh : priced;
  var minP = double.infinity, maxP = 0.0, sum = 0.0;
  StationEntry? best;
  for (final e in pool) {
    final p = e.station.priceFor(fuel)!;
    sum += p;
    maxP = math.max(maxP, p);
    if (p < minP || (p == minP && best != null && e.proximityM < best.proximityM)) {
      minP = p;
      best = e;
    }
  }
  return PriceSummary(count: pool.length, min: minP, max: maxP, average: sum / pool.length, cheapest: best!);
}

/// Ordre d'affichage des stations.
enum StationSort {
  price('Moins cher'),
  distance('Plus proche'),
  route('Sur le trajet');

  const StationSort(this.label);

  final String label;
}

/// Trie les stations : celles sans prix pour [fuel] passent en dernier.
List<StationEntry> sortStations(List<StationEntry> entries, FuelType fuel, StationSort sort) {
  int byPrice(StationEntry a, StationEntry b) {
    final pa = a.station.priceFor(fuel), pb = b.station.priceFor(fuel);
    if (pa == null && pb == null) return a.proximityM.compareTo(b.proximityM);
    if (pa == null) return 1;
    if (pb == null) return -1;
    final c = pa.compareTo(pb);
    return c != 0 ? c : a.proximityM.compareTo(b.proximityM);
  }

  int byDistance(StationEntry a, StationEntry b) {
    final c = a.proximityM.compareTo(b.proximityM);
    return c != 0 ? c : byPrice(a, b);
  }

  int byRoute(StationEntry a, StationEntry b) {
    final c = (a.distanceAlongM ?? double.infinity).compareTo(b.distanceAlongM ?? double.infinity);
    return c != 0 ? c : byPrice(a, b);
  }

  final out = List.of(entries);
  out.sort(switch (sort) {
    StationSort.price => byPrice,
    StationSort.distance => byDistance,
    StationSort.route => byRoute,
  });
  return out;
}

/// Arrondit une position (~1 km) pour mutualiser les requêtes et le cache.
GeoPoint roundForStationQuery(GeoPoint p) => GeoPoint((p.lat * 100).round() / 100, (p.lng * 100).round() / 100);

// -----------------------------------------------------------------------------
// Pleins

/// Total payé.
double fuelTotal(double liters, double pricePerLiter) => liters * pricePerLiter;

/// Litres à partir du total payé et du prix au litre.
double? litersFromTotal(double total, double pricePerLiter) => pricePerLiter > 0 ? total / pricePerLiter : null;

/// Prix au litre à partir du total et des litres.
double? priceFromTotal(double total, double liters) => liters > 0 ? total / liters : null;

/// Lit un nombre saisi au clavier (« 12,5 », « 12.5 », « 1 234 »).
double? parseUserNumber(String? s) {
  if (s == null) return null;
  final t = s.trim().replaceAll(RegExp(r'[\s  €]'), '').replaceAll(',', '.');
  if (t.isEmpty) return null;
  return double.tryParse(t);
}

/// Bornes de plausibilité d'une consommation moto (L/100 km).
const minPlausibleL100 = 2.0;
const maxPlausibleL100 = 15.0;

bool isPlausibleConsumption(double l100) => l100 >= minPlausibleL100 && l100 <= maxPlausibleL100;

/// Moyenne lissée : la nouvelle mesure compte pour [weight].
double smoothConsumption(double current, double measured, {double weight = 0.4}) =>
    current * (1 - weight) + measured * weight;

/// Distance minimale entre deux pleins complets pour mesurer une consommation.
const minKmForConsumption = 30.0;

/// Consommation « plein à plein » : litres mis depuis le plein complet
/// précédent (appoints compris) divisés par les km parcourus.
///
/// [history] : pleins de la même moto (le plein [entry] peut y figurer, il est
/// ignoré). Les km viennent des compteurs, sinon de [kmFallback].
/// Retourne null s'il n'y a pas de plein complet précédent ou trop peu de km.
double? fullToFullConsumption({required FuelEntry entry, required List<FuelEntry> history, double? kmFallback}) {
  if (!entry.fullTank) return null;
  final before = history.where((e) => e.id != entry.id && !e.date.isAfter(entry.date)).toList()
    ..sort((a, b) => a.date.compareTo(b.date));
  final prevFullIdx = before.lastIndexWhere((e) => e.fullTank);
  if (prevFullIdx < 0) return null;
  final prevFull = before[prevFullIdx];
  var liters = entry.liters;
  for (final e in before.skip(prevFullIdx + 1)) {
    liters += e.liters;
  }
  double? km;
  if (entry.odometerKm != null && prevFull.odometerKm != null) {
    final d = entry.odometerKm! - prevFull.odometerKm!;
    if (d > 0) km = d;
  }
  km ??= kmFallback;
  if (km == null || km < minKmForConsumption) return null;
  return liters / km * 100;
}

/// Résultat de l'enregistrement d'un plein sur une moto.
class FuelEntryOutcome {
  const FuelEntryOutcome({required this.bike, this.measuredL100, this.consumptionUpdated = false});

  /// Moto mise à jour (conso, km depuis le plein, compteur).
  final Bike bike;

  /// Consommation mesurée sur ce plein (null si non mesurable).
  final double? measuredL100;

  /// La conso moyenne de la moto a été ajustée.
  final bool consumptionUpdated;
}

/// Applique un plein à une moto :
/// - plein complet : mesure de la conso plein à plein, lissage de
///   `consumptionL100` si plausible (2–15 L/100), remise à zéro de
///   `kmSinceFullTank` ;
/// - appoint : `kmSinceFullTank` recule de l'équivalent en km des litres mis ;
/// - le compteur est avancé si le plein indique un kilométrage supérieur.
///
/// Un plein saisi après coup (plus ancien qu'un autre plein, ou de plus de
/// 24 h avant [now]) ne touche pas au niveau du réservoir.
///
/// [rideKm] : km de la balade en cours pas encore reportés sur la moto (plein
/// fait en route). Ils sont ajoutés au compteur et aux km depuis le plein
/// avant d'appliquer le plein ; l'appelant les marque comme comptés pour que
/// l'arrêt de la balade ne les ajoute pas une seconde fois.
FuelEntryOutcome applyFuelEntry({
  required Bike bike,
  required FuelEntry entry,
  required List<FuelEntry> history,
  DateTime? now,
  double rideKm = 0,
}) {
  if (rideKm > 0) {
    bike = bike.copyWith(kmSinceFullTank: bike.kmSinceFullTank + rideKm, odometerKm: bike.odometerKm + rideKm);
  }
  final conso = bike.consumptionL100 > 0 ? bike.consumptionL100 : 5.5;
  final odometer = entry.odometerKm != null && entry.odometerKm! > bike.odometerKm
      ? entry.odometerKm!
      : bike.odometerKm;
  final isLatest = !history.any((e) => e.id != entry.id && e.date.isAfter(entry.date));
  final isRecent = now == null || now.toUtc().difference(entry.date.toUtc()) <= const Duration(hours: 24);
  final affectsTank = isLatest && isRecent;

  if (!entry.fullTank) {
    if (!affectsTank) return FuelEntryOutcome(bike: bike.copyWith(odometerKm: odometer));
    final equivalentKm = entry.liters / conso * 100;
    return FuelEntryOutcome(
      bike: bike.copyWith(kmSinceFullTank: math.max(0, bike.kmSinceFullTank - equivalentKm), odometerKm: odometer),
    );
  }

  // Les appoints depuis le dernier plein complet ont fait reculer
  // kmSinceFullTank : on les réintègre pour retrouver les km réels.
  final sorted = history.where((e) => e.id != entry.id && !e.date.isAfter(entry.date)).toList()
    ..sort((a, b) => a.date.compareTo(b.date));
  final prevFullIdx = sorted.lastIndexWhere((e) => e.fullTank);
  var topUpLiters = 0.0;
  if (prevFullIdx >= 0) {
    for (final e in sorted.skip(prevFullIdx + 1)) {
      topUpLiters += e.liters;
    }
  }
  final kmFallback = bike.kmSinceFullTank + topUpLiters / conso * 100;
  final measured = fullToFullConsumption(
    entry: entry,
    history: history,
    // Les km « depuis le plein » ne valent que pour un plein saisi sur le moment.
    kmFallback: affectsTank && kmFallback > 0 ? kmFallback : null,
  );
  final plausible = measured != null && isPlausibleConsumption(measured);
  final newConso = plausible ? smoothConsumption(conso, measured) : conso;
  return FuelEntryOutcome(
    bike: bike.copyWith(
      consumptionL100: (newConso * 100).round() / 100,
      kmSinceFullTank: affectsTank ? 0 : bike.kmSinceFullTank,
      odometerKm: odometer,
    ),
    measuredL100: measured,
    consumptionUpdated: plausible,
  );
}

/// Consommation mesurée pour chaque plein complet de l'historique (par id).
Map<String, double> consumptionPerEntry(List<FuelEntry> entries) {
  final out = <String, double>{};
  for (final e in entries) {
    if (!e.fullTank) continue;
    final c = fullToFullConsumption(entry: e, history: entries);
    if (c != null && isPlausibleConsumption(c)) out[e.id] = c;
  }
  return out;
}

/// Litres à prévoir pour faire le plein (réservoir − restant estimé).
double litersToFill(Bike bike, {double extraKm = 0}) {
  final used = (bike.kmSinceFullTank + extraKm) * bike.consumptionL100 / 100;
  return used.clamp(0, bike.tankLiters).toDouble();
}
