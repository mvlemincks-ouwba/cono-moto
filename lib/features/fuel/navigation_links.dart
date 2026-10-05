import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/geo.dart';
import '../../core/ui/widgets.dart';

/// Applications de navigation externes proposées pour « Y aller ».
enum NavApp {
  googleMaps('Google Maps', Icons.map),
  waze('Waze', Icons.navigation);

  const NavApp(this.label, this.icon);

  final String label;
  final IconData icon;
}

String _c(double v) => v.toStringAsFixed(6);

/// Itinéraire Google Maps en mode deux-roues.
Uri googleMapsDirectionsUri(GeoPoint p) =>
    Uri.parse('https://www.google.com/maps/dir/?api=1&destination=${_c(p.lat)},${_c(p.lng)}&travelmode=two-wheeler');

/// Navigation Waze.
Uri wazeNavigateUri(GeoPoint p) => Uri.parse('https://waze.com/ul?ll=${_c(p.lat)},${_c(p.lng)}&navigate=yes');

Uri navigationUri(NavApp app, GeoPoint p) => switch (app) {
  NavApp.googleMaps => googleMapsDirectionsUri(p),
  NavApp.waze => wazeNavigateUri(p),
};

/// Ouvre l'appli de navigation (ou le navigateur à défaut).
Future<void> openNavigation(BuildContext context, NavApp app, GeoPoint destination) async {
  final uri = navigationUri(app, destination);
  var ok = false;
  try {
    ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
  } catch (_) {
    ok = false;
  }
  if (!ok && context.mounted) {
    showCmSnack(context, "Impossible d'ouvrir ${app.label}.", error: true);
  }
}

/// Petit menu « Y aller » : Google Maps ou Waze.
class GoThereButton extends StatelessWidget {
  const GoThereButton({super.key, required this.destination, this.filled = false});

  final GeoPoint destination;
  final bool filled;

  @override
  Widget build(BuildContext context) {
    return MenuAnchor(
      builder: (context, controller, _) {
        void toggle() => controller.isOpen ? controller.close() : controller.open();
        const icon = Icon(Icons.directions, size: 20);
        const label = Text('Y aller');
        return filled
            ? FilledButton.icon(onPressed: toggle, icon: icon, label: label)
            : TextButton.icon(onPressed: toggle, icon: icon, label: label);
      },
      menuChildren: [
        for (final app in NavApp.values)
          MenuItemButton(
            leadingIcon: Icon(app.icon),
            onPressed: () => openNavigation(context, app, destination),
            child: Text('Avec ${app.label}'),
          ),
      ],
    );
  }
}
