import 'package:flutter/material.dart';

import '../app_state.dart';
import '../data/models.dart';
import '../data/settings.dart';
import '../util/fold.dart';
import 'widgets.dart';

/// „Moje radnje“: lanci i formati u kojima korisnik kupuje.
class StoresScreen extends StatefulWidget {
  const StoresScreen({super.key});
  @override
  State<StoresScreen> createState() => _StoresScreenState();
}

class _StoresScreenState extends State<StoresScreen> {
  String _filter = '';
  Map<int, int> _storeCounts = {};
  Map<int, int> _priceCounts = {};

  @override
  void initState() {
    super.initState();
    _loadCounts();
    app.store.addListener(_loadCounts);
  }

  @override
  void dispose() {
    app.store.removeListener(_loadCounts);
    super.dispose();
  }

  Future<void> _loadCounts() async {
    final db = app.store.db;
    if (db == null) return;
    final sc = await db.storeCounts();
    final rows = await db.db.rawQuery(
        'SELECT f.chain_id, count(*) n FROM prices p JOIN formats f ON f.id = p.format_id GROUP BY f.chain_id');
    if (mounted) {
      setState(() {
        _storeCounts = sc;
        _priceCounts = {for (final r in rows) r['chain_id'] as int: r['n'] as int};
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final db = app.store.db!;
    final t = Theme.of(context);
    final f = fold(_filter);
    final chains = db.chains.values.where((c) => f.isEmpty || fold(c.name).contains(f)).toList();
    // prvo lanci sa najviše radnji (Maxi, Idea…), pa po broju cena; tehnika na kraju
    int byStores(Chain a, Chain b) {
      final s = (_storeCounts[b.id] ?? 0).compareTo(_storeCounts[a.id] ?? 0);
      return s != 0 ? s : (_priceCounts[b.id] ?? 0).compareTo(_priceCounts[a.id] ?? 0);
    }
    final gov = chains.where((c) => c.isGov && (_priceCounts[c.id] ?? 0) > 0).toList()..sort(byStores);
    final web = chains.where((c) => !c.isGov).toList();
    return Scaffold(
      appBar: AppBar(title: const Text('Moje radnje')),
      body: ListenableBuilder(
        listenable: app.settings,
        builder: (context, _) => ListView(children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
            child: TextField(
              decoration: const InputDecoration(
                  prefixIcon: Icon(Icons.filter_list), hintText: 'Filtriraj lance', border: OutlineInputBorder()),
              onChanged: (v) => setState(() => _filter = v),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(children: [
              const Icon(Icons.radar, size: 20),
              const SizedBox(width: 8),
              Text(app.settings.radiusKm == 0 ? 'Mapa: sve radnje' : 'Mapa: do ${app.settings.radiusKm.round()} km'),
              Expanded(
                child: Slider(
                  value: app.settings.radiusKm,
                  min: 0,
                  max: 50,
                  divisions: 10,
                  label: app.settings.radiusKm == 0 ? 'sve' : '${app.settings.radiusKm.round()} km',
                  onChanged: app.settings.setRadius,
                ),
              ),
            ]),
          ),
          if (gov.isNotEmpty) _header(context, 'Hrana, piće i drogerija', 'zvanični cenovnici sa data.gov.rs'),
          for (final c in gov) _chainTile(context, c),
          if (web.isNotEmpty) _header(context, 'Tehnika', 'cene uživo sa sajta prodavnice'),
          for (final c in web) _chainTile(context, c),
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text(
              'Lanac se bira u celini (npr. Maxi = Maxi, Mega Maxi, Shop&Go…). Kad cena zavisi od vrste radnje, '
              'to piše kod proizvoda. '
              'Lokacije radnji su iz OpenStreetMap-a.',
              style: t.textTheme.bodySmall,
            ),
          ),
        ]),
      ),
    );
  }

  Widget _header(BuildContext context, String title, String sub) => ListTile(
        title: Text(title, style: Theme.of(context).textTheme.titleSmall),
        subtitle: Text(sub),
      );

  Widget _chainTile(BuildContext context, Chain c) {
    final on = app.settings.isSelected(c.slug);
    final stores = _storeCounts[c.id] ?? 0;
    final sub = [
      if (c.isGov) '${_priceCounts[c.id] ?? 0} cena',
      if (c.kind == 'link') 'samo link ka sajtu',
      if (stores > 0) '$stores na mapi',
    ].join(' · ');
    void toggle() => app.settings.setSelected([AppSettings.key(c.slug)], !on);
    return ListTile(
      leading: ChainLogo(c, size: 40),
      title: Text(c.name),
      subtitle: Text(sub),
      trailing: Checkbox(value: on, onChanged: (_) => toggle()),
      onTap: toggle,
    );
  }
}
