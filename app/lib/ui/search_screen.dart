import 'dart:async';

import 'package:flutter/material.dart';

import '../app_state.dart';
import '../data/models.dart';
import '../data/web_shops.dart';
import '../main.dart';
import 'agent_screen.dart';
import 'product_screen.dart';
import 'web_product_screen.dart';
import 'widgets.dart';

class SearchScreen extends StatefulWidget {
  const SearchScreen({super.key});
  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends State<SearchScreen> {
  bool _aiMode = true;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: app.settings,
      builder: (context, _) {
        final ai = app.settings.aiReady && _aiMode;
        return Scaffold(
          appBar: AppBar(
            title: const Text('Cene'),
            actions: [
              if (app.settings.aiReady)
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: SegmentedButton<bool>(
                    showSelectedIcon: false,
                    segments: const [
                      ButtonSegment(value: false, icon: Icon(Icons.search), label: Text('Pretraga')),
                      ButtonSegment(value: true, icon: Icon(Icons.auto_awesome), label: Text('AI')),
                    ],
                    selected: {_aiMode},
                    onSelectionChanged: (s) => setState(() => _aiMode = s.first),
                  ),
                ),
            ],
          ),
          body: ai ? const AgentView() : const ClassicSearch(),
        );
      },
    );
  }
}

class ClassicSearch extends StatefulWidget {
  const ClassicSearch({super.key});
  @override
  State<ClassicSearch> createState() => _ClassicSearchState();
}

class _ClassicSearchState extends State<ClassicSearch> {
  final _q = TextEditingController();
  Timer? _debounce;
  List<ProductHit> _hits = [];
  List<WebProduct> _web = [];
  List<WebShopError> _webErrors = [];
  bool _webLoading = false;
  String _webQuery = '';
  int _seq = 0;

  @override
  void initState() {
    super.initState();
    // promena izabranih radnji ili nova baza -> osveži rezultate
    app.settings.addListener(_refresh);
    app.store.addListener(_refresh);
  }

  void _refresh() {
    if (!mounted) return;
    setState(() {}); // baner „Izaberi radnje“, Tehnomanija link…
    if (_q.text.trim().isNotEmpty && app.store.db != null) _searchLocal(_q.text);
  }

  @override
  void dispose() {
    app.settings.removeListener(_refresh);
    app.store.removeListener(_refresh);
    _debounce?.cancel();
    _q.dispose();
    super.dispose();
  }

  Set<String> get _webShops => {
        for (final s in ['gigatron', 'uspon'])
          if (app.settings.isSelected(s)) s,
      };

  void _onChanged(String v) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 250), () => _searchLocal(v));
  }

  Future<void> _searchLocal(String v) async {
    final db = app.store.db!;
    final seq = ++_seq;
    final hits = await db.search(v, app.settings.selectedFormatIds(db));
    if (mounted && seq == _seq) setState(() => _hits = hits);
  }

  /// tehnika se traži tek na „Traži“ (Enter), da ne šaljemo upit sajtu za svako slovo
  Future<void> _searchWeb(String v) async {
    final q = v.trim();
    if (q.length < 2 || _webShops.isEmpty) return;
    setState(() {
      _webLoading = true;
      _webQuery = q;
    });
    final (res, errs) = await searchWeb(q, _webShops);
    res.sort((a, b) => (a.price ?? double.infinity).compareTo(b.price ?? double.infinity));
    if (mounted && _webQuery == q) {
      setState(() {
        _web = res;
        _webErrors = errs;
        _webLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final db = app.store.db!;
    final t = Theme.of(context);
    final noStores = app.settings.selected.isEmpty;
    final tehno = db.chainBySlug('tehnomanija');
    final q = _q.text.trim();
    return Column(children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
        child: SearchBar(
          controller: _q,
          hintText: 'Šta tražiš? npr. mleko, kafa, laptop…',
          leading: const Icon(Icons.search),
          trailing: [
            if (_q.text.isNotEmpty)
              IconButton(
                  icon: const Icon(Icons.clear),
                  onPressed: () {
                    _q.clear();
                    setState(() {
                      _hits = [];
                      _web = [];
                      _webQuery = '';
                    });
                  }),
          ],
          onChanged: (v) {
            setState(() {});
            _onChanged(v);
          },
          onSubmitted: (v) {
            _searchLocal(v);
            _searchWeb(v);
          },
          textInputAction: TextInputAction.search,
        ),
      ),
      if (noStores)
        MaterialBanner(
          content: const Text('Izaberi radnje u kojima kupuješ da bi video poređenje.'),
          actions: [TextButton(onPressed: () => currentTab.value = 3, child: const Text('Izaberi'))],
        ),
      Expanded(
        child: q.isEmpty
            ? const EmptyHint(Icons.manage_search,
                'Ukucaj proizvod. Rezultati iz cenovnika se pojavljuju dok kucaš, a tehnika (Gigatron, Uspon) kad pritisneš Traži.')
            : ListView(children: [
                for (final h in _hits)
                  ProductTile(h,
                      onTap: () => Navigator.push(
                          context, MaterialPageRoute(builder: (_) => ProductScreen(productId: h.id)))),
                if (_hits.isEmpty && _web.isEmpty && !_webLoading)
                  Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text('Nema proizvoda za „$q“ u cenovnicima.', textAlign: TextAlign.center),
                  ),
                if (_webShops.isNotEmpty || tehno != null && app.settings.isSelected('tehnomanija')) ...[
                  const Divider(),
                  ListTile(
                    title: Text('Tehnika (uživo sa sajtova)', style: t.textTheme.titleSmall),
                    trailing: _webLoading
                        ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                        : (_webShops.isNotEmpty && _webQuery != q
                            ? TextButton.icon(
                                icon: const Icon(Icons.travel_explore),
                                label: const Text('Traži'),
                                onPressed: () => _searchWeb(q))
                            : null),
                  ),
                  for (final e in _webErrors)
                    ListTile(
                        dense: true,
                        leading: Icon(Icons.error_outline, color: t.colorScheme.error),
                        title: Text(e.toString())),
                  for (final w in _web)
                    WebProductTile(w,
                        chain: db.chainBySlug(w.shop),
                        shopName: db.chainBySlug(w.shop)?.name ?? w.shop,
                        onTap: () => Navigator.push(
                            context, MaterialPageRoute(builder: (_) => WebProductScreen(product: w)))),
                  if (tehno != null && app.settings.isSelected('tehnomanija') && tehno.searchUrl != null)
                    ListTile(
                      leading: ChainLogo(tehno, size: 40),
                      title: const Text('Pretraži na Tehnomaniji'),
                      subtitle: const Text('otvara njihov sajt'),
                      trailing: const Icon(Icons.open_in_new),
                      onTap: () => openUrl(context, tehno.searchUrl!.replaceAll('{q}', Uri.encodeComponent(q))),
                    ),
                ],
                const SizedBox(height: 24),
              ]),
      ),
    ]);
  }
}
