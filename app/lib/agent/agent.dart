import 'dart:convert';

import '../data/db.dart';
import '../data/location.dart';
import '../data/models.dart';
import '../data/settings.dart';
import '../data/shopping_list.dart';
import '../data/web_shops.dart';
import 'openrouter.dart';

class AgentReply {
  final String text;
  final List<int> productIds; // proizvodi koje treba prikazati kao kartice
  final List<WebProduct> web;
  final List<String> toolLog; // koji alati su pozvani (prikaz "šta je agent radio")
  AgentReply(this.text, this.productIds, this.web, this.toolLog);
}

Map<String, dynamic> _fn(String name, String description, Map<String, dynamic> props, List<String> req) => {
      'type': 'function',
      'function': {
        'name': name,
        'description': description,
        'parameters': {'type': 'object', 'properties': props, 'required': req},
      },
    };

final agentTools = [
  _fn('search_products', 'Pretraži namirnice, piće, kozmetiku, drogeriju i ostalo iz zvaničnih cenovnika '
      'trgovinskih lanaca. Vraća proizvode sa najnižom cenom u radnjama koje je korisnik izabrao.', {
    'query': {'type': 'string', 'description': 'naziv proizvoda, npr. "mleko 2,8%" ili "kafa grand 200g"'},
    'limit': {'type': 'integer', 'description': 'broj rezultata (podrazumevano 8, najviše 20)'},
  }, ['query']),
  _fn('compare_prices', 'Uporedi cene jednog ili više proizvoda (po product_id iz search_products) '
      'u izabranim radnjama, od najjeftinije.', {
    'product_ids': {'type': 'array', 'items': {'type': 'integer'}},
  }, ['product_ids']),
  _fn('plan_basket', 'Za spisak proizvoda nađi najjeftiniju JEDNU radnju za sve stavke i najjeftiniju '
      'kombinaciju po stavkama (kupovina u više radnji).', {
    'items': {
      'type': 'array',
      'items': {
        'type': 'object',
        'properties': {
          'product_id': {'type': 'integer'},
          'qty': {'type': 'integer', 'description': 'količina, podrazumevano 1'},
        },
        'required': ['product_id'],
      },
    },
  }, ['items']),
  _fn('nearby_stores', 'Najbliže radnje izabranih lanaca u odnosu na korisnikovu GPS lokaciju.', {
    'chain': {'type': 'string', 'description': 'ime lanca (npr. "Maxi", "Lidl"); bez ovoga sve izabrane'},
    'limit': {'type': 'integer'},
  }, []),
  _fn('search_electronics', 'Pretraži tehniku (telefoni, laptopovi, TV, bela tehnika, oprema) uživo na '
      'sajtovima Gigatron i Uspon (ako ih je korisnik izabrao). Vraća nazive, cene i linkove.', {
    'query': {'type': 'string'},
  }, ['query']),
];

class Agent {
  final PriceDb db;
  final AppSettings settings;
  final OpenRouter api;
  final List<Map<String, dynamic>> history = [];

  Agent(this.db, this.settings, this.api);

  Set<int> get _sel => settings.selectedFormatIds(db);

  String _systemPrompt() {
    final shops = [
      for (final id in settings.selectedChainIds(db)) db.chains[id]!.name,
    ];
    final d = DateTime.now();
    return 'Ti si asistent za kupovinu u Srbiji u aplikaciji „Cene“. Korisnikove izabrane radnje: '
        '${shops.isEmpty ? 'nijedna (reci mu da ih izabere u kartici Radnje)' : shops.join(', ')}.\n'
        'Pravila:\n'
        '- Uvek koristi alate. Nikad ne izmišljaj cene, proizvode ni radnje – sve brojke moraju doći iz rezultata alata.\n'
        '- Namirnice/drogerija: search_products, pa compare_prices; za više stavki plan_basket.\n'
        '- Tehnika: search_electronics.\n'
        '- Ako upit ima više proizvoda, traži svaki posebno. Ako nema rezultata, probaj kraći ili drugačiji naziv.\n'
        '- Odgovaraj kratko, na srpskom (latinica), cene u dinarima, navedi radnju za svaku cenu.\n'
        'Danas je ${d.day}.${d.month}.${d.year}.';
  }

