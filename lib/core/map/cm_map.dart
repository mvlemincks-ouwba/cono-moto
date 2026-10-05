import 'dart:async';
import 'dart:math' show Point;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:maplibre_gl/maplibre_gl.dart';

import '../geo.dart';
import '../location.dart';
import '../settings.dart';
import 'map_models.dart';
import 'marker_renderer.dart';

export 'map_models.dart';

/// Pilotage de la caméra d'une [CmMap].
class CmMapController {
  CmMapController._(this._state);

  final _CmMapState _state;

  MapLibreMapController? get _c => _state._controller;

  Future<void> moveTo(GeoPoint p, {double? zoom, bool animate = true}) async {
    final c = _c;
    if (c == null) return;
    final update = zoom == null
        ? CameraUpdate.newLatLng(LatLng(p.lat, p.lng))
        : CameraUpdate.newLatLngZoom(LatLng(p.lat, p.lng), zoom);
    animate ? await c.animateCamera(update) : await c.moveCamera(update);
  }

  /// Cadre la carte sur une zone.
  Future<void> fitBounds(GeoBounds b, {EdgeInsets padding = const EdgeInsets.all(48)}) async {
    final c = _c;
    if (c == null) return;
    // Évite un zoom infini sur un point unique.
    final safe = (b.north - b.south).abs() < 1e-4 && (b.east - b.west).abs() < 1e-4 ? b.expand(300) : b;
    await c.animateCamera(CameraUpdate.newLatLngBounds(
      LatLngBounds(
        southwest: LatLng(safe.south, safe.west),
        northeast: LatLng(safe.north, safe.east),
      ),
      left: padding.left,
      top: padding.top,
      right: padding.right,
      bottom: padding.bottom,
    ));
  }

  Future<void> fitPoints(List<GeoPoint> points, {EdgeInsets padding = const EdgeInsets.all(48)}) async {
    final b = GeoBounds.fromPoints(points);
    if (b != null) await fitBounds(b, padding: padding);
  }

  Future<void> setFollowMode(FollowMode mode) => _state._setFollowMode(mode);

  Future<GeoBounds?> visibleBounds() async {
    final c = _c;
    if (c == null) return null;
    final r = await c.getVisibleRegion();
    return GeoBounds(
      south: r.southwest.latitude,
      west: r.southwest.longitude,
      north: r.northeast.latitude,
      east: r.northeast.longitude,
    );
  }

  Future<double?> zoom() async => (await _c?.queryCameraPosition())?.zoom;

  /// Accès bas niveau (téléchargement hors-ligne, couches spécifiques).
  MapLibreMapController? get raw => _c;
}

/// Carte Cono Moto : MapLibre + styles OpenFreeMap, API déclarative
/// (lignes et marqueurs passés en paramètres, synchronisés automatiquement).
class CmMap extends ConsumerStatefulWidget {
  const CmMap({
    super.key,
    this.lines = const [],
    this.markers = const [],
    this.initialCenter,
    this.initialZoom = 12,
    this.showUserLocation = true,
    this.followMode = FollowMode.none,
    this.onFollowModeChanged,
    this.onMarkerTap,
    this.onMapTap,
    this.onMapLongPress,
    this.onCameraIdle,
    this.onCreated,
    this.interactive = true,
    this.tilt = 0,
    this.compassEnabled = true,
    this.attributionMargin,
  });

  final List<MapLine> lines;
  final List<MapMarker> markers;
  final GeoPoint? initialCenter;
  final double initialZoom;
  final bool showUserLocation;
  final FollowMode followMode;
  final ValueChanged<FollowMode>? onFollowModeChanged;
  final ValueChanged<MapMarker>? onMarkerTap;
  final ValueChanged<GeoPoint>? onMapTap;
  final ValueChanged<GeoPoint>? onMapLongPress;

  /// Appelé quand la caméra s'arrête, avec la zone visible.
  final ValueChanged<GeoBounds>? onCameraIdle;
  final ValueChanged<CmMapController>? onCreated;
  final bool interactive;

  /// Inclinaison 3D de la caméra en suivi (degrés).
  final double tilt;
  final bool compassEnabled;
  final Point<double>? attributionMargin;

  /// Centre par défaut : France.
  static const defaultCenter = GeoPoint(46.6, 2.4);

  @override
  ConsumerState<CmMap> createState() => _CmMapState();
}

class _CmMapState extends ConsumerState<CmMap> {
  static const _lineSource = 'cm-lines-src';
  static const _markerSource = 'cm-markers-src';
  static const _lineCasingLayer = 'cm-lines-casing';
  static const _lineLayer = 'cm-lines';
  static const _lineDashedLayer = 'cm-lines-dashed';
  static const _markerLayer = 'cm-markers';

