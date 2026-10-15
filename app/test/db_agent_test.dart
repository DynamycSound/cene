// Testovi nad pravom bazom koju pravi pipeline (pipeline/dist/cene.sqlite).
// Pokreni posle `python -m cene.build_db`; bez baze se preskaču.
import 'dart:convert';
import 'dart:io';

import 'package:cene/agent/agent.dart';
import 'package:cene/agent/openrouter.dart';
import 'package:cene/data/db.dart';
import 'package:cene/data/models.dart';
import 'package:cene/data/settings.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const dbPath = '../pipeline/dist/cene.sqlite';

void main() {
  final skip = File(dbPath).existsSync() ? null : 'nema $dbPath';
  late PriceDb db;
  late AppSettings settings;

  setUpAll(() async {
    if (skip != null) return;
    sqfliteFfiInit();
    db = await PriceDb.open(File(dbPath).absolute.path, factory: databaseFactoryFfi);
    settings = AppSettings()..selected = {'maxi|', 'lidl|', 'proleter|', 'gigatron|'};
  });

  test('pretraga bez dijakritika i ćirilicom, izabrane radnje prve', () async {
    final sel = settings.selectedFormatIds(db);
    // svi cenovnici izabranih lanaca (Maxi ih ima 5: Maxi, Mega Maxi, Shop and Go, Maxi Online, Profi)
    expect(sel, hasLength(sel.map((f) => db.formats[f]!.chainId).toSet().length + 4));
    final sw = Stopwatch()..start();
    final hits = await db.search('mleko 2,8', sel);
    sw.stop();
    expect(hits, isNotEmpty);
    expect(hits.first.bestSelected, isNotNull);
    // izabrana su 3 lanca hrane (Maxi sa 5 formata, Lidl, Proleter) – broji se lanac, ne format
    expect(hits.every((h) => h.offers <= 3), isTrue);
    expect(hits.any((h) => h.offers == 3), isTrue);
    expect(hits.take(10).every((h) => h.name.toLowerCase().contains('ml')), isTrue);
    // ćirilica i dijakritici daju iste rezultate kao latinica bez kvačica
    final a = await db.search('čokolada milka', sel);
    final b = await db.search('чоколада милка', sel);
    final c = await db.search('cokolada milka', sel);
    expect(a.map((h) => h.id), c.map((h) => h.id));
    expect(b.map((h) => h.id), c.map((h) => h.id));
    expect(a, isNotEmpty);
    // cela reč ispred skraćene: „milka“ ne sme da počne sa „Milk shake“
    final m = await db.search('milka', sel);
    // brend je izvađen iz naziva, a „milka“ može da stoji samo u robnoj marci drugog lanca – proverava se
    // kolona po kojoj se pretražuje
    final top = m.take(10).toList();
    final rows = await db.db.rawQuery(
        'SELECT search FROM products WHERE id IN (${List.filled(top.length, '?').join(',')})', [for (final h in top) h.id]);
    expect(rows.length, top.length);
    expect(rows.every((r) => ' ${r['search']} '.contains(' milka ')), isTrue,
        reason: top.map((h) => h.name).join(' | '));
    // ignore: avoid_print
    print('pretraga "mleko 2,8": ${hits.length} rezultata za ${sw.elapsedMilliseconds} ms; prvi: ${hits.first.name} ${hits.first.bestSelected}');
  }, skip: skip);

  test('poređenje po EAN-u kroz lance (Prolom voda 0,5 l)', () async {
    final sel = settings.selectedFormatIds(db);
    final ps = await db.byEan('8600169600046', sel);
    expect(ps.length, 1);
    final offers = await db.offers(ps.first.id);
    final chains = offers.map((o) => o.chain.slug).toSet();
    expect(chains, containsAll(['maxi', 'proleter']));
    expect(chains.length, greaterThan(5));
    for (var i = 1; i < offers.length; i++) {
      expect(offers[i].effective, greaterThanOrEqualTo(offers[i - 1].effective));
    }
    final mine = groupByChain(offers.where((o) => sel.contains(o.formatId)));
    // jedan red po lancu, od najjeftinijeg
    expect(mine.map((c) => c.chain.slug).toSet(), hasLength(mine.length));
    expect(mine.first.best.effective, lessThanOrEqualTo(mine.last.best.effective));
    expect(mine.map((c) => c.chain.name), containsAll(['Maxi', 'Proleter']));
  }, skip: skip);

  test('radnje sa koordinatama za izabrane lance', () async {
    final stores = await db.stores(settings.selectedChainIds(db));
    expect(stores.length, greaterThan(300));
    expect(stores.every((s) => s.lat > 41 && s.lat < 47 && s.lon > 18 && s.lon < 24), isTrue);
  }, skip: skip);

  test('AI agent: petlja sa alatima nad lokalnom bazom (lažni OpenRouter)', () async {
    final requests = <Map<String, dynamic>>[];
    var step = 0;
    final client = MockClient((req) async {
      final body = jsonDecode(req.body) as Map<String, dynamic>;
      requests.add(body);
      expect(req.headers['Authorization'], 'Bearer test-key');
      step++;
      Map<String, dynamic> msg;
      if (step == 1) {
        msg = {
          'role': 'assistant',
          'content': null,
          'tool_calls': [
            {'id': 'c1', 'type': 'function', 'function': {'name': 'search_products', 'arguments': '{"query":"prolom voda 0,5"}'}},
          ],
        };
      } else if (step == 2) {
        final toolMsg = (body['messages'] as List).last as Map<String, dynamic>;
        expect(toolMsg['role'], 'tool');
        expect(toolMsg['tool_call_id'], 'c1');
        final found = jsonDecode(toolMsg['content'] as String) as List;
        expect(found, isNotEmpty);
        final id = (found.first as Map)['product_id'];
        msg = {
          'role': 'assistant',
          'content': '',
          'tool_calls': [
            {'id': 'c2', 'type': 'function', 'function': {'name': 'compare_prices', 'arguments': jsonEncode({'product_ids': [id]})}},
          ],
        };
      } else {
        final toolMsg = (body['messages'] as List).last as Map<String, dynamic>;
        final cmp = jsonDecode(toolMsg['content'] as String) as List;
        final best = ((cmp.first as Map)['offers_in_my_stores'] as List).first as Map;
        msg = {'role': 'assistant', 'content': 'Najjeftinije je u ${best['store']}: ${best['price']} din.'};
      }
      return http.Response(jsonEncode({'choices': [{'message': msg, 'finish_reason': 'stop'}]}), 200,
          headers: {'content-type': 'application/json; charset=utf-8'});
    });
    final agent = Agent(db, settings, OpenRouter('test-key', client: client));
    final r = await agent.ask('gde je najjeftinija prolom voda?');
    expect(step, 3);
    expect(requests.first['model'], 'openrouter/free');
    expect((requests.first['tools'] as List).length, agentTools.length);
    expect((requests.first['messages'] as List).first['role'], 'system');
    expect(r.text, startsWith('Najjeftinije je u'));
    expect(r.productIds, hasLength(1));
    expect(r.toolLog.first, startsWith('search_products'));
    // ignore: avoid_print
    print('agent: ${r.text}  |  ${r.toolLog}');
  }, skip: skip);

  test('OpenRouter greška 429 je jasna poruka, ne tihi pad', () async {
    final client = MockClient((_) async => http.Response(
        jsonEncode({'error': {'code': 429, 'message': 'Rate limit exceeded: free-models-per-day'}}), 429));
    final agent = Agent(db, settings, OpenRouter('k', client: client));
    await expectLater(agent.ask('mleko'),
        throwsA(isA<OpenRouterError>().having((e) => e.rateLimited, 'rateLimited', isTrue)));
  }, skip: skip);
}
