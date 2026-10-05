// Logique pure du carnet d'entretien : échéances, statuts, éléments par défaut.
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/format.dart';
import '../../core/theme.dart';
import '../../data/models/garage.dart';

/// Statut d'un élément d'entretien.
enum MaintenanceStatus {
  ok('À jour', CmColors.green, Icons.check_circle_rounded, 0),
  soon('Bientôt', CmColors.amber, Icons.schedule_rounded, 1),
  due('À faire', CmColors.orange, Icons.build_circle_rounded, 2),
  overdue('En retard', CmColors.red, Icons.warning_amber_rounded, 3),
  none('Sans échéance', Color(0xFF8A93A3), Icons.remove_circle_outline, -1);

  const MaintenanceStatus(this.label, this.color, this.icon, this.severity);

  final String label;
  final Color color;
  final IconData icon;

  /// Gravité croissante (-1 = sans échéance).
  final int severity;

  bool get needsAttention => severity >= 1;
}

/// Part de l'intervalle sous laquelle l'échéance est « bientôt ».
const maintenanceSoonRatio = 0.10;

/// Dépassement (en part de l'intervalle) au-delà duquel c'est « en retard ».
const maintenanceOverdueRatio = 0.10;

/// Ajoute [months] mois à une date (jour borné à la fin du mois).
DateTime addMonths(DateTime d, int months) {
  final total = d.month - 1 + months;
  final year = d.year + (total >= 0 ? total ~/ 12 : -((-total + 11) ~/ 12));
  final month = total % 12 + 1;
  final lastDay = DateTime.utc(year, month + 1, 0).day;
  final day = math.min(d.day, lastDay);
  return d.isUtc
      ? DateTime.utc(year, month, day, d.hour, d.minute, d.second)
      : DateTime(year, month, day, d.hour, d.minute, d.second);
}

/// État calculé d'un élément d'entretien à un instant donné.
class MaintenanceState {
  const MaintenanceState({
    required this.item,
    required this.status,
    this.kmSince,
    this.kmRemaining,
    this.daysSince,
    this.daysRemaining,
    this.dueDate,
    this.progress = 0,
    this.neverDone = false,
    this.drivenByKm = true,
  });

  final MaintenanceItem item;
  final MaintenanceStatus status;

  /// Km parcourus depuis la dernière fois.
  final double? kmSince;

  /// Km avant l'échéance (négatif = dépassé).
  final double? kmRemaining;
  final int? daysSince;

  /// Jours avant l'échéance (négatif = dépassé).
  final int? daysRemaining;
  final DateTime? dueDate;

  /// Part de l'intervalle consommée (0 = juste fait, 1 = échéance, > 1 = dépassé),
  /// critère le plus avancé entre km et durée.
  final double progress;

  /// Jamais renseigné.
  final bool neverDone;

  /// Le statut est dicté par le kilométrage (sinon par la durée).
  final bool drivenByKm;

  String get name => item.displayName;

  /// Résumé court : « encore 450 km », « dans 3 mois », « 120 km de retard »…
  String get summary {
    if (neverDone) return 'Jamais renseigné';
    if (status == MaintenanceStatus.none) {
      return kmSince != null ? '${Fmt.number(kmSince!)} km depuis la dernière fois' : 'Pas d\'échéance';
    }
    final parts = <String>[];
    if (kmRemaining != null) {
      parts.add(
        kmRemaining! >= 0 ? 'encore ${Fmt.number(kmRemaining!)} km' : '${Fmt.number(-kmRemaining!)} km de retard',
      );
    }
    if (daysRemaining != null) {
      parts.add(daysRemaining! >= 0 ? _inDays(daysRemaining!) : '${_span(-daysRemaining!)} de retard');
    }
    return parts.join(' · ');
  }

  static String _inDays(int days) {
    if (days == 0) return "aujourd'hui";
    return 'dans ${_span(days)}';
  }

  static String _span(int days) {
    if (days < 45) return '$days j';
    final months = (days / 30.4).round();
    if (months < 24) return '$months mois';
    return '${(days / 365.25).round()} ans';
  }
}

MaintenanceStatus _statusFor(double remainingRatio) {
  if (remainingRatio < -maintenanceOverdueRatio) return MaintenanceStatus.overdue;
  if (remainingRatio <= 0) return MaintenanceStatus.due;
  if (remainingRatio < maintenanceSoonRatio) return MaintenanceStatus.soon;
  return MaintenanceStatus.ok;
}

