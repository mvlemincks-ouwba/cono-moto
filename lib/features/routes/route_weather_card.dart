import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../core/theme.dart';
import '../../data/models/planned_route.dart';
import '../../services/routing/weather_service.dart';
import 'route_ui.dart';
import 'routes_providers.dart';

/// Choix d'une heure de départ (date + heure).
Future<DateTime?> pickDeparture(BuildContext context, DateTime initial) async {
  final now = DateTime.now();
  final date = await showDatePicker(
    context: context,
    initialDate: initial.isBefore(now) ? now : initial,
    firstDate: DateTime(now.year, now.month, now.day),
    lastDate: now.add(const Duration(days: 14)),
    helpText: 'Jour du départ',
  );
  if (date == null || !context.mounted) return null;
  final time = await showTimePicker(
    context: context,
    initialTime: TimeOfDay.fromDateTime(initial),
    helpText: 'Heure du départ',
  );
  if (time == null) return null;
  return DateTime(date.year, date.month, date.day, time.hour, time.minute);
}

/// Libellé court d'un départ : « aujourd'hui 14:00 », « demain 9:30 », « sam. 12 oct. 8:00 ».
String departureLabel(DateTime d, {DateTime? now}) {
  final n = now ?? DateTime.now();
  final today = DateTime(n.year, n.month, n.day);
  final day = DateTime(d.year, d.month, d.day);
  final diff = day.difference(today).inDays;
  final time = Fmt.time(d);
  if (diff == 0) return "aujourd'hui $time";
  if (diff == 1) return 'demain $time';
  return '${Fmt.date(d)} $time';
}

/// Carte météo réutilisable : résumé + prévision aux ~6 points du parcours,
/// à l'heure de passage estimée.
class RouteWeatherCard extends ConsumerStatefulWidget {
  const RouteWeatherCard({
    super.key,
    required this.route,
    this.departure,
    this.onDepartureChanged,
    this.editable = true,
  });

  final PlannedRoute route;

  /// Heure de départ (par défaut : prochaine heure pleine).
  final DateTime? departure;
  final ValueChanged<DateTime>? onDepartureChanged;

  /// Permet de changer l'heure de départ depuis la carte.
  final bool editable;

  @override
  ConsumerState<RouteWeatherCard> createState() => _RouteWeatherCardState();
}

class _RouteWeatherCardState extends ConsumerState<RouteWeatherCard> {
  late DateTime _departure = widget.departure ?? nextFullHour();

  @override
  void didUpdateWidget(covariant RouteWeatherCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.departure != null && widget.departure != oldWidget.departure) {
      _departure = widget.departure!;
    }
  }

  Future<void> _change() async {
    final picked = await pickDeparture(context, _departure);
    if (picked == null || !mounted) return;
    setState(() => _departure = picked);
    widget.onDepartureChanged?.call(picked);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final query = WeatherQuery(widget.route, _departure);
    final async = ref.watch(routeWeatherProvider(query));

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(CmSpacing.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.wb_cloudy, color: scheme.onSurfaceVariant, size: 18),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    'MÉTÉO SUR LE PARCOURS',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.labelSmall
                        ?.copyWith(color: scheme.onSurfaceVariant, letterSpacing: 0.8, fontWeight: FontWeight.w800),
                  ),
                ),
              ],
            ),
            const SizedBox(height: CmSpacing.sm),
            ActionChip(
              avatar: const Icon(Icons.schedule, size: 16),
              label: Text('Départ ${departureLabel(_departure)}', overflow: TextOverflow.ellipsis),
              onPressed: widget.editable ? _change : null,
              visualDensity: VisualDensity.compact,
            ),
            const SizedBox(height: CmSpacing.md),
            AnimatedSize(
              duration: const Duration(milliseconds: 250),
              alignment: Alignment.topCenter,
              child: async.when(
                skipLoadingOnReload: false,
                loading: () => const _WeatherLoading(),
                error: (e, _) =>
                    _WeatherError(message: '$e', onRetry: () => ref.invalidate(routeWeatherProvider(query))),
                data: (w) => _WeatherBody(weather: w),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _WeatherBody extends StatelessWidget {
  const _WeatherBody({required this.weather});

  final RouteWeather weather;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final (verdictIcon, verdictColor) = switch (weather.verdict) {
      WeatherVerdict.top => (Icons.wb_sunny, CmColors.amber),
      WeatherVerdict.correct => (Icons.thumb_up_alt_outlined, CmColors.teal),
      WeatherVerdict.bof => (Icons.umbrella, CmColors.sky),
      WeatherVerdict.pourri => (Icons.thunderstorm, CmColors.red),
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: verdictColor.withValues(alpha: 0.16),
                borderRadius: BorderRadius.circular(14),
              ),
              child: Icon(verdictIcon, color: verdictColor),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    weather.headline,
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
                  ),
                  for (final d in weather.details)
                    Text(
                      d,
                      style: TextStyle(color: scheme.onSurfaceVariant, fontWeight: FontWeight.w600),
                    ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: CmSpacing.md),
        SizedBox(
          height: 136,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            itemCount: weather.samples.length,
            separatorBuilder: (_, _) => const SizedBox(width: 8),
            itemBuilder: (context, i) => _SampleTile(sample: weather.samples[i], first: i == 0),
          ),
        ),
        const SizedBox(height: CmSpacing.md),
        Wrap(
          spacing: 16,
          runSpacing: 6,
          children: [
            if (weather.minTempC != null)
              _MiniStat(
                icon: Icons.thermostat,
                label: '${weather.minTempC!.round()}° / ${weather.maxTempC!.round()} °C',
              ),
            if (weather.maxGustKmh != null)
              _MiniStat(icon: Icons.air, label: 'Rafales ${weather.maxGustKmh!.round()} km/h'),
          ],
        ),
      ],
    );
  }
}

