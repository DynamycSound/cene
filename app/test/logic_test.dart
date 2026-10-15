import 'dart:convert';
import 'dart:io';

import 'package:cene/data/db.dart';
import 'package:cene/data/images.dart';
import 'package:cene/data/models.dart';
import 'package:cene/data/shopping_list.dart';
import 'package:cene/data/web_shops.dart';
import 'package:cene/util/fold.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

Chain _c(int id, String slug) => Chain(id, slug, slug, 'gov', Colors.red, null, null);

Offer _o(int pid, int fid, Chain c, double price, {double? sale, String? format}) => Offer(
    productId: pid, formatId: fid, chain: c, formatName: format, price: price, salePrice: sale,
    saleFrom: sale == null ? null : todayInt(DateTime.now().subtract(const Duration(days: 1))),
    saleTo: sale == null ? null : todayInt(DateTime.now().add(const Duration(days: 1))));

void main() {
  test('fold i reči pretrage (isto kao pipeline)', () {
    expect(fold('Mleko ČOKOLADNO đak Млеко'), 'mleko cokoladno djak mleko');
    expect(searchTokens('Mleka 2,8% Imlek'), ['mlek', '2,8', 'imle']);
    expect(searchTokens('  '), isEmpty);
  });

  test('cena i datum za prikaz', () {
    expect(fmtPrice(1299.9), '1.299,90 din');
    expect(fmtPrice(57.99), '57,99 din');
    expect(fmtPrice(13999), '13.999 din');
    expect(fmtDateInt(20261015), '15.10.2026.');
    expect([1, 3, 5, 11, 12, 21, 22, 25].map((n) => plural(n, 'lancu', 'lanca', 'lanaca')),
        ['1 lancu', '3 lanca', '5 lanaca', '11 lanaca', '12 lanaca', '21 lancu', '22 lanca', '25 lanaca']);
    expect(['MERCATOR', 'UNIVEREXPORT - M', 'Maxi Online'].map(PriceDb.prettyName),
        ['Mercator', 'Univerexport - M', 'Maxi Online']);
  });

  test('Gigatron: proizvodi iz RSC payload-a prave stranice pretrage', () {
    final page = File('test/fixtures/gigatron_search.html').readAsStringSync();
    final r = parseGigatron(page);
    expect(r.length, 24);
    final first = r.first;
    expect(first.price, 13999);
    expect(first.url, startsWith('https://gigatron.rs/proizvod/'));
    expect(first.image, contains('vtexassets.com'));
    expect(r.where((p) => p.name.toLowerCase().contains('air')).length, greaterThan(5));
  });

  test('Uspon: kartice proizvoda iz HTML-a', () {
    final page = File('test/fixtures/uspon_search.html').readAsStringSync();
    final r = parseUspon(page);
    expect(r, isNotEmpty);
    final p = r.firstWhere((p) => p.name.startsWith('AirFryer Ufesa Jacana'));
    expect(p.price, 17099.0);
    expect(p.url, 'https://www.uspon.rs/artikal/airfryer-ufesa-jacana-10-l-8-programa-crna');
    expect(p.image, 'https://www.uspon.rs/images/products/big/136734.webp');
    expect(r.every((p) => p.price != null && p.price! > 0), isTrue);
  });

  test('sličnost naziva tehnike', () {
    expect(nameSimilarity('Air fryer Ufesa Jacana 10l crna', 'AirFryer Ufesa Jacana/10 l/8 programa/crna'), greaterThan(0.5));
    expect(nameSimilarity('Air fryer Ufesa Jacana 10l crna', 'AirFryer Ufesa Jacana/10 l/8 programa/crna'), 1.0);
    expect(nameSimilarity('Ufesa AirFryer Jacana 10L', 'Ufesa Air Fryer Jacana 8L'), 0);
    expect(nameSimilarity('Samsung Galaxy A55 128GB', 'Samsung Galaxy A35 128GB'), 0);
    expect(nameSimilarity('SAMSUNG Galaxy A55 5G 8/128GB Navy', 'Mobilni telefon Samsung Galaxy A55 5G 8GB/128GB plavi'),
        greaterThan(0.8)); // „8/128GB“ = „8GB/128GB“
    expect(compareQuery('AirFryer Ufesa Jacana/10 l/8 programa/crna'), 'AirFryer Ufesa Jacana 10');
  });

  test('slike sa Open Food Facts: upit se završi, rezultat i „nema slike“ se pamte, više istovremenih', () async {
    var calls = 0;
    final imgs = ProductImages.instance
      ..client = MockClient((req) async {
        calls++;
        await Future<void>.delayed(const Duration(milliseconds: 20));
        final code = req.url.pathSegments.last.replaceAll('.json', '');
        if (code.endsWith('9')) return http.Response('{"status":0}', 404);
        return http.Response(jsonEncode({'product': {'image_front_small_url': 'https://img/$code.jpg'}}), 200);
      });
    final eans = [for (var i = 0; i < 10; i++) '860150011600$i'];
    final r = await Future.wait(eans.map(imgs.forEan)).timeout(const Duration(seconds: 5));
    expect(r.first, 'https://img/8601500116000.jpg');
    expect(r.last, isNull); // 404 -> nema slike
    expect(calls, 10);
    expect(imgs.cached(eans.first), r.first);
    expect(imgs.known(eans.last), isTrue);
    await imgs.forEan(eans.first); // iz keša, bez novog upita
    expect(calls, 10);
    expect(await imgs.forEan('205123'), isNull); // interna šifra – ne traži se
  });

  test('korpa: jedna radnja vs. kombinacija, akcija i stavke kojih nema', () {
    final maxi = _c(1, 'Maxi'), lidl = _c(2, 'Lidl');
    final mleko = ListItem('1', 'mleko', 2), hleb = ListItem('2', 'hleb'), kavijar = ListItem('3', 'kavijar');
    final r = planBasket([mleko, hleb, kavijar], {
      mleko: [_o(1, 1, maxi, 150, sale: 120), _o(1, 2, lidl, 130)],
      hleb: [_o(2, 1, maxi, 60), _o(2, 2, lidl, 70)],
      kavijar: [],
    });
    // Maxi: 2*120 (akcija) + 60 = 300; Lidl: 2*130 + 70 = 330
    expect(r.bestSingle!.label, 'Maxi');
    expect(r.bestSingle!.total, 300);
    expect(r.stores[1].total, 330);
    expect(r.splitTotal, 300);
    expect(r.nowhere, ['kavijar']);

    // radnja kojoj fali stavka ide iza one koja ima sve, iako je jeftinija
    final r2 = planBasket([mleko, hleb], {
      mleko: [_o(1, 1, maxi, 150), _o(1, 2, lidl, 100)],
      hleb: [_o(2, 1, maxi, 60)],
    });
    expect(r2.bestSingle!.label, 'Maxi');
    expect(r2.stores[1].missing, ['hleb']);
    expect(r2.splitTotal, 2 * 100 + 60);
  });

  test('formati istog lanca su jedan red; format se pominje samo kad se cene razlikuju', () {
    final maxi = _c(1, 'Maxi'), lidl = _c(2, 'Lidl');
    final g = groupByChain([
      _o(1, 1, maxi, 209.99, format: 'Maxi'),
      _o(1, 3, maxi, 199.99, format: 'Shop and Go'),
      _o(1, 4, maxi, 199.99, format: 'Mega Maxi'),
      _o(1, 2, lidl, 205),
    ]);
    expect(g.map((c) => c.chain.name), ['Maxi', 'Lidl']);
    expect(g.first.best.effective, 199.99);
    expect(g.first.formatNote, 'ova cena: Shop and Go, Mega Maxi · drugde do 209,99 din');
    expect(g.last.formatNote, isNull);
    final same = groupByChain([_o(1, 1, maxi, 99, format: 'Maxi'), _o(1, 4, maxi, 99, format: 'Mega Maxi')]);
    expect(same.single.varies, isFalse);
    expect(same.single.formatNote, isNull);

    // korpa: lanac se računa po svom najpovoljnijem cenovniku, ne meša cene različitih vrsta radnji
    final a = ListItem('1', 'a'), b = ListItem('2', 'b');
    final r = planBasket([a, b], {
      a: [_o(1, 1, maxi, 100, format: 'Maxi'), _o(1, 4, maxi, 90, format: 'Mega Maxi')],
      b: [_o(2, 1, maxi, 50, format: 'Maxi'), _o(2, 4, maxi, 70, format: 'Mega Maxi')],
    });
    expect(r.stores, hasLength(1));
    expect(r.bestSingle!.label, 'Maxi');
    expect(r.bestSingle!.formatName, 'Maxi');
    expect(r.bestSingle!.total, 150);
    expect(r.splitTotal, 140);
  });
}
