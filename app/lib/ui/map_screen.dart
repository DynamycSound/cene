import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../app_state.dart';
import '../data/location.dart';
import '../data/models.dart';
import 'widgets.dart';

/// Mapa izabranih radnji (OpenStreetMap). Sa [productId] prikazuje cenu tog proizvoda po radnji.
class MapScreen extends StatefulWidget {
  final int? productId;
  final int? onlyChainId;
  final String? title;
  const MapScreen({super.key, this.productId, this.onlyChainId, this.title});
  @override
  State<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends State<MapScreen> {
  final _map = MapController();
  List<Store> _stores = [];
  Map<int, Offer> _priceByFormat = {};
  Map<int, Offer> _cheapestByChain = {};
  LatLng? _me;
  String? _problem;
  Future<bool> Function()? _fix;
  late final AppLifecycleListener _lifecycle;
  bool _ready = false;

  static const _serbia = LatLng(44.2, 20.9);

  @override
  void initState() {
    super.initState();
    app.settings.addListener(_load);
    // posle povratka iz podešavanja lokacije pokušaj ponovo
    _lifecycle = AppLifecycleListener(onResume: () {
      if (_me == null) _locate();
    });
    _load();
    _locate();
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    app.settings.removeListener(_load);
    super.dispose();
  }

  Future<void> _locate() async {
    final r = await Locator.current();
    if (!mounted) return;
    setState(() {
      _me = r.pos;
      _problem = r.problem;
      _fix = r.fix;
    });
    if (r.pos != null && _ready) _map.move(r.pos!, 13);
  }

  Future<void> _load() async {
    final db = app.store.db;
    if (db == null) return;
    final sel = app.settings.selectedFormatIds(db);
    var chainIds = app.settings.selectedChainIds(db);
    if (widget.onlyChainId != null) chainIds = {widget.onlyChainId!};
    var stores = await db.stores(chainIds);
    final byFormat = <int, Offer>{}, byChain = <int, Offer>{};
    if (widget.productId != null) {
      for (final o in await db.offers(widget.productId!)) {
        if (!sel.contains(o.formatId)) continue;
        byFormat[o.formatId] = o;
        final c = byChain[o.chain.id];
        if (c == null || o.effective < c.effective) byChain[o.chain.id] = o;
      }
      // samo radnje koje imaju taj proizvod
      stores = stores.where((s) => byChain[s.chainId] != null).toList();
    }
    if (mounted) {
      setState(() {
        _stores = stores;
        _priceByFormat = byFormat;
        _cheapestByChain = byChain;
      });
    }
  }

  /// cena u cenovniku te radnje ako se zna kojoj vrsti radnje pripada, inače najniža u lancu
  Offer? _offerFor(Store s) => _priceByFormat[s.formatId] ?? _cheapestByChain[s.chainId];

  void _showStore(Store s) {
    final db = app.store.db!;
    final c = db.chains[s.chainId]!;
    final o = _offerFor(s);
    final d = _me == null ? null : Locator.km(_me!, s.lat, s.lon);
    showModalBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              ChainLogo(c, size: 32),
              const SizedBox(width: 10),
              Expanded(child: Text(s.name.isEmpty ? c.name : s.name, style: Theme.of(ctx).textTheme.titleLarge)),
            ]),
            const SizedBox(height: 4),
            Text([s.address, s.city].where((x) => x.isNotEmpty).join(', ')),
            if (d != null) Text('${d.toStringAsFixed(1)} km od tebe'),
            if (s.formatId != null && db.formatName(s.formatId!) != null) Text('Vrsta radnje: ${db.formatName(s.formatId!)}'),
            if (o != null) ...[
              const SizedBox(height: 8),
              Row(children: [Expanded(child: Text(widget.title ?? '')), PriceText(o)]),
            ],
            const SizedBox(height: 12),
            FilledButton.icon(
              icon: const Icon(Icons.directions),
              label: const Text('Navigacija'),
              onPressed: () => openUrl(ctx,
                  'geo:${s.lat},${s.lon}?q=${s.lat},${s.lon}(${Uri.encodeComponent(s.name.isEmpty ? c.name : s.name)})'),
            ),
          ]),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final db = app.store.db!;
    final radius = app.settings.radiusKm;
    final visible = (_me != null && radius > 0)
        ? _stores.where((s) => Locator.km(_me!, s.lat, s.lon) <= radius).toList()
        : _stores;
    return Scaffold(
      appBar: AppBar(title: Text(widget.title ?? 'Mapa radnji')),
      floatingActionButton: FloatingActionButton.small(
        tooltip: 'Moja lokacija',
        onPressed: _locate,
        child: const Icon(Icons.my_location),
      ),
      body: Stack(children: [
        FlutterMap(
          mapController: _map,
          options: MapOptions(
            initialCenter: _me ?? Locator.last ?? _serbia,
            initialZoom: (_me ?? Locator.last) != null ? 13 : 7,
            onMapReady: () => _ready = true,
          ),
          children: [
            TileLayer(
              urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
              userAgentPackageName: 'rs.cene.cene',
            ),
            MarkerLayer(markers: [
              for (final s in visible)
                Marker(
                  point: LatLng(s.lat, s.lon),
                  width: widget.productId != null ? 84 : 28,
                  height: 28,
                  child: GestureDetector(
                    onTap: () => _showStore(s),
                    child: _pin(db.chains[s.chainId]!, _offerFor(s)),
                  ),
                ),
              if (_me != null)
                Marker(
                  point: _me!,
                  width: 22,
                  height: 22,
                  child: Container(
                    decoration: BoxDecoration(
                        color: Colors.blue, shape: BoxShape.circle, border: Border.all(color: Colors.white, width: 3)),
                  ),
                ),
            ]),
            const SimpleAttributionWidget(source: Text('OpenStreetMap')),
          ],
        ),
        if (_problem != null || visible.isEmpty)
          Positioned(
            left: 12,
            right: 12,
            top: 12,
            child: Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Row(children: [
                  Expanded(
                    child: Text([
                      ?_problem,
                      if (visible.isEmpty)
                        _stores.isEmpty
                            ? 'Nema radnji na mapi za izabrane lance (lokacije su iz OpenStreetMap-a).'
                            : 'Nema radnji u radijusu od ${radius.round()} km.',
                    ].join('\n')),
                  ),
                  if (_problem != null && _fix != null) TextButton(onPressed: _fix, child: const Text('Uključi')),
                ]),
              ),
            ),
          ),
      ]),
    );
  }

  Widget _pin(Chain c, Offer? o) {
    if (o == null) return ChainLogo(c, size: 28);
    return Container(
      alignment: Alignment.center,
      decoration: BoxDecoration(
          color: c.color, borderRadius: BorderRadius.circular(14), border: Border.all(color: Colors.white, width: 2)),
      child: Text(fmtPrice(o.effective).replaceAll(' din', ''),
          style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 12)),
    );
  }
}
