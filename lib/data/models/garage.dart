import 'package:flutter/material.dart';

/// Carburants disponibles dans les données officielles prix-carburants.gouv.fr.
enum FuelType {
  e10('SP95-E10', 'e10'),
  sp98('SP98', 'sp98'),
  sp95('SP95', 'sp95'),
  e85('E85', 'e85'),
  gazole('Gazole', 'gazole'),
  gplc('GPLc', 'gplc');

  const FuelType(this.label, this.apiKey);

  final String label;

  /// Préfixe des champs dans l'API (ex : `sp98_prix`).
  final String apiKey;

  static FuelType fromName(String? name) =>
      FuelType.values.firstWhere((f) => f.name == name, orElse: () => FuelType.sp98);
}

/// Une moto du garage.
class Bike {
  const Bike({
    required this.id,
    required this.name,
    this.brand = '',
    this.model = '',
    this.year,
    this.odometerKm = 0,
    this.tankLiters = 15,
    this.reserveLiters = 3,
    this.consumptionL100 = 5.5,
    this.fuelType = FuelType.sp98,
    this.colorValue = 0xFFFF6B1A,
    this.isDefault = false,
    this.kmSinceFullTank = 0,
  });

  final String id;
  final String name;
  final String brand;
  final String model;
  final int? year;

  /// Kilométrage compteur (mis à jour automatiquement après chaque balade).
  final double odometerKm;
  final double tankLiters;
  final double reserveLiters;

  /// Consommation moyenne (L/100 km), saisie ou apprise des pleins.
  final double consumptionL100;
  final FuelType fuelType;
  final int colorValue;
  final bool isDefault;

  /// Km parcourus depuis le dernier plein complet (pour l'autonomie).
  final double kmSinceFullTank;

  Color get color => Color(colorValue);

  Bike copyWith({
    String? name,
    String? brand,
    String? model,
    int? year,
    double? odometerKm,
    double? tankLiters,
    double? reserveLiters,
    double? consumptionL100,
    FuelType? fuelType,
    int? colorValue,
    bool? isDefault,
    double? kmSinceFullTank,
  }) =>
      Bike(
        id: id,
        name: name ?? this.name,
        brand: brand ?? this.brand,
        model: model ?? this.model,
        year: year ?? this.year,
        odometerKm: odometerKm ?? this.odometerKm,
        tankLiters: tankLiters ?? this.tankLiters,
        reserveLiters: reserveLiters ?? this.reserveLiters,
        consumptionL100: consumptionL100 ?? this.consumptionL100,
        fuelType: fuelType ?? this.fuelType,
        colorValue: colorValue ?? this.colorValue,
        isDefault: isDefault ?? this.isDefault,
        kmSinceFullTank: kmSinceFullTank ?? this.kmSinceFullTank,
      );

  Map<String, Object?> toDb() => {
        'id': id,
        'name': name,
        'brand': brand,
        'model': model,
        'year': year,
        'odometer_km': odometerKm,
        'tank_l': tankLiters,
        'reserve_l': reserveLiters,
        'conso_l100': consumptionL100,
        'fuel_type': fuelType.name,
        'color': colorValue,
        'is_default': isDefault ? 1 : 0,
        'km_since_full': kmSinceFullTank,
      };

  factory Bike.fromDb(Map<String, Object?> r) => Bike(
        id: r['id'] as String,
        name: r['name'] as String,
        brand: (r['brand'] as String?) ?? '',
        model: (r['model'] as String?) ?? '',
        year: r['year'] as int?,
        odometerKm: (r['odometer_km'] as num?)?.toDouble() ?? 0,
        tankLiters: (r['tank_l'] as num?)?.toDouble() ?? 15,
        reserveLiters: (r['reserve_l'] as num?)?.toDouble() ?? 3,
        consumptionL100: (r['conso_l100'] as num?)?.toDouble() ?? 5.5,
        fuelType: FuelType.fromName(r['fuel_type'] as String?),
        colorValue: (r['color'] as int?) ?? 0xFFFF6B1A,
        isDefault: (r['is_default'] as int? ?? 0) == 1,
        kmSinceFullTank: (r['km_since_full'] as num?)?.toDouble() ?? 0,
      );
}