  MapLibreMapController? _controller;
  late final CmMapController _facade = CmMapController._(this);
  MarkerRenderer? _renderer;
  bool _styleReady = false;
  bool _locationGranted = false;
  final Set<String> _addedImages = {};
  Future<void> _queue = Future.value();
  bool _syncScheduled = false;

  @override
  void initState() {
    super.initState();
    if (widget.showUserLocation) _checkLocation();
  }

  Future<void> _checkLocation() async {
    final access = await ref.read(locationServiceProvider).ensurePermission();
    if (!mounted) return;
    setState(() => _locationGranted = access == LocationAccess.granted);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _renderer ??= MarkerRenderer(MediaQuery.devicePixelRatioOf(context));
  }

  @override
  void didUpdateWidget(covariant CmMap oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.lines, widget.lines) || !identical(oldWidget.markers, widget.markers)) {
      _scheduleSync();
    }
    if (oldWidget.followMode != widget.followMode) {
      _applyTracking(widget.followMode);
    }
  }

  void _enqueue(Future<void> Function() task) {
    _queue = _queue.then((_) => task()).catchError((Object e, StackTrace st) {
      debugPrint('CmMap : $e');
    });
  }

  void _scheduleSync() {
    if (!_styleReady || _syncScheduled) return;
    _syncScheduled = true;
    _enqueue(() async {
      _syncScheduled = false;
      await _sync();
    });
  }

  Future<void> _onStyleLoaded() async {
    final c = _controller;
    if (c == null) return;
    _addedImages.clear();
    _styleReady = false;
    _enqueue(() async {
      await c.addGeoJsonSource(_lineSource, _emptyCollection);
      await c.addGeoJsonSource(_markerSource, _emptyCollection);
      await c.addLineLayer(
        _lineSource,
        _lineCasingLayer,
        const LineLayerProperties(
          lineColor: '#101318',
          lineWidth: ['+', ['get', 'width'], 4],
          lineOpacity: ['*', ['get', 'opacity'], 0.55],
          lineCap: 'round',
          lineJoin: 'round',
        ),
        filter: ['==', ['get', 'casing'], true],
        enableInteraction: false,
      );
      await c.addLineLayer(
        _lineSource,
        _lineLayer,
        const LineLayerProperties(
          lineColor: ['get', 'color'],
          lineWidth: ['get', 'width'],
          lineOpacity: ['get', 'opacity'],
          lineCap: 'round',
          lineJoin: 'round',
        ),
        filter: ['==', ['get', 'dashed'], false],
        enableInteraction: false,
      );
      await c.addLineLayer(
        _lineSource,
        _lineDashedLayer,
        const LineLayerProperties(
          lineColor: ['get', 'color'],
          lineWidth: ['get', 'width'],
          lineOpacity: ['get', 'opacity'],
          lineDasharray: [1.5, 1.5],
          lineCap: 'butt',
          lineJoin: 'round',
        ),
        filter: ['==', ['get', 'dashed'], true],
        enableInteraction: false,
      );
      await c.addSymbolLayer(
        _markerSource,
        _markerLayer,
        const SymbolLayerProperties(
          iconImage: ['get', 'icon'],
          iconAllowOverlap: true,
          iconIgnorePlacement: true,
          iconAnchor: 'center',
          symbolSortKey: ['get', 'z'],
          textField: ['get', 'label'],
          textFont: ['Noto Sans Bold'],
          textSize: 12,
          textOffset: [0, 1.9],
          textAnchor: 'top',
          textOptional: true,
          textColor: '#FFFFFF',
          textHaloColor: '#101318',
          textHaloWidth: 1.6,
        ),
      );
      _styleReady = true;
      await _sync();
      await _applyTracking(widget.followMode);
    });
  }

  static const Map<String, dynamic> _emptyCollection = {
    'type': 'FeatureCollection',
    'features': <dynamic>[],
  };

  static String _hex(Color c) =>
      '#${(c.toARGB32() & 0xFFFFFF).toRadixString(16).padLeft(6, '0').toUpperCase()}';

  Future<void> _sync() async {
    final c = _controller;
    if (c == null || !_styleReady || !mounted) return;
    final renderer = _renderer!;

    // Images des marqueurs manquantes.
    for (final m in widget.markers) {
      if (_addedImages.contains(m.imageKey)) continue;
      final bytes = await renderer.render(m);
      await c.addImage(m.imageKey, bytes);
      _addedImages.add(m.imageKey);
    }

    final lineFeatures = <Map<String, dynamic>>[
      for (final l in widget.lines)
        if (l.points.length >= 2)
          {
            'type': 'Feature',
            'id': l.id,
            'properties': {
              'id': l.id,
              'color': _hex(l.color),
              'width': l.width,
              'opacity': l.opacity,
              'dashed': l.dashed,
              'casing': l.casing,
            },
            'geometry': {
              'type': 'LineString',
              'coordinates': [
                for (final p in l.points) [p.lng, p.lat]
              ],
            },
          }
    ];
    final markerFeatures = <Map<String, dynamic>>[
      for (final m in widget.markers)
        {
          'type': 'Feature',
          'id': m.id,
          'properties': {
            'id': m.id,
            'icon': m.imageKey,
            'label': m.label ?? '',
            'z': m.zIndex,
          },
          'geometry': {
            'type': 'Point',
            'coordinates': [m.position.lng, m.position.lat],
          },
        }
    ];
    await c.setGeoJsonSource(_lineSource, {'type': 'FeatureCollection', 'features': lineFeatures});
    await c.setGeoJsonSource(_markerSource, {'type': 'FeatureCollection', 'features': markerFeatures});
  }

  Future<void> _applyTracking(FollowMode mode) async {
    final c = _controller;
    if (c == null || !_locationGranted || !widget.showUserLocation) return;
    final tracking = switch (mode) {
      FollowMode.none => MyLocationTrackingMode.none,
      FollowMode.follow => MyLocationTrackingMode.tracking,
      FollowMode.heading => MyLocationTrackingMode.trackingGps,
    };
    try {
      await c.updateMyLocationTrackingMode(tracking);
      if (mode == FollowMode.heading && widget.tilt > 0) {
        await c.animateCamera(CameraUpdate.tiltTo(widget.tilt));
      }
    } catch (e) {
      debugPrint('Suivi position : $e');
    }
  }

  Future<void> _setFollowMode(FollowMode mode) async {
    await _applyTracking(mode);
    widget.onFollowModeChanged?.call(mode);
  }

  void _onFeatureTapped(Point<double> point, LatLng coords, String id, String layerId, Annotation? a) {
    if (layerId != _markerLayer) return;
    final marker = widget.markers.where((m) => m.id == id).firstOrNull;
    if (marker != null) widget.onMarkerTap?.call(marker);
  }

  Future<void> _onCameraIdle() async {
    final cb = widget.onCameraIdle;
    if (cb == null) return;
    final b = await _facade.visibleBounds();
    if (b != null && mounted) cb(b);
  }

  @override
  void dispose() {
    _controller?.onFeatureTapped.remove(_onFeatureTapped);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final mapStyle = ref.watch(settingsProvider.select((s) => s.mapStyle));
    final styleUrl = mapStyle.resolve(Theme.of(context).brightness);
    final center = widget.initialCenter ?? ref.read(positionHubProvider)?.point ?? CmMap.defaultCenter;
    final zoom = widget.initialCenter == null && ref.read(positionHubProvider) == null ? 5.2 : widget.initialZoom;
    final showLoc = widget.showUserLocation && _locationGranted;

    return MapLibreMap(
      styleString: styleUrl,
      initialCameraPosition: CameraPosition(target: LatLng(center.lat, center.lng), zoom: zoom),
      onMapCreated: (c) {
        _controller = c;
        c.onFeatureTapped.add(_onFeatureTapped);
        widget.onCreated?.call(_facade);
      },
      onStyleLoadedCallback: _onStyleLoaded,
      myLocationEnabled: showLoc,
      myLocationRenderMode: showLoc ? MyLocationRenderMode.gps : MyLocationRenderMode.normal,
      myLocationTrackingMode: MyLocationTrackingMode.none,
      onCameraTrackingDismissed: () => widget.onFollowModeChanged?.call(FollowMode.none),
      onMapClick: (p, latLng) => widget.onMapTap?.call(GeoPoint(latLng.latitude, latLng.longitude)),
      onMapLongClick: (p, latLng) => widget.onMapLongPress?.call(GeoPoint(latLng.latitude, latLng.longitude)),
      onCameraIdle: _onCameraIdle,
      compassEnabled: widget.compassEnabled,
      compassViewPosition: CompassViewPosition.topRight,
      compassViewMargins: const Point(16, 120),
      rotateGesturesEnabled: widget.interactive,
      scrollGesturesEnabled: widget.interactive,
      zoomGesturesEnabled: widget.interactive,
      tiltGesturesEnabled: widget.interactive,
      doubleClickZoomEnabled: widget.interactive,
      attributionButtonPosition: AttributionButtonPosition.bottomLeft,
      attributionButtonMargins: widget.attributionMargin ?? const Point(8, 8),
      trackCameraPosition: false,
    );
  }
}
