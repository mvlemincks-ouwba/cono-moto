import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/geo.dart';
import '../../core/location.dart';
import '../../core/theme.dart';
import '../../core/ui/widgets.dart';
import '../../data/models/shared.dart';
import '../../services/social/social_api.dart';
import '../ride/ride_screen.dart';
import '../social/social_providers.dart';
import '../social/social_sheets.dart';

/// Types proposés en un geste (le reste via « Plus… »).
const quickReportTypes = [
  ReportType.danger,
  ReportType.police,
  ReportType.gravillons,
  ReportType.accident,
  ReportType.huile,
  ReportType.travaux,
  ReportType.animal,
  ReportType.routeDegradee,
];

/// Signalement en roulant, en deux touches : « Signaler » puis le type.
/// La position est prise au premier appui (à 90 km/h, on fait 25 m par
/// seconde). Sans compte entre potes, ouvre la feuille complète qui explique
/// quoi faire.
Future<void> showQuickReportSheet(BuildContext context, WidgetRef ref) async {
  final here = ref.read(positionHubProvider)?.point;
  if (here == null) {
    showCmSnack(context, 'Position GPS pas encore dispo, réessaie dans un instant.');
    return;
  }
  HapticFeedback.selectionClick();
  final ready =
      ref.read(socialApiProvider) != null &&
      ref.read(myUidProvider) != null &&
      ref.read(myProfileProvider).value != null;
  if (!ready) {
    await showReportSheet(context, at: here);
    return;
  }
  final choice = await showModalBottomSheet<Object>(
    context: context,
    isScrollControlled: true,
    builder: (ctx) => Theme(data: RideScreen.hudTheme, child: const QuickReportGrid()),
  );
  if (!context.mounted || choice == null) return;
  if (choice is! ReportType) {
    await showReportSheet(context, at: here);
    return;
  }
  await _send(context, ref, choice, here);
}

Future<void> _send(BuildContext context, WidgetRef ref, ReportType type, GeoPoint at) async {
  HapticFeedback.mediumImpact();
  try {
    final synced = await ref.read(socialActionsProvider).addReport(type: type, at: at);
    if (!context.mounted) return;
    showCmSnack(
      context,
      synced
          ? '${type.label} signalé à tes potes. Merci !'
          : '${type.label} en file : envoi dès que le réseau revient.',
    );
  } on SocialException catch (e) {
    if (context.mounted) showCmSnack(context, e.message, error: true);
  } catch (_) {
    if (context.mounted) showCmSnack(context, 'Signalement impossible pour le moment.', error: true);
  }
}

/// Grille de gros boutons (utilisables avec des gants). Renvoie le
/// [ReportType] choisi, ou `'more'` pour la feuille complète.
class QuickReportGrid extends StatelessWidget {
  const QuickReportGrid({super.key});

  @override
  Widget build(BuildContext context) {
    final tiles = <Widget>[
      for (final t in quickReportTypes)
        _ReportTile(icon: t.icon, color: t.color, label: t.label, onTap: () => Navigator.pop(context, t)),
      _ReportTile(
        icon: Icons.more_horiz_rounded,
        color: const Color(0xFF9AA3B2),
        label: 'Plus…',
        onTap: () => Navigator.pop(context, 'more'),
      ),
    ];
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: LayoutBuilder(
          builder: (context, c) {
            final columns = c.maxWidth > 560 ? 5 : 3;
            return Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    const Icon(Icons.campaign_rounded, color: CmColors.orange, size: 30),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text('Signaler à tes potes', style: CmTheme.numbers(size: 30, color: Colors.white)),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                const Text(
                  'Un appui suffit : c\'est posé là où tu es.',
                  style: TextStyle(color: Colors.white70, fontSize: 15, fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 14),
                Flexible(
                  child: GridView.count(
                    shrinkWrap: true,
                    crossAxisCount: columns,
                    mainAxisSpacing: 10,
                    crossAxisSpacing: 10,
                    childAspectRatio: columns == 3 ? 0.88 : 1.05,
                    children: tiles,
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _ReportTile extends StatelessWidget {
  const _ReportTile({required this.icon, required this.color, required this.label, required this.onTap});

  final IconData icon;
  final Color color;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: label,
      child: Material(
        color: color.withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(22),
        child: InkWell(
          borderRadius: BorderRadius.circular(22),
          onTap: onTap,
          child: Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(22),
              border: Border.all(color: color.withValues(alpha: 0.55), width: 2),
            ),
            padding: const EdgeInsets.all(8),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Container(
                  width: 50,
                  height: 50,
                  decoration: BoxDecoration(color: color, shape: BoxShape.circle),
                  child: Icon(icon, color: Colors.white, size: 30),
                ),
                const SizedBox(height: 6),
                Text(
                  label,
                  maxLines: 2,
                  textAlign: TextAlign.center,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.w800, height: 1.1),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
