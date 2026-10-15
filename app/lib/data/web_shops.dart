import 'dart:convert';

import 'package:html/parser.dart' as html;
import 'package:http/http.dart' as http;

import '../util/fold.dart';

/// Tehnika: Gigatron i Uspon nemaju zvanične cenovnike, pa se njihova javna pretraga poziva
/// uživo sa telefona, samo kad korisnik nešto traži (isto kao da je otvorio sajt).
/// Tehnomanija je iza Cloudflare zaštite – za nju se samo otvara njihova pretraga u browseru.
class WebProduct {
  final String shop; // slug lanca
  final String name, url;
  final double? price;
  final String? image, ean;
  final bool available;
  WebProduct({required this.shop, required this.name, required this.url, this.price, this.image,
      this.ean, this.available = true});
}

const _ua = 'Mozilla/5.0 (Linux; Android 14; Mobile) AppleWebKit/537.36 (KHTML, like Gecko) '
    'Chrome/141.0 Mobile Safari/537.36';

class WebShopError implements Exception {
  final String shop, message;
  WebShopError(this.shop, this.message);
  @override
  String toString() => '$shop: $message';
}

Future<String> _get(String shop, Uri url, http.Client c) async {
  final r = await c.get(url, headers: {'User-Agent': _ua, 'Accept-Language': 'sr-RS,sr;q=0.9'})
      .timeout(const Duration(seconds: 20));
  if (r.statusCode != 200) throw WebShopError(shop, 'HTTP ${r.statusCode}');
  return utf8.decode(r.bodyBytes, allowMalformed: true);
}

// ---------- Gigatron (Next.js; rezultati su u RSC payload-u self.__next_f.push) ----------

final _flightRx = RegExp(r'self\.__next_f\.push\(\[1,"((?:[^"\\]|\\.)*)"\]\)');

/// Vrati JSON niz koji počinje na [start] (indeks znaka '[') – kao Python raw_decode.
String _jsonArrayAt(String s, int start) {
  var depth = 0;
  var inStr = false;
  for (var i = start; i < s.length; i++) {
    final ch = s.codeUnitAt(i);
    if (inStr) {
      if (ch == 0x5C) {
        i++; // escape
      } else if (ch == 0x22) {
        inStr = false;
      }
      continue;
    }
    if (ch == 0x22) {
      inStr = true;
    } else if (ch == 0x5B || ch == 0x7B) {
      depth++;
    } else if (ch == 0x5D || ch == 0x7D) {
      depth--;
      if (depth == 0) return s.substring(start, i + 1);
    }
  }
  throw const FormatException('nezavršen JSON niz');
}

List<WebProduct> parseGigatron(String page) {
  final flight = StringBuffer();
  for (final m in _flightRx.allMatches(page)) {
    flight.write(jsonDecode('"${m.group(1)}"') as String);
  }
  final s = flight.toString();
  final i = s.indexOf('"productRes":{"products":');
  if (i < 0) {
    if (s.contains('"productRes"')) return [];
    throw WebShopError('gigatron', 'promenjen format stranice (nema productRes)');
  }
  final arr = jsonDecode(_jsonArrayAt(s, s.indexOf('[', i))) as List;
  final out = <WebProduct>[];
  for (final p in arr.cast<Map<String, dynamic>>()) {
    final items = (p['items'] as List?) ?? const [];
    if (items.isEmpty) continue;
    final it = items.first as Map<String, dynamic>;
    final sellers = (it['sellers'] as List?) ?? const [];
    final offer = sellers.isEmpty ? null : (sellers.first as Map)['commertialOffer'] as Map?;
    final price = (offer?['ListPrice'] ?? offer?['Price']) as num?;
    final refs = (it['referenceId'] as List?) ?? const [];
    final images = (it['images'] as List?) ?? const [];
    out.add(WebProduct(
      shop: 'gigatron',
      name: (p['productName'] ?? '') as String,
      url: 'https://gigatron.rs/proizvod/${p['linkText']}',
      price: price?.toDouble(),
      image: images.isEmpty ? null : (images.first as Map)['imageUrl'] as String?,
      ean: refs.isEmpty ? null : (refs.first as Map)['Value']?.toString(),
      available: ((offer?['AvailableQuantity'] ?? 0) as num) > 0,
    ));
  }
  return out;
}

Future<List<WebProduct>> searchGigatron(String q, {http.Client? client}) async {
  final c = client ?? http.Client();
  try {
    return parseGigatron(
        await _get('gigatron', Uri.https('gigatron.rs', '/pretraga', {'q': q}), c));
  } finally {
    if (client == null) c.close();
  }
}

// ---------- Uspon (klasičan HTML) ----------

double? _lastPrice(String text) {
  final ms = RegExp(r'\d{1,3}(?:\.\d{3})*(?:,\d{2})?').allMatches(text).toList();
  if (ms.isEmpty) return null;
  final s = ms.last.group(0)!.replaceAll('.', '').replaceAll(',', '.');
  return double.tryParse(s);
}

