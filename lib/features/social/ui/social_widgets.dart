import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/format.dart';
import '../../../core/geo.dart';
import '../../../core/providers.dart';
import '../../../core/theme.dart';
import '../../../core/ui/widgets.dart';
import '../../home/home_shell.dart';
import '../social_models.dart';

/// Couleur de texte lisible sur une couleur de fond donnée.
Color onColor(Color c) => c.computeLuminance() > 0.45 ? CmColors.asphalt900 : Colors.white;

/// Avatar rond d'un motard : initiales sur sa couleur, anneau vert s'il roule,
/// rouge en cas de SOS.
class RiderAvatar extends StatelessWidget {
  const RiderAvatar({
    super.key,
    required this.name,
    required this.color,
    this.size = 44,
    this.riding = false,
    this.sos = false,
    this.icon,
  });

  final String name;
  final Color color;
  final double size;
  final bool riding;
  final bool sos;

  /// Icône à la place des initiales.
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final ring = sos ? CmColors.red : (riding ? CmColors.green : null);
    final bg = Theme.of(context).colorScheme.surface;
    return SizedBox(
      width: size,
      height: size,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Container(
            width: size,
            height: size,
            padding: EdgeInsets.all(ring == null ? 0 : 2.5),
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: ring == null ? null : Border.all(color: ring, width: 2.5),
              boxShadow: [
                BoxShadow(color: color.withValues(alpha: 0.35), blurRadius: size * 0.25, spreadRadius: -2),
              ],
            ),
            child: DecoratedBox(
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [Color.lerp(color, Colors.white, 0.18)!, color],
                ),
              ),
              child: Center(
                child: icon != null
                    ? Icon(icon, size: size * 0.48, color: onColor(color))
                    : Text(
                        initialsOf(name),
                        style: CmTheme.numbers(size: size * 0.42, color: onColor(color), weight: FontWeight.w800),
                      ),
              ),
            ),
          ),
          if (sos || riding)
            Positioned(
              right: -2,
              bottom: -2,
              child: Container(
                width: size * 0.38,
                height: size * 0.38,
                decoration: BoxDecoration(
                  color: sos ? CmColors.red : CmColors.green,
                  shape: BoxShape.circle,
                  border: Border.all(color: bg, width: 2),
                ),
                child: Icon(
                  sos ? Icons.priority_high_rounded : Icons.two_wheeler,
                  size: size * 0.22,
                  color: Colors.white,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Avatars superposés (membres d'un groupe).
class AvatarStack extends StatelessWidget {
  const AvatarStack({super.key, required this.people, this.size = 30, this.max = 5});

  final List<(String name, Color color)> people;
  final double size;
  final int max;

  @override
  Widget build(BuildContext context) {
    final shown = people.take(max).toList();
    final extra = people.length - shown.length;
    final bg = Theme.of(context).colorScheme.surfaceContainer;
    final step = size * 0.68;
    final count = shown.length + (extra > 0 ? 1 : 0);
    return SizedBox(
      height: size,
      width: count == 0 ? 0 : step * (count - 1) + size,
      child: Stack(
        children: [
          for (var i = 0; i < shown.length; i++)
            Positioned(
              left: i * step,
              child: Container(
                decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: bg, width: 2)),
                child: RiderAvatar(name: shown[i].$1, color: shown[i].$2, size: size - 4),
              ),
            ),
          if (extra > 0)
            Positioned(
              left: shown.length * step,
              child: Container(
                width: size,
                height: size,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: Theme.of(context).colorScheme.surfaceContainerHighest,
                  border: Border.all(color: bg, width: 2),
                ),
                alignment: Alignment.center,
                child: Text('+$extra', style: Theme.of(context).textTheme.labelMedium?.copyWith(fontWeight: FontWeight.w800)),
              ),
            ),
        ],
      ),
    );
  }
}

/// Statut d'un pote : libellé, couleur, icône.
class FriendStatus {
  const FriendStatus(this.label, this.color, this.icon, {this.distance});

  final String label;
  final Color color;
  final IconData icon;

  /// « à 12 km » si connu.
  final String? distance;

  static FriendStatus of(Friend f, {GeoPoint? me, DateTime? now}) {
    final live = f.recentLive(now: now);
    final dist = (me != null && live != null) ? 'à ${Fmt.distance(Geo.distance(me, live.location))}' : null;
    if (live == null) {
      final old = f.live;
      if (old != null) {
        return FriendStatus('Vu ${Fmt.ago(old.updatedAt, now: now)}', Colors.grey, Icons.schedule_rounded);
      }
      return const FriendStatus('Pas encore roulé avec l\'app', Colors.grey, Icons.hourglass_empty_rounded);
    }
    if (live.sos) return FriendStatus('SOS en cours !', CmColors.red, Icons.sos_rounded, distance: dist);
    if (f.isRiding(now: now)) {
      return FriendStatus(
        live.speedKmh >= 3 ? 'En balade · ${Fmt.speed(live.speedKmh)}' : 'En balade · à l\'arrêt',
        CmColors.green,
        Icons.two_wheeler,
        distance: dist,
      );
    }
    return FriendStatus('Vu ${Fmt.ago(live.updatedAt, now: now)}', CmColors.sky, Icons.place_rounded, distance: dist);
  }
}

/// Badge arrondi coloré, comme [Pill] du socle mais dont le texte se coupe
/// proprement (« … ») s'il est trop long pour la place disponible.
class SocialPill extends StatelessWidget {
  const SocialPill({super.key, required this.label, this.icon, this.color});

  final String label;
  final IconData? icon;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final c = color ?? CmColors.orange;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: c.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 14, color: c),
            const SizedBox(width: 4),
          ],
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.labelMedium?.copyWith(color: c, fontWeight: FontWeight.w700),
            ),
          ),
        ],
      ),
    );
  }
}