  Future<AgentReply> ask(String userText) async {
    if (history.isEmpty) history.add({'role': 'system', 'content': _systemPrompt()});
    history.add({'role': 'user', 'content': userText});
    final shown = <int>[];
    final searched = <int>[];
    final web = <WebProduct>[];
    final log = <String>[];

    for (var step = 0; step < 8; step++) {
      final msg = await api.chat(settings.modelId, history, tools: agentTools);
      final calls = (msg['tool_calls'] as List?)?.cast<Map<String, dynamic>>() ?? const [];
      history.add({
        'role': 'assistant',
        'content': msg['content'] ?? '',
        if (calls.isNotEmpty) 'tool_calls': calls,
      });
      if (calls.isEmpty) {
        final ids = shown.isNotEmpty ? shown : searched.take(4).toList();
        return AgentReply(((msg['content'] ?? '') as String).trim(), ids.toSet().toList(), web, log);
      }
      for (final c in calls) {
        final f = c['function'] as Map<String, dynamic>;
        final name = f['name'] as String;
        Map<String, dynamic> args;
        try {
          final raw = f['arguments'];
          args = raw is String ? (raw.trim().isEmpty ? {} : jsonDecode(raw) as Map<String, dynamic>) : (raw as Map<String, dynamic>);
        } on FormatException catch (e) {
          args = {};
          log.add('$name: neispravni argumenti ($e)');
        }
        Object result;
        try {
          result = await _run(name, args, shown, searched, web);
          log.add('$name(${_short(args)})');
        } catch (e) {
          // greška alata se vraća modelu (da proba drugačije) i prikazuje u logu
          result = {'error': e.toString()};
          log.add('$name: greška $e');
        }
        history.add({'role': 'tool', 'tool_call_id': c['id'], 'content': jsonEncode(result)});
      }
    }
    return AgentReply('Agent nije završio u 8 koraka. Probaj jednostavnije pitanje.', shown, web, log);
  }

  String _short(Map<String, dynamic> a) {
    final s = a.values.map((v) => v is List ? plural(v.length, 'stavka', 'stavke', 'stavki') : '$v').join(', ');
    return s.length > 40 ? '${s.substring(0, 40)}…' : s;
  }

  Map<String, dynamic> _offerJson(ChainOffer c) {
    final o = c.best;
    return {
      'store': o.label,
      'price': o.effective,
      if (o.onSale) 'regular_price': o.price,
      if (o.onSale && o.saleTo != null) 'sale_until': fmtDateInt(o.saleTo),
      if (o.unitPrice != null) 'unit_price': o.unitPrice,
      if (c.formatNote != null) 'note': c.formatNote,
    };
  }