/// Un plein (ou appoint) d'essence.
class FuelEntry {
  const FuelEntry({
    required this.id,
    required this.date,
    required this.liters,
    required this.pricePerLiter,
    this.bikeId,
    this.rideId,
    this.odometerKm,
    this.fullTank = true,
    this.stationId,
    this.stationName = '',
    this.fuelType = FuelType.sp98,
    this.lat,
    this.lng,
  });

  final String id;
  final DateTime date;
  final double liters;
  final double pricePerLiter;
  final String? bikeId;

  /// Balade pendant laquelle le plein a été fait (pour le coût de la balade).
  final String? rideId;
  final double? odometerKm;
  final bool fullTank;
  final String? stationId;
  final String stationName;
  final FuelType fuelType;
  final double? lat;
  final double? lng;

  double get total => liters * pricePerLiter;

  Map<String, Object?> toDb() => {
        'id': id,
        'date': date.millisecondsSinceEpoch,
        'liters': liters,
        'price_per_l': pricePerLiter,
        'bike_id': bikeId,
        'ride_id': rideId,
        'odometer_km': odometerKm,
        'full_tank': fullTank ? 1 : 0,
        'station_id': stationId,
        'station_name': stationName,
        'fuel_type': fuelType.name,
        'lat': lat,
        'lng': lng,
      };

  factory FuelEntry.fromDb(Map<String, Object?> r) => FuelEntry(
        id: r['id'] as String,
        date: DateTime.fromMillisecondsSinceEpoch(r['date'] as int, isUtc: true),
        liters: (r['liters'] as num).toDouble(),
        pricePerLiter: (r['price_per_l'] as num).toDouble(),
        bikeId: r['bike_id'] as String?,
        rideId: r['ride_id'] as String?,
        odometerKm: (r['odometer_km'] as num?)?.toDouble(),
        fullTank: (r['full_tank'] as int? ?? 1) == 1,
        stationId: r['station_id'] as String?,
        stationName: (r['station_name'] as String?) ?? '',
        fuelType: FuelType.fromName(r['fuel_type'] as String?),
        lat: (r['lat'] as num?)?.toDouble(),
        lng: (r['lng'] as num?)?.toDouble(),
      );
}

/// Catégories de dépenses d'une balade (hors essence, gérée par [FuelEntry]).
enum ExpenseCategory {
  peage('Péage', Icons.toll),
  resto('Resto / café', Icons.restaurant),
  parking('Parking', Icons.local_parking),
  equipement('Équipement', Icons.sports_motorsports),
  entretien('Entretien', Icons.build),
  autre('Autre', Icons.receipt_long);

  const ExpenseCategory(this.label, this.icon);

  final String label;
  final IconData icon;

  static ExpenseCategory fromName(String? n) =>
      ExpenseCategory.values.firstWhere((c) => c.name == n, orElse: () => ExpenseCategory.autre);
}

/// Une dépense personnelle (péage, resto…), éventuellement liée à une balade.
class Expense {
  const Expense({
    required this.id,
    required this.date,
    required this.amount,
    required this.category,
    this.label = '',
    this.rideId,
    this.bikeId,
  });

  final String id;
  final DateTime date;
  final double amount;
  final ExpenseCategory category;
  final String label;
  final String? rideId;
  final String? bikeId;

  Map<String, Object?> toDb() => {
        'id': id,
        'date': date.millisecondsSinceEpoch,
        'amount': amount,
        'category': category.name,
        'label': label,
        'ride_id': rideId,
        'bike_id': bikeId,
      };

  factory Expense.fromDb(Map<String, Object?> r) => Expense(
        id: r['id'] as String,
        date: DateTime.fromMillisecondsSinceEpoch(r['date'] as int, isUtc: true),
        amount: (r['amount'] as num).toDouble(),
        category: ExpenseCategory.fromName(r['category'] as String?),
        label: (r['label'] as String?) ?? '',
        rideId: r['ride_id'] as String?,
        bikeId: r['bike_id'] as String?,
      );
}

/// Types d'entretien prédéfinis avec intervalles par défaut.
enum MaintenanceType {
  chaine('Graissage chaîne', Icons.link, 600, null),
  tensionChaine('Tension chaîne', Icons.settings_input_component, 1500, null),
  vidange('Vidange', Icons.oil_barrel, 6000, 12),
  pneuAvant('Pneu avant', Icons.trip_origin, 12000, null),
  pneuArriere('Pneu arrière', Icons.trip_origin, 9000, null),
  plaquettes('Plaquettes de frein', Icons.album, 12000, null),
  liquideFrein('Liquide de frein', Icons.water_drop, null, 24),
  revision('Révision', Icons.build_circle, 12000, 12),
  pressionPneus('Pression pneus', Icons.compress, null, 1),
  autre('Autre', Icons.handyman, null, null);

