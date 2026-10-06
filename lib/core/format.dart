import 'package:intl/intl.dart';

/// Formatage français des distances, durées, prix et dates.
class Fmt {
  Fmt._();

  static final _dec1 = NumberFormat('#,##0.0', 'fr_FR');
  static final _dec0 = NumberFormat('#,##0', 'fr_FR');
  static final _euro = NumberFormat.currency(locale: 'fr_FR', symbol: '€', decimalDigits: 2);
  static final _price3 = NumberFormat('0.000', 'fr_FR');

  /// « 12,4 km » ou « 850 m ».
  static String distance(double meters) {
    if (meters < 1000) return '${_dec0.format(meters)} m';
    if (meters < 100000) return '${_dec1.format(meters / 1000)} km';
    return '${_dec0.format(meters / 1000)} km';
  }

  /// Valeur numérique seule en km (pour les tuiles de stats).
  static String km(double meters, {int decimals = 1}) =>
      decimals == 0 ? _dec0.format(meters / 1000) : _dec1.format(meters / 1000);

  static String number(double v, {int decimals = 0}) =>
      decimals == 0 ? _dec0.format(v) : NumberFormat('#,##0.${'0' * decimals}', 'fr_FR').format(v);

  /// « 2 h 05 » ou « 12 min ».
  static String duration(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes.remainder(60);
    if (h == 0) return '${d.inMinutes} min';
    return '$h h ${m.toString().padLeft(2, '0')}';
  }

  static String durationS(num seconds) => duration(Duration(seconds: seconds.round()));

  /// Chrono « 1:23:45 ».
  static String chrono(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return h > 0 ? '$h:$m:$s' : '$m:$s';
  }

  static String euros(double v) => _euro.format(v);

  /// Prix au litre « 1,849 € ».
  static String pricePerLiter(double v) => '${_price3.format(v)} €';

  static String speed(double kmh) => '${_dec0.format(kmh)} km/h';

  /// Taille de fichier « 850 Ko » ou « 1,2 Mo ».
  static String fileSize(int bytes) {
    if (bytes < 1024 * 1024) return '${_dec0.format((bytes / 1024).ceil())} Ko';
    return '${_dec1.format(bytes / (1024 * 1024))} Mo';
  }

  static String date(DateTime d) => DateFormat('d MMM yyyy', 'fr_FR').format(d.toLocal());

  static String dateLong(DateTime d) => DateFormat('EEEE d MMMM yyyy', 'fr_FR').format(d.toLocal());

  static String time(DateTime d) => DateFormat('HH:mm', 'fr_FR').format(d.toLocal());

  static String dateTime(DateTime d) => DateFormat("d MMM 'à' HH:mm", 'fr_FR').format(d.toLocal());

  /// « il y a 5 min », « il y a 2 h », « hier »…
  static String ago(DateTime d, {DateTime? now}) {
    final n = (now ?? DateTime.now()).toUtc();
    final diff = n.difference(d.toUtc());
    if (diff.inSeconds < 60) return "à l'instant";
    if (diff.inMinutes < 60) return 'il y a ${diff.inMinutes} min';
    if (diff.inHours < 24) return 'il y a ${diff.inHours} h';
    if (diff.inDays == 1) return 'hier';
    if (diff.inDays < 7) return 'il y a ${diff.inDays} j';
    return date(d);
  }
}
