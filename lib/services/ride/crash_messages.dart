import '../../core/geo.dart';

/// Lien Google Maps vers une position (s'ouvre sur n'importe quel téléphone).
String mapsLink(GeoPoint p) => 'https://maps.google.com/?q=${p.lat.toStringAsFixed(5)},${p.lng.toStringAsFixed(5)}';

/// SMS envoyé au contact d'urgence quand personne n'a répondu à l'alerte de chute.
String buildCrashSms({GeoPoint? at, double? accuracyM, DateTime? time}) {
  // Heure formatée à la main : ce message ne doit jamais échouer (pas d'intl).
  final local = time?.toLocal();
  final when = local == null
      ? ''
      : ' à ${local.hour.toString().padLeft(2, '0')}h${local.minute.toString().padLeft(2, '0')}';
  final where = at == null
      ? 'Position GPS indisponible.'
      : 'Position : ${mapsLink(at)}'
            '${accuracyM != null && accuracyM > 0 ? ' (±${accuracyM.round()} m)' : ''}';
  return 'Cono Moto : chute de moto probable détectée$when, sans réponse depuis 1 min. '
      '$where Appelle-moi et, si je ne réponds pas, préviens les secours (112).';
}

/// Message diffusé aux potes (alerte SOS).
String buildCrashSosMessage() => 'Chute détectée, pas de réponse depuis 1 min';

/// SMS de levée de doute après une fausse alerte.
String buildFalseAlarmSms() => 'Cono Moto : fausse alerte, tout va bien ! Désolé pour la frayeur.';