  Future<Object> _run(String name, Map<String, dynamic> a, List<int> shown, List<int> searched,
      List<WebProduct> web) async {
    switch (name) {
      case 'search_products':
        final q = (a['query'] ?? '').toString();
        final limit = ((a['limit'] as num?)?.toInt() ?? 8).clamp(1, 20);
        var words = q.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();
        var hits = <ProductHit>[];
        // ako nema pogodaka sa svim rečima, skraćuj upit
        while (words.isNotEmpty) {
          hits = await db.search(words.join(' '), _sel, limit: limit);
          if (hits.isNotEmpty) break;
          words = words.sublist(0, words.length - 1);
        }
        searched.addAll(hits.map((h) => h.id));
        final offers = await db.offersFor(hits.map((h) => h.id));
        return [
          for (final h in hits)
            {
              'product_id': h.id,
              'name': h.name,
              if (h.brand.isNotEmpty) 'brand': h.brand,
              'cheapest_in_my_stores': h.bestSelected,
              'cheapest_store': (offers[h.id] ?? []).where((o) => _sel.contains(o.formatId)).firstOrNull?.label,
              'my_stores_with_it': h.offers,
              if (h.bestSelected == null) 'note': 'nema ga u izabranim radnjama; najniža cena drugde ${h.bestAll}',
            },
        ];
      case 'compare_prices':
        final ids = ((a['product_ids'] as List?) ?? []).map((e) => (e as num).toInt()).toList();
        shown.addAll(ids);
        final offers = await db.offersFor(ids);
        final out = [];
        for (final id in ids) {
          final p = await db.product(id, _sel);
          if (p == null) {
            out.add({'product_id': id, 'error': 'nepoznat product_id'});
            continue;
          }
          final mine = groupByChain((offers[id] ?? []).where((o) => _sel.contains(o.formatId)));
          out.add({
            'product_id': id,
            'name': p.name,
            'offers_in_my_stores': mine.take(8).map(_offerJson).toList(),
            if (mine.isEmpty) 'note': 'nema ga u izabranim radnjama',
          });
        }
        return out;
      case 'plan_basket':
        final raw = ((a['items'] as List?) ?? []).cast<Map<String, dynamic>>();
        final items = <ListItem>[];
        final offers = <ListItem, List<Offer>>{};
        final all = await db.offersFor(raw.map((e) => (e['product_id'] as num).toInt()));
        for (final e in raw) {
          final id = (e['product_id'] as num).toInt();
          final p = await db.product(id, _sel);
          if (p == null) continue;
          final it = ListItem(p.ean, p.name, ((e['qty'] as num?)?.toInt() ?? 1).clamp(1, 99));
          items.add(it);
          offers[it] = (all[id] ?? []).where((o) => _sel.contains(o.formatId)).toList();
          shown.add(id);
        }
        final r = planBasket(items, offers);
        return {
          'best_single_store': r.bestSingle == null
              ? null
              : {'store': r.bestSingle!.label, 'total': _r(r.bestSingle!.total), 'missing_items': r.bestSingle!.missing},
          'other_stores': r.stores.skip(1).take(4).map((s) => {'store': s.label, 'total': _r(s.total), 'missing_items': s.missing}).toList(),
          'split_plan': {
            'total': _r(r.splitTotal),
            'lines': r.split.map((l) => {'item': l.item, 'qty': l.qty, ..._offerJson(ChainOffer([l.offer]))}).toList(),
          },
          'not_in_any_store': r.nowhere,
        };
      case 'nearby_stores':
        final loc = await Locator.current();
        if (loc.pos == null) return {'error': loc.problem ?? 'lokacija nije dostupna'};
        var chainIds = settings.selectedChainIds(db);
        final want = (a['chain'] ?? '').toString().toLowerCase();
        if (want.isNotEmpty) {
          chainIds = chainIds.where((id) => db.chains[id]!.name.toLowerCase().contains(want)).toSet();
        }
        final limit = ((a['limit'] as num?)?.toInt() ?? 5).clamp(1, 20);
        final near = Locator.nearby(await db.stores(chainIds), loc.pos, 0).take(limit);
        return [
          for (final (s, d) in near)
            {
              'store': db.chains[s.chainId]!.name,
              'name': s.name,
              'address': [s.address, s.city].where((x) => x.isNotEmpty).join(', '),
              'distance_km': d == null ? null : _r(d),
            },
        ];
      case 'search_electronics':
        final shops = {
          for (final s in ['gigatron', 'uspon'])
            if (settings.isSelected(s)) s,
        };
        if (shops.isEmpty) return {'error': 'korisnik nije izabrao Gigatron ni Uspon u Radnjama'};
        final (res, errs) = await searchWeb((a['query'] ?? '').toString(), shops);
        res.sort((x, y) => (x.price ?? double.infinity).compareTo(y.price ?? double.infinity));
        final top = res.take(10).toList();
        web.addAll(top);
        return {
          'results': [
            for (final p in top)
              {'shop': db.chainBySlug(p.shop)?.name ?? p.shop, 'name': p.name, 'price': p.price, 'available': p.available, 'url': p.url},
          ],
          if (errs.isNotEmpty) 'errors': errs.map((e) => e.toString()).toList(),
          if (settings.isSelected('tehnomanija')) 'note': 'Tehnomanija se ne pretražuje automatski; korisnik je može otvoriti dugmetom.',
        };
    }
    throw ArgumentError('nepoznat alat $name');
  }

  static double _r(double v) => (v * 100).roundToDouble() / 100;
}
