import 'package:flutter/material.dart';

import '../app_state.dart';
import '../data/models.dart';
import '../data/web_shops.dart';
import 'widgets.dart';

/// Tehnika: isti (ili najsličniji) proizvod u ostalim izabranim web prodavnicama.
class WebProductScreen extends StatefulWidget {
  final WebProduct product;
  const WebProductScreen({super.key, required this.product});
  @override
  State<WebProductScreen> createState() => _WebProductScreenState();
}

class _WebProductScreenState extends State<WebProductScreen> {
  List<WebProduct>? _matches;
  List<WebShopError> _errors = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final p = widget.product;
    final shops = {
      for (final s in ['gigatron', 'uspon'])
        if (s != p.shop && app.settings.isSelected(s)) s,
    };
    final (res, errs) = await searchWeb(compareQuery(p.name), shops);
    final m = res.where((r) => nameSimilarity(r.name, p.name) >= 0.6 || (p.ean != null && r.ean == p.ean)).toList();
    m.add(p);
    m.sort((a, b) => (a.price ?? double.infinity).compareTo(b.price ?? double.infinity));
    if (mounted) {
      setState(() {
        _matches = m;
        _errors = errs;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final db = app.store.db!;
    final p = widget.product;
    final t = Theme.of(context);
    final tehno = db.chainBySlug('tehnomanija');
    return Scaffold(
      appBar: AppBar(title: const Text('Poređenje tehnike')),
      body: ListView(children: [
        Center(child: ProductImage(url: p.image, size: 200)),
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 16, 24, 12),
          child: Text(p.name, textAlign: TextAlign.center, style: t.textTheme.titleLarge),
        ),
        if (_matches == null) const LinearProgressIndicator(),
        for (final e in _errors)
          ListTile(leading: Icon(Icons.error_outline, color: t.colorScheme.error), title: Text(e.toString())),
        for (final m in _matches ?? <WebProduct>[])
          ListTile(
            leading: ChainLogo(db.chainBySlug(m.shop), size: 40),
            title: Text(db.chainBySlug(m.shop)?.name ?? m.shop),
            subtitle: Text(m.name, maxLines: 2, overflow: TextOverflow.ellipsis),
            trailing: Text(fmtPrice(m.price),
                style: t.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold, color: identical(m, _matches!.first) ? t.colorScheme.primary : null)),
            onTap: () => openUrl(context, m.url),
          ),
        if (_matches != null && _matches!.length == 1)
          const Padding(
            padding: EdgeInsets.all(16),
            child: Text('Isti proizvod nije nađen u drugim izabranim prodavnicama (poređenje je po nazivu modela).'),
          ),
        if (tehno != null && app.settings.isSelected('tehnomanija') && tehno.searchUrl != null)
          ListTile(
            leading: ChainLogo(tehno, size: 40),
            title: const Text('Proveri na Tehnomaniji'),
            trailing: const Icon(Icons.open_in_new),
            onTap: () => openUrl(context, tehno.searchUrl!.replaceAll('{q}', Uri.encodeComponent(compareQuery(p.name)))),
          ),
        Padding(
          padding: const EdgeInsets.all(16),
          child: Text('Cene tehnike su sa sajtova prodavnica u trenutku pretrage. Dodir otvara proizvod na sajtu.',
              style: t.textTheme.bodySmall),
        ),
      ]),
    );
  }
}
