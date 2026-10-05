import 'dart:ui' show Color;

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

/// Canaux de notification de l'app.
enum CmChannel {
  ride('ride', 'Balade', 'Alertes pendant la balade (autonomie, potes, météo)', Importance.high),
  safety('safety', 'Sécurité', 'Détection de chute et alertes SOS', Importance.max),
  friends('friends', 'Potes', 'Activité de tes potes', Importance.defaultImportance),
  garage('garage', 'Garage', 'Rappels d\'entretien', Importance.defaultImportance);

  const CmChannel(this.id, this.name, this.description, this.importance);

  final String id;
  final String name;
  final String description;
  final Importance importance;
}

/// Notifications locales (sans serveur).
class Notifications {
  Notifications._();

  static final _plugin = FlutterLocalNotificationsPlugin();
  static bool _ready = false;

  static Future<void> init() async {
    if (_ready) return;
    try {
      await _plugin.initialize(
        settings: const InitializationSettings(
          android: AndroidInitializationSettings('@mipmap/ic_launcher'),
          // iPhone : pas de demande au lancement (l'accueil la fait au bon
          // moment, voir [requestPermission]) ; notifications affichées même
          // app ouverte.
          iOS: DarwinInitializationSettings(
            requestAlertPermission: false,
            requestBadgePermission: false,
            requestSoundPermission: false,
          ),
        ),
      );
      _ready = true;
    } catch (e) {
      debugPrint('Notifications indisponibles : $e');
    }
  }

  static Future<void> requestPermission() async {
    await init();
    if (!_ready) return;
    try {
      await _plugin
          .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
          ?.requestNotificationsPermission();
      // Alertes critiques (qui passent outre le mode silencieux) non demandées :
      // elles exigent un droit spécial d'Apple.
      await _plugin
          .resolvePlatformSpecificImplementation<IOSFlutterLocalNotificationsPlugin>()
          ?.requestPermissions(alert: true, badge: true, sound: true);
    } catch (e) {
      debugPrint('Permission notifications : $e');
    }
  }

  static Future<void> show({
    required int id,
    required String title,
    required String body,
    CmChannel channel = CmChannel.ride,
    bool ongoing = false,
  }) async {
    await init();
    if (!_ready) return;
    try {
      await _plugin.show(
        id: id,
        title: title,
        body: body,
        notificationDetails: NotificationDetails(
          android: AndroidNotificationDetails(
            channel.id,
            channel.name,
            channelDescription: channel.description,
            importance: channel.importance,
            priority: channel.importance == Importance.max ? Priority.max : Priority.high,
            ongoing: ongoing,
            color: const Color(0xFFFF6B1A),
            category: channel == CmChannel.safety ? AndroidNotificationCategory.alarm : null,
            fullScreenIntent: channel == CmChannel.safety,
          ),
          iOS: DarwinNotificationDetails(
            presentAlert: true,
            presentBanner: true,
            presentList: true,
            presentSound: true,
            // Regroupe les notifications par thème dans le centre de notifications.
            threadIdentifier: channel.id,
          ),
        ),
      );
    } catch (e) {
      debugPrint('Notification non affichée : $e');
    }
  }

  static Future<void> cancel(int id) async {
    if (!_ready) return;
    await _plugin.cancel(id: id);
  }
}
