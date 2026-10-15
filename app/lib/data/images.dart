import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

/// Slike proizvoda po barkodu sa Open Food Facts (besplatno, bez ključa).
/// Rezultat (i "nema slike") se pamti da se isti barkod ne traži ponovo.
class ProductImages {
  static final instance = ProductImages._();
  ProductImages._();

  /// zamenljiv u testovima
  http.Client client = http.Client();
  final Map<String, String> _cache = {}; // ean -> url ili '' (nema)
  final Map<String, Future<String?>> _pending = {};
  SharedPreferences? _p;
  int _active = 0;
  final _queue = <Completer<void>>[];

  Future<void> load() async {
    _p = await SharedPreferences.getInstance();
    final raw = _p!.getString('img_cache');
    if (raw != null) _cache.addAll((jsonDecode(raw) as Map).cast<String, String>());
  }

  Timer? _saveTimer;
  void _scheduleSave() {
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(seconds: 3), () {
      // ograniči veličinu keša
      if (_cache.length > 5000) {
        final keys = _cache.keys.take(_cache.length - 5000).toList();
        keys.forEach(_cache.remove);
      }
      _p?.setString('img_cache', jsonEncode(_cache));
    });
  }

  String? cached(String ean) {
    final v = _cache[ean];
    return (v == null || v.isEmpty) ? null : v;
  }

  bool known(String ean) => _cache.containsKey(ean);

  static String _gtin(String ean) => (ean.length > 8 && ean.length < 13) ? ean.padLeft(13, '0') : ean;

  Future<String?> forEan(String ean) {
    if (ean.length < 8 || ean.contains(':')) return Future.value(null);
    if (_cache.containsKey(ean)) return Future.value(cached(ean));
    // telo u {} – `=> _pending.remove(ean)` bi vratilo baš ovaj future, pa bi whenComplete čekao sam sebe zauvek
    return _pending[ean] ??= _fetch(ean).whenComplete(() {
      _pending.remove(ean);
    });
  }

  Future<String?> _fetch(String ean) async {
    // OFF traži najviše ~100 upita u minuti po korisniku – zato najviše 3 istovremeno
    if (_active >= 3) {
      final c = Completer<void>();
      _queue.add(c);
      await c.future;
    }
    _active++;
    try {
      final url = Uri.https('world.openfoodfacts.org', '/api/v2/product/${_gtin(ean)}.json',
          {'fields': 'image_front_small_url,image_small_url'});
      final r = await client.get(url, headers: {'User-Agent': 'Cene/1.0 (Android; poredjenje cena)'})
          .timeout(const Duration(seconds: 15));
      String img = '';
      if (r.statusCode == 200) {
        final j = jsonDecode(r.body) as Map<String, dynamic>;
        final p = j['product'] as Map<String, dynamic>?;
        img = (p?['image_front_small_url'] ?? p?['image_small_url'] ?? '') as String;
      } else if (r.statusCode != 404) {
        return null; // privremena greška (429/5xx) – ne pamti, probaće se kasnije
      }
      _cache[ean] = img;
      _scheduleSave();
      return img.isEmpty ? null : img;
    } on TimeoutException {
      return null;
    } finally {
      _active--;
      if (_queue.isNotEmpty) _queue.removeAt(0).complete();
    }
  }
}
