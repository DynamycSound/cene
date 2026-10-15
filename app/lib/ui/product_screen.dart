import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';

import '../app_state.dart';
import '../data/location.dart';
import '../data/models.dart';
import 'map_screen.dart';
import 'widgets.dart';

/// Poređenje: gde je proizvod najjeftiniji u izabranim radnjama.
class ProductScreen extends StatefulWidget {
  final int productId;
  const ProductScreen({super.key, required this.productId});
  @override
  State<ProductScreen> createState() => _ProductScreenState();
}

class _ProductScreenState extends State<ProductScreen> {
  ProductHit? _p;
  List<Offer> _offers = [];
  Map<int, double> _nearestKm = {}; // chain_id -> km do najbliže radnje
  bool _showOthers = false;
  LocationResult? _loc;
  // posle povratka iz podešavanja lokacije pokušaj ponovo
  late final AppLifecycleListener _lifecycle;

  @override
  void initState() {
    super.initState();
    _lifecycle = AppLifecycleListener(onResume: () {
      if (_loc?.pos == null) _locate();
    });
    _load();
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final db = app.store.db!;
    final sel = app.settings.selectedFormatIds(db);
    final p = await db.product(widget.productId, sel);
    final offers = await db.offers(widget.productId);
    setState(() {
      _p = p;
      _offers = offers;
    });
    await _locate();
  }

  Future<void> _locate() async {
    final loc = await Locator.current();
    if (!mounted) return;
    setState(() => _loc = loc);
    if (loc.pos == null) return;
    final stores = await app.store.db!.stores({for (final o in _offers) o.chain.id});
    if (mounted) setState(() => _nearestKm = nearestByChain(stores, loc.pos!));
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final p = _p;
    if (p == null) return Scaffold(appBar: AppBar(), body: const Center(child: CircularProgressIndicator()));
    final sel = app.settings.selectedFormatIds(app.store.db!);
    final mine = groupByChain(_offers.where((o) => sel.contains(o.formatId)));
    final others = groupByChain(_offers.where((o) => !sel.contains(o.formatId)));
    final best = mine.isEmpty ? null : mine.first;
    final saving = mine.length > 1 ? mine.last.best.effective - best!.best.effective : 0.0;
    return Scaffold(
      appBar: AppBar(actions: [
        IconButton(
          tooltip: 'Na mapi',
          icon: const Icon(Icons.map_outlined),
          onPressed: () => Navigator.push(
              context, MaterialPageRoute(builder: (_) => MapScreen(productId: p.id, title: p.name))),
        ),
      ]),
      floatingActionButton: ListenableBuilder(
        listenable: app.list,
        builder: (context, _) => FloatingActionButton.extended(
          icon: Icon(app.list.contains(p.ean) ? Icons.playlist_add_check : Icons.playlist_add),
          label: Text(app.list.contains(p.ean) ? 'Dodaj još 1' : 'Na spisak'),
          onPressed: () async {
            await app.list.add(p.ean, p.name);
            if (context.mounted) {
              ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Dodato: ${p.name}')));
            }
          },
        ),
      ),
      body: ListView(padding: const EdgeInsets.only(bottom: 96), children: [
        // slika gore na sredini, ispod naziv, pa proizvođač
        Center(child: ProductImage(url: p.imageBig ?? p.image, ean: p.ean, size: 200)),
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 16, 24, 0),
          child: Text(p.name, textAlign: TextAlign.center, style: t.textTheme.titleLarge),
        ),
        if (p.brand.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(p.brand,
                textAlign: TextAlign.center,
                style: t.textTheme.titleSmall?.copyWith(color: t.colorScheme.onSurfaceVariant)),
          ),
        Padding(
          padding: const EdgeInsets.only(top: 4, bottom: 12),
          child: Text('barkod ${p.ean}', textAlign: TextAlign.center, style: t.textTheme.bodySmall),
        ),
        if (best != null)
          Card(
            margin: const EdgeInsets.symmetric(horizontal: 16),
            color: t.colorScheme.primaryContainer,
            child: ListTile(
              contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              leading: ChainLogo(best.chain, size: 44),
              title: Text('Najjeftinije: ${best.chain.name}'),
              subtitle: saving >= 0.01
                  ? Text('${fmtPrice(saving)} jeftinije nego u ${mine.last.chain.name}')
                  : mine.length == 1
                      ? const Text('jedini od tvojih lanaca koji ga ima')
                      : const Text('ista cena u svim tvojim lancima'),
              trailing: PriceText(best.best),
            ),
          )
        else
          const Padding(
            padding: EdgeInsets.all(16),
            child: Text('Ovog proizvoda nema u radnjama koje si izabrao. Pogledaj ostale radnje ispod.'),
          ),
        if (_loc?.problem != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 8, 0),
            child: LocationNotice(_loc!.problem!, _loc!.fix),
          ),
        const SizedBox(height: 8),
        for (final c in mine) _ChainOfferTile(c, km: _nearestKm[c.chain.id]),
        if (others.isNotEmpty)
          ListTile(
            title: Text('Ostali lanci (${others.length})'),
            trailing: Icon(_showOthers ? Icons.expand_less : Icons.expand_more),
            onTap: () => setState(() => _showOthers = !_showOthers),
          ),
        if (_showOthers) for (final c in others) _ChainOfferTile(c, km: _nearestKm[c.chain.id], dim: true),
      ]),
    );
  }
}

/// najbliža radnja svakog lanca
Map<int, double> nearestByChain(List<Store> stores, LatLng pos) {
  final out = <int, double>{};
  for (final s in stores) {
    final d = Locator.km(pos, s.lat, s.lon);
    if (d < (out[s.chainId] ?? double.infinity)) out[s.chainId] = d;
  }
  return out;
}

class _ChainOfferTile extends StatelessWidget {
  final ChainOffer c;
  final double? km;
  final bool dim;
  const _ChainOfferTile(this.c, {this.km, this.dim = false});

  @override
  Widget build(BuildContext context) {
    final o = c.best;
    final parts = [
      ?c.formatNote,
      // lanci prijavljuju cenu po jedinici različito (po kg ili po komadu) – prikaz samo kad nosi informaciju
      if (o.unitPrice != null && o.unitPrice != o.price) '${fmtPrice(o.unitPrice)}/jed. mere',
      if (o.onSale && o.saleTo != null) 'akcija do ${fmtDateInt(o.saleTo)}',
      if (km != null) 'najbliža ${km!.toStringAsFixed(km! < 10 ? 1 : 0)} km',
    ];
    return Opacity(
      opacity: dim ? 0.7 : 1,
      child: ListTile(
        leading: ChainLogo(c.chain, size: 40),
        title: Text(c.chain.name),
        subtitle: parts.isEmpty ? null : Text(parts.join(' · ')),
        trailing: PriceText(o),
      ),
    );
  }
}