List<WebProduct> parseUspon(String page) {
  final doc = html.parse(page);
  final out = <WebProduct>[];
  for (final card in doc.querySelectorAll('div.product-card article.shop-product-card')) {
    final a = card.querySelector('h2.product-name a');
    if (a == null) continue;
    final img = card.querySelector('img.product-image');
    final priceEl = card.querySelector('.price-holder');
    out.add(WebProduct(
      shop: 'uspon',
      name: a.text.trim().replaceAll(RegExp(r'\s+'), ' '),
      url: a.attributes['href'] ?? 'https://www.uspon.rs',
      image: img?.attributes['data-src'] ?? img?.attributes['src'],
      price: priceEl == null ? null : _lastPrice(priceEl.text),
    ));
  }
  return out;
}

Future<List<WebProduct>> searchUspon(String q, {http.Client? client}) async {
  final c = client ?? http.Client();
  try {
    return parseUspon(await _get('uspon', Uri.parse('https://www.uspon.rs/search/${Uri.encodeComponent(q)}'), c));
  } finally {
    if (client == null) c.close();
  }
}

/// Pretraži izabrane web prodavnice paralelno. Greška jedne prodavnice ne ruši ostale,
/// ali se vraća korisniku (nije progutana).
Future<(List<WebProduct>, List<WebShopError>)> searchWeb(String q, Set<String> shops) async {
  final jobs = <Future<List<WebProduct>>>[];
  final errors = <WebShopError>[];
  Future<List<WebProduct>> guard(String shop, Future<List<WebProduct>> f) => f.catchError((Object e) {
        errors.add(e is WebShopError ? e : WebShopError(shop, e.toString()));
        return <WebProduct>[];
      });
  if (shops.contains('gigatron')) jobs.add(guard('gigatron', searchGigatron(q)));
  if (shops.contains('uspon')) jobs.add(guard('uspon', searchUspon(q)));
  final res = (await Future.wait(jobs)).expand((e) => e).toList();
  return (res, errors);
}

/// Koliko su dva naziva tehnike slična (udeo zajedničkih reči; brojevi/modeli nose više).
/// Reči naziva: „10 l“ → „10l“ (broj + kratka jedinica), cifre se zadržavaju i kad su jednocifrene.
List<String> _nameWords(String s) {
  final raw = RegExp(r'[a-z0-9]+').allMatches(fold(s)).map((m) => m.group(0)!).toList();
  final out = <String>[];
  for (var i = 0; i < raw.length; i++) {
    final w = raw[i];
    if (RegExp(r'^\d+$').hasMatch(w) && i + 1 < raw.length && RegExp(r'^[a-z]{1,3}$').hasMatch(raw[i + 1])) {
      out.add(w + raw[++i]);
    } else if (w.length > 1 || RegExp(r'\d').hasMatch(w)) {
      out.add(w);
    }
  }
  return out;
}

/// Koliko liče dva naziva tehnike (0..1), mereno na kraćem nazivu. „Air fryer“ = „AirFryer“.
/// Reči sa ciframa (model, kapacitet) nose duplu težinu; ako se neka od njih ne poklapa, to nije isti proizvod.
double nameSimilarity(String a, String b) {
  final wa = _nameWords(a), wb = _nameWords(b);
  if (wa.isEmpty || wb.isEmpty) return 0;
  bool hasDigit(String w) => RegExp(r'\d').hasMatch(w);
  double weight(String w) => hasDigit(w) ? 2 : 1;
  double total(List<String> ws) => ws.fold(0, (s, w) => s + weight(w));
  final (small, other) = total(wa) <= total(wb) ? (wa, wb) : (wb, wa);
  final numUnit = RegExp(r'^(\d+)[a-z]+$');
  final otherSet = {...other, for (var i = 0; i + 1 < other.length; i++) other[i] + other[i + 1]};
  // goli broj i broj sa jedinicom su isti („8/128GB“ = „8GB/128GB“), ali „10l“ ≠ „10gb“
  final otherNums = {for (final w in other) ?numUnit.firstMatch(w)?.group(1)};
  bool found(String w) =>
      otherSet.contains(w) || otherNums.contains(w) || otherSet.contains(numUnit.firstMatch(w)?.group(1));
  final matched = List.generate(small.length, (i) => found(small[i]));
  for (var i = 0; i + 1 < small.length; i++) {
    if (other.contains(small[i] + small[i + 1])) matched[i] = matched[i + 1] = true;
  }
  var common = 0.0;
  for (var i = 0; i < small.length; i++) {
    if (matched[i]) {
      common += weight(small[i]);
    } else if (hasDigit(small[i])) {
      return 0;
    }
  }
  return common / total(small);
}

/// Kraći upit od naziva proizvoda za traženje istog proizvoda u drugoj prodavnici
String compareQuery(String name) {
  final words = name.replaceAll(RegExp(r'[/|,()]'), ' ').split(RegExp(r'\s+')).where((w) => w.isNotEmpty);
  return words.take(4).join(' ');
}
