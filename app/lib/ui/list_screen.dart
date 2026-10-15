import 'package:flutter/material.dart';

import '../app_state.dart';
import '../data/models.dart';
import '../data/shopping_list.dart';
import '../main.dart';
import 'map_screen.dart';
import 'widgets.dart';

class ListScreen extends StatefulWidget {
  const ListScreen({super.key});
  @override
  State<ListScreen> createState() => _ListScreenState();
}

class _ListScreenState extends State<ListScreen> {
  BasketResult? _r;
  int _seq = 0;

  @override
  void initState() {
    super.initState();
    app.list.addListener(_compute);
    app.settings.addListener(_compute);
    app.store.addListener(_compute);
    _compute();
  }

  @override
  void dispose() {
    app.list.removeListener(_compute);
    app.settings.removeListener(_compute);
    app.store.removeListener(_compute);
    super.dispose();
  }

  Future<void> _compute() async {
    final db = app.store.db;
    if (db == null) return;
    final seq = ++_seq;
    final sel = app.settings.selectedFormatIds(db);
    final items = List.of(app.list.items);
    final byItem = <ListItem, List<int>>{};
    final names = <ListItem, String>{};
    for (final it in items) {
      final ps = await db.byEan(it.ean, sel);
      // interne šifre mogu da se ponove u više lanaca – prednost ima isti naziv
      final same = ps.where((p) => p.name == it.name).toList();
      final use = same.isNotEmpty ? same : ps;
      byItem[it] = use.map((p) => p.id).toList();
      if (use.isNotEmpty) names[it] = use.first.name;
    }
    if (seq != _seq) return;
    // stavka dodata sa starijom bazom dobija današnji (očišćen) naziv; rename javlja promenu i računa se ponovo
    await app.list.rename(names);
    if (seq != _seq) return;
    final all = await db.offersFor(byItem.values.expand((e) => e));
    final offers = {
      for (final it in items)
        it: [
          for (final id in byItem[it]!) ...(all[id] ?? <Offer>[]).where((o) => sel.contains(o.formatId)),
        ],
    };
    final r = planBasket(items, offers);
    if (mounted && seq == _seq) setState(() => _r = r);
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final items = app.list.items;
    final r = _r;
    return Scaffold(
      appBar: AppBar(title: const Text('Spisak za kupovinu'), actions: [
        if (items.isNotEmpty)
          IconButton(
            tooltip: 'Obriši spisak',
            icon: const Icon(Icons.delete_sweep_outlined),
            onPressed: () async {
              final ok = await showDialog<bool>(
                context: context,
                builder: (c) => AlertDialog(
                  title: const Text('Obrisati ceo spisak?'),
                  actions: [
                    TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Ne')),
                    FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Obriši')),
                  ],
                ),
              );
              if (ok == true) await app.list.clear();
            },
          ),
      ]),
      body: items.isEmpty
          ? EmptyHint(Icons.checklist, 'Spisak je prazan. Nađi proizvod u Pretrazi i dodirni „Na spisak“.',
              action: FilledButton(onPressed: () => currentTab.value = 0, child: const Text('Pretraga')))
          : ListView(padding: const EdgeInsets.only(bottom: 24), children: [
              for (final it in items)
                ListTile(
                  title: Text(it.name, maxLines: 2, overflow: TextOverflow.ellipsis),
                  trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                    IconButton(icon: const Icon(Icons.remove_circle_outline), onPressed: () => app.list.setQty(it, it.qty - 1)),
                    Text('${it.qty}', style: t.textTheme.titleMedium),
                    IconButton(icon: const Icon(Icons.add_circle_outline), onPressed: () => app.list.setQty(it, it.qty + 1)),
                  ]),
                ),
              const Divider(),
              if (r == null)
                const LinearProgressIndicator()
              else ...[
                if (r.bestSingle != null) _singleCard(context, r),
                if (r.split.isNotEmpty) _splitCard(context, r),
                if (r.nowhere.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: Text('Nema ni u jednoj izabranoj radnji: ${r.nowhere.join(', ')}',
                        style: TextStyle(color: t.colorScheme.error)),
                  ),
                if (r.stores.length > 1) ...[
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
                    child: Text('Sve izabrane radnje', style: t.textTheme.titleSmall),
                  ),
                  for (final s in r.stores)
                    ListTile(
                      dense: true,
                      leading: ChainLogo(s.chain, size: 32),
                      title: Text(s.label),
                      subtitle: s.missing.isEmpty ? null : Text('fali: ${s.missing.join(', ')}', maxLines: 2),
                      trailing: Text(fmtPrice(s.total), style: t.textTheme.titleSmall),
                    ),
                ],
              ],
            ]),
    );
  }

  Widget _singleCard(BuildContext context, BasketResult r) {
    final t = Theme.of(context);
    final b = r.bestSingle!;
    return Card(
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      color: t.colorScheme.primaryContainer,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Sve u jednoj radnji', style: t.textTheme.labelLarge),
          const SizedBox(height: 4),
          Row(children: [
            ChainLogo(b.chain, size: 40),
            const SizedBox(width: 12),
            Expanded(child: Text(b.label, style: t.textTheme.titleLarge)),
            Text(fmtPrice(b.total), style: t.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold)),
          ]),
          if (b.formatName != null) Text('po cenama u radnjama „${b.formatName}“', style: t.textTheme.bodySmall),
          if (b.missing.isNotEmpty) Text('Nema: ${b.missing.join(', ')}', style: TextStyle(color: t.colorScheme.error)),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton.icon(
              icon: const Icon(Icons.map_outlined),
              label: const Text('Gde je?'),
              onPressed: () => Navigator.push(context,
                  MaterialPageRoute(builder: (_) => MapScreen(onlyChainId: b.chain.id, title: b.label))),
            ),
          ),
        ]),
      ),
    );
  }

  Widget _splitCard(BuildContext context, BasketResult r) {
    final t = Theme.of(context);
    final single = r.bestSingle;
    final saving = single != null && single.missing.isEmpty ? single.total - r.splitTotal : null;
    return Card(
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Najjeftinije po stavkama (više radnji)', style: t.textTheme.labelLarge),
          const SizedBox(height: 4),
          Row(children: [
            Expanded(
                child: Text(saving != null && saving > 0.5 ? 'Ušteda ${fmtPrice(saving)}' : 'Ukupno',
                    style: t.textTheme.titleMedium)),
            Text(fmtPrice(r.splitTotal), style: t.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold)),
          ]),
          const SizedBox(height: 8),
          for (final l in r.split)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Row(children: [
                ChainLogo(l.offer.chain, size: 24),
                const SizedBox(width: 8),
                Expanded(child: Text('${l.qty > 1 ? '${l.qty}× ' : ''}${l.item}', maxLines: 1, overflow: TextOverflow.ellipsis)),
                const SizedBox(width: 8),
                Text(l.offer.label, style: t.textTheme.bodySmall),
                const SizedBox(width: 8),
                Text(fmtPrice(l.offer.effective * l.qty)),
              ]),
            ),
        ]),
      ),
    );
  }
}