class _SampleTile extends StatelessWidget {
  const _SampleTile({required this.sample, required this.first});

  final RouteWeatherSample sample;
  final bool first;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final wet = sample.rainLikely;
    return Container(
      width: 78,
      padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 6),
      decoration: BoxDecoration(
        color: wet ? CmColors.sky.withValues(alpha: 0.14) : scheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(16),
        border: wet ? Border.all(color: CmColors.sky.withValues(alpha: 0.5)) : null,
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          _Fit(
            Text(
              RouteWeatherService.hourLabel(sample.eta),
              style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 13),
            ),
          ),
          Icon(weatherIcon(sample.weatherCode), color: weatherColor(sample.weatherCode), size: 26),
          _Fit(
            Text(
              sample.temperatureC == null ? '—' : '${sample.temperatureC!.round()}°',
              style: CmTheme.numbers(size: 22, color: scheme.onSurface),
            ),
          ),
          _Fit(
            Text(
              first ? 'départ' : 'km ${sample.km.round()}',
              style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 11, fontWeight: FontWeight.w700),
            ),
          ),
          _Fit(
            Text(
              (sample.precipitationProbability ?? 0) >= 20 ? '${sample.precipitationProbability!.round()} %' : ' ',
              style: const TextStyle(color: CmColors.sky, fontSize: 11, fontWeight: FontWeight.w800),
            ),
          ),
        ],
      ),
    );
  }
}

/// Réduit un texte trop large plutôt que de déborder.
class _Fit extends StatelessWidget {
  const _Fit(this.child);

  final Widget child;

  @override
  Widget build(BuildContext context) => FittedBox(fit: BoxFit.scaleDown, child: child);
}

class _MiniStat extends StatelessWidget {
  const _MiniStat({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 16, color: scheme.onSurfaceVariant),
        const SizedBox(width: 4),
        Flexible(
          child: Text(
            label,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: scheme.onSurfaceVariant, fontWeight: FontWeight.w700),
          ),
        ),
      ],
    );
  }
}

class _WeatherLoading extends StatelessWidget {
  const _WeatherLoading();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2.4)),
            const SizedBox(width: 12),
            Text(
              'On consulte le ciel…',
              style: TextStyle(color: scheme.onSurfaceVariant, fontWeight: FontWeight.w600),
            ),
          ],
        ),
        const SizedBox(height: CmSpacing.md),
        SizedBox(
          height: 136,
          child: ListView(
            scrollDirection: Axis.horizontal,
            physics: const NeverScrollableScrollPhysics(),
            children: [
              for (var i = 0; i < 6; i++)
                Container(
                  width: 78,
                  margin: const EdgeInsets.only(right: 8),
                  decoration: BoxDecoration(
                    color: scheme.surfaceContainerHigh,
                    borderRadius: BorderRadius.circular(16),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

class _WeatherError extends StatelessWidget {
  const _WeatherError({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Row(
      children: [
        Icon(Icons.cloud_off, color: scheme.onSurfaceVariant),
        const SizedBox(width: 10),
        Expanded(
          child: Text(message, style: TextStyle(color: scheme.onSurfaceVariant)),
        ),
        TextButton(onPressed: onRetry, child: const Text('Réessayer')),
      ],
    );
  }
}
