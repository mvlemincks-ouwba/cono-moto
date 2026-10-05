/// Nom automatique d'une balade, façon motard.
///
/// Exemples : « Balade du dimanche matin », « Petit tour du mardi midi »,
/// « Belle virée du samedi après-midi », « Balade nocturne du vendredi ».
/// Si un itinéraire planifié a été suivi, son nom est repris.
String autoRideName(DateTime start, {double distanceKm = 0, String? routeName}) {
  final route = routeName?.trim();
  if (route != null && route.isNotEmpty) return route;

  final local = start.toLocal();
  const days = ['lundi', 'mardi', 'mercredi', 'jeudi', 'vendredi', 'samedi', 'dimanche'];
  final day = days[local.weekday - 1];

  final String prefix;
  if (distanceKm < 30) {
    prefix = 'Petit tour';
  } else if (distanceKm < 150) {
    prefix = 'Balade';
  } else if (distanceKm < 300) {
    prefix = 'Belle virée';
  } else {
    prefix = 'Road trip';
  }

  final h = local.hour;
  if (h >= 22 || h < 5) return '$prefix nocturne du $day';
  final String moment;
  if (h < 11) {
    moment = 'matin';
  } else if (h < 14) {
    moment = 'midi';
  } else if (h < 18) {
    moment = 'après-midi';
  } else {
    moment = 'soir';
  }
  return '$prefix du $day $moment';
}