/// Carte « bloc » du module (fond légèrement surélevé, coins arrondis).
class SocialCard extends StatelessWidget {
  const SocialCard({super.key, required this.child, this.padding = const EdgeInsets.all(CmSpacing.lg), this.onTap, this.color, this.gradient, this.border});

  final Widget child;
  final EdgeInsetsGeometry padding;
  final VoidCallback? onTap;
  final Color? color;
  final Gradient? gradient;
  final BoxBorder? border;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      decoration: BoxDecoration(
        color: gradient == null ? (color ?? scheme.surfaceContainer) : null,
        gradient: gradient,
        borderRadius: BorderRadius.circular(CmSpacing.radius),
        border: border,
      ),
      clipBehavior: Clip.antiAlias,
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          onTap: onTap,
          child: Padding(padding: padding, child: child),
        ),
      ),
    );
  }
}

/// Ligne « icône colorée + titre + sous-titre » (listes de fonctionnalités).
class FeatureLine extends StatelessWidget {
  const FeatureLine({super.key, required this.icon, required this.color, required this.title, required this.subtitle});

  final IconData icon;
  final Color color;
  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 7),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(icon, color: color, size: 22),
          ),
          const SizedBox(width: CmSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: t.titleSmall?.copyWith(fontWeight: FontWeight.w800)),
                const SizedBox(height: 2),
                Text(subtitle, style: t.bodySmall?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Code affiché en grosses cases (« K 7 P M 2 X »), toujours sur une ligne :
/// les cases rétrécissent si la place manque.
class CodeTiles extends StatelessWidget {
  const CodeTiles({super.key, required this.code, this.color = CmColors.orange, this.tileSize = 38});

  final String code;
  final Color color;

  /// Taille maximale d'une case.
  final double tileSize;

  static const _gap = 6.0;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final chars = code.split('');
    final dashes = chars.where((c) => c == '-').length;
    return LayoutBuilder(builder: (context, c) {
      var size = tileSize;
      if (c.hasBoundedWidth && chars.isNotEmpty) {
        final fit = (c.maxWidth - _gap * (chars.length - 1)) / ((chars.length - dashes) + dashes * 0.4);
        if (fit < size) size = fit.clamp(12.0, tileSize);
      }
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 0; i < chars.length; i++) ...[
            if (i > 0) const SizedBox(width: _gap),
            Container(
              width: chars[i] == '-' ? size * 0.4 : size,
              height: size * 1.2,
              alignment: Alignment.center,
              decoration: chars[i] == '-'
                  ? null
                  : BoxDecoration(
                      color: scheme.surfaceContainerHighest.withValues(alpha: 0.7),
                      borderRadius: BorderRadius.circular(size * 0.26),
                      border: Border.all(color: color.withValues(alpha: 0.35)),
                    ),
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(
                  chars[i],
                  style: CmTheme.numbers(size: size * 0.75, color: chars[i] == '-' ? scheme.outline : color),
                ),
              ),
            ),
          ],
        ],
      );
    });
  }
}

/// Copie dans le presse-papiers avec confirmation.
Future<void> copyToClipboard(BuildContext context, String text, {String message = 'Copié !'}) async {
  await Clipboard.setData(ClipboardData(text: text));
  if (context.mounted) showCmSnack(context, message);
}

/// Centre la carte principale sur un point et bascule sur l'onglet Carte.
void showOnMap(BuildContext context, WidgetRef ref, GeoPoint point) {
  ref.read(mapFocusProvider.notifier).focus(point);
  ref.read(homeTabProvider.notifier).select(HomeTabs.map);
  final nav = Navigator.of(context);
  if (nav.canPop()) nav.popUntil((r) => r.isFirst);
}

/// Bouton plein avec indicateur de chargement.
class BusyButton extends StatelessWidget {
  const BusyButton({super.key, required this.label, required this.onPressed, this.busy = false, this.icon, this.color});

  final String label;
  final VoidCallback? onPressed;
  final bool busy;
  final IconData? icon;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final style = color == null ? null : FilledButton.styleFrom(backgroundColor: color);
    final child = busy
        ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.6, color: Colors.white))
        : Text(label);
    if (icon != null && !busy) {
      return FilledButton.icon(onPressed: onPressed, style: style, icon: Icon(icon), label: child);
    }
    return FilledButton(onPressed: busy ? null : onPressed, style: style, child: child);
  }
}

/// Titre de feuille modale (icône + titre + sous-titre).
class SheetTitle extends StatelessWidget {
  const SheetTitle({super.key, required this.icon, required this.title, this.subtitle, this.color = CmColors.orange});

  final IconData icon;
  final String title;
  final String? subtitle;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Row(
      children: [
        Container(
          width: 46,
          height: 46,
          decoration: BoxDecoration(color: color.withValues(alpha: 0.16), borderRadius: BorderRadius.circular(14)),
          child: Icon(icon, color: color),
        ),
        const SizedBox(width: CmSpacing.md),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: t.titleLarge?.copyWith(fontWeight: FontWeight.w800)),
              if (subtitle != null)
                Text(subtitle!, style: t.bodyMedium?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant)),
            ],
          ),
        ),
      ],
    );
  }
}

/// Demande de confirmation (action destructive).
Future<bool> confirmAction(
  BuildContext context, {
  required String title,
  required String message,
  required String confirm,
  bool destructive = true,
}) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: Text(message),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Annuler')),
        FilledButton(
          style: destructive ? FilledButton.styleFrom(backgroundColor: CmColors.red) : null,
          onPressed: () => Navigator.pop(ctx, true),
          child: Text(confirm),
        ),
      ],
    ),
  );
  return ok ?? false;
}