/// Évalue un élément d'entretien selon le compteur et la date du jour.
MaintenanceState evaluateMaintenance(MaintenanceItem item, {required double odometerKm, required DateTime now}) {
  final hasKm = (item.intervalKm ?? 0) > 0;
  final hasTime = (item.intervalMonths ?? 0) > 0;
  final neverDone = item.lastDoneKm == null && item.lastDoneDate == null;

  double? kmSince, kmRemaining;
  int? daysSince, daysRemaining;
  DateTime? dueDate;
  double kmProgress = -1, timeProgress = -1;
  var status = MaintenanceStatus.none;
  var drivenByKm = true;

  if (item.lastDoneKm != null) {
    kmSince = math.max(0, odometerKm - item.lastDoneKm!).toDouble();
  }
  if (item.lastDoneDate != null) {
    daysSince = math.max(0, now.toUtc().difference(item.lastDoneDate!.toUtc()).inDays);
  }

  if (neverDone && (hasKm || hasTime)) {
    return MaintenanceState(item: item, status: MaintenanceStatus.due, progress: 1, neverDone: true, drivenByKm: hasKm);
  }

  if (hasKm && kmSince != null) {
    final interval = item.intervalKm!.toDouble();
    kmRemaining = interval - kmSince;
    kmProgress = kmSince / interval;
    status = _statusFor(kmRemaining / interval);
  }
  if (hasTime && item.lastDoneDate != null) {
    final last = item.lastDoneDate!.toUtc();
    dueDate = addMonths(last, item.intervalMonths!);
    final totalDays = math.max(1, dueDate.difference(last).inDays);
    daysRemaining = dueDate.difference(now.toUtc()).inHours ~/ 24;
    if (dueDate.isBefore(now.toUtc()) && daysRemaining == 0) daysRemaining = -1;
    timeProgress = (daysSince ?? 0) / totalDays;
    final timeStatus = _statusFor(daysRemaining / totalDays);
    if (timeStatus.severity > status.severity ||
        (timeStatus.severity == status.severity && timeProgress > kmProgress)) {
      status = timeStatus;
      drivenByKm = false;
    }
  }
  // Intervalle en km mais aucun relevé km (seulement une date) : on ne sait pas.
  if (hasKm && kmSince == null && !hasTime) {
    status = MaintenanceStatus.due;
  }

  return MaintenanceState(
    item: item,
    status: status,
    kmSince: kmSince,
    kmRemaining: kmRemaining,
    daysSince: daysSince,
    daysRemaining: daysRemaining,
    dueDate: dueDate,
    progress: math.max(0, math.max(kmProgress, timeProgress)).toDouble(),
    drivenByKm: drivenByKm,
  );
}

/// Évalue et trie : le plus urgent d'abord.
List<MaintenanceState> evaluateAllMaintenance(
  List<MaintenanceItem> items, {
  required double odometerKm,
  required DateTime now,
}) {
  final out = [for (final i in items) evaluateMaintenance(i, odometerKm: odometerKm, now: now)];
  out.sort((a, b) {
    final s = b.status.severity.compareTo(a.status.severity);
    if (s != 0) return s;
    return b.progress.compareTo(a.progress);
  });
  return out;
}

/// Message de rappel (null si rien à signaler).
String? maintenanceMessage(MaintenanceState s) {
  if (!s.status.needsAttention) return null;
  final name = s.name;
  if (s.neverDone) return '$name à faire (jamais renseigné)';
  String detail() {
    if (s.drivenByKm && s.kmSince != null) return '${Fmt.number(s.kmSince!)} km depuis la dernière fois';
    final days = s.daysSince ?? 0;
    if (days < 45) return 'fait il y a $days j';
    return 'fait il y a ${(days / 30.4).round()} mois';
  }

  switch (s.status) {
    case MaintenanceStatus.overdue:
      return '$name en retard (${detail()})';
    case MaintenanceStatus.due:
      return '$name à faire (${detail()})';
    case MaintenanceStatus.soon:
      if (s.drivenByKm && s.kmRemaining != null) {
        return '$name bientôt : encore ${Fmt.number(s.kmRemaining!)} km';
      }
      if (s.daysRemaining != null) return '$name bientôt : ${MaintenanceState._inDays(s.daysRemaining!)}';
      return '$name bientôt';
    default:
      return null;
  }
}

/// Éléments créés avec une nouvelle moto (intervalles par défaut).
/// On part du principe que tout est à jour au moment de l'ajout.
List<MaintenanceItem> defaultMaintenanceItems(Bike bike, {required DateTime now, required String Function() newId}) {
  return [
    for (final t in MaintenanceType.values)
      if (t != MaintenanceType.autre)
        MaintenanceItem(
          id: newId(),
          bikeId: bike.id,
          type: t,
          intervalKm: t.defaultIntervalKm,
          intervalMonths: t.defaultIntervalMonths,
          lastDoneKm: bike.odometerKm,
          lastDoneDate: now.toUtc(),
        ),
  ];
}

/// « Fait aujourd'hui » : l'élément repart de zéro au compteur actuel.
MaintenanceItem markMaintenanceDone(MaintenanceItem item, {required double odometerKm, required DateTime date}) =>
    item.copyWith(lastDoneKm: odometerKm, lastDoneDate: date.toUtc());

/// Entrée d'historique correspondante.
MaintenanceLog maintenanceLogFor(
  MaintenanceItem item, {
  required String id,
  required double odometerKm,
  required DateTime date,
  double? cost,
  String notes = '',
}) => MaintenanceLog(
  id: id,
  itemId: item.id,
  bikeId: item.bikeId,
  date: date.toUtc(),
  odometerKm: odometerKm,
  cost: cost,
  notes: notes,
);

/// Copie d'un élément avec des intervalles éventuellement effacés (null).
/// (`MaintenanceItem.copyWith` ne permet pas de remettre un champ à null.)
MaintenanceItem editMaintenanceItem(
  MaintenanceItem item, {
  required String label,
  required int? intervalKm,
  required int? intervalMonths,
  required double? lastDoneKm,
  required DateTime? lastDoneDate,
  String? notes,
}) => MaintenanceItem(
  id: item.id,
  bikeId: item.bikeId,
  type: item.type,
  label: label,
  intervalKm: (intervalKm ?? 0) > 0 ? intervalKm : null,
  intervalMonths: (intervalMonths ?? 0) > 0 ? intervalMonths : null,
  lastDoneKm: lastDoneKm,
  lastDoneDate: lastDoneDate?.toUtc(),
  notes: notes ?? item.notes,
);