  const MaintenanceType(this.label, this.icon, this.defaultIntervalKm, this.defaultIntervalMonths);

  final String label;
  final IconData icon;
  final int? defaultIntervalKm;
  final int? defaultIntervalMonths;

  static MaintenanceType fromName(String? n) =>
      MaintenanceType.values.firstWhere((t) => t.name == n, orElse: () => MaintenanceType.autre);
}

/// Un élément d'entretien suivi pour une moto.
class MaintenanceItem {
  const MaintenanceItem({
    required this.id,
    required this.bikeId,
    required this.type,
    this.label = '',
    this.intervalKm,
    this.intervalMonths,
    this.lastDoneKm,
    this.lastDoneDate,
    this.notes = '',
  });

  final String id;
  final String bikeId;
  final MaintenanceType type;
  final String label;
  final int? intervalKm;
  final int? intervalMonths;
  final double? lastDoneKm;
  final DateTime? lastDoneDate;
  final String notes;

  String get displayName => label.isNotEmpty ? label : type.label;

  MaintenanceItem copyWith({
    String? label,
    int? intervalKm,
    int? intervalMonths,
    double? lastDoneKm,
    DateTime? lastDoneDate,
    String? notes,
  }) =>
      MaintenanceItem(
        id: id,
        bikeId: bikeId,
        type: type,
        label: label ?? this.label,
        intervalKm: intervalKm ?? this.intervalKm,
        intervalMonths: intervalMonths ?? this.intervalMonths,
        lastDoneKm: lastDoneKm ?? this.lastDoneKm,
        lastDoneDate: lastDoneDate ?? this.lastDoneDate,
        notes: notes ?? this.notes,
      );

  Map<String, Object?> toDb() => {
        'id': id,
        'bike_id': bikeId,
        'type': type.name,
        'label': label,
        'interval_km': intervalKm,
        'interval_months': intervalMonths,
        'last_done_km': lastDoneKm,
        'last_done_date': lastDoneDate?.millisecondsSinceEpoch,
        'notes': notes,
      };

  factory MaintenanceItem.fromDb(Map<String, Object?> r) => MaintenanceItem(
        id: r['id'] as String,
        bikeId: r['bike_id'] as String,
        type: MaintenanceType.fromName(r['type'] as String?),
        label: (r['label'] as String?) ?? '',
        intervalKm: r['interval_km'] as int?,
        intervalMonths: r['interval_months'] as int?,
        lastDoneKm: (r['last_done_km'] as num?)?.toDouble(),
        lastDoneDate: r['last_done_date'] == null
            ? null
            : DateTime.fromMillisecondsSinceEpoch(r['last_done_date'] as int, isUtc: true),
        notes: (r['notes'] as String?) ?? '',
      );
}

/// Historique d'une opération d'entretien réalisée.
class MaintenanceLog {
  const MaintenanceLog({
    required this.id,
    required this.itemId,
    required this.bikeId,
    required this.date,
    this.odometerKm,
    this.cost,
    this.notes = '',
  });

  final String id;
  final String itemId;
  final String bikeId;
  final DateTime date;
  final double? odometerKm;
  final double? cost;
  final String notes;

  Map<String, Object?> toDb() => {
        'id': id,
        'item_id': itemId,
        'bike_id': bikeId,
        'date': date.millisecondsSinceEpoch,
        'odometer_km': odometerKm,
        'cost': cost,
        'notes': notes,
      };

  factory MaintenanceLog.fromDb(Map<String, Object?> r) => MaintenanceLog(
        id: r['id'] as String,
        itemId: r['item_id'] as String,
        bikeId: r['bike_id'] as String,
        date: DateTime.fromMillisecondsSinceEpoch(r['date'] as int, isUtc: true),
        odometerKm: (r['odometer_km'] as num?)?.toDouble(),
        cost: (r['cost'] as num?)?.toDouble(),
        notes: (r['notes'] as String?) ?? '',
      );
}
