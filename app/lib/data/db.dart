import 'package:sqflite/sqflite.dart';

import '../util/fold.dart';
import 'models.dart';

/// Lokalna baza cena (cene.sqlite koju pravi pipeline/GitHub Actions). Samo za čitanje.
class PriceDb {
  final Database db;
  final Map<int, Chain> chains = {};
  final Map<int, Format> formats = {};
  final Map<String, String> meta = {};
  final Map<int, List<Format>> formatsOfChain = {};

  PriceDb._(this.db);

  static Future<PriceDb> open(String path, {DatabaseFactory? factory}) async {
    final f = factory ?? databaseFactory;
    final db = await f.openDatabase(path, options: OpenDatabaseOptions(readOnly: true));
    final p = PriceDb._(db);
    await p._load();
    return p;
  }

  Future<void> close() => db.close();

  Future<void> _load() async {
    for (final r in await db.query('meta')) {
      meta[r['key'] as String] = (r['value'] ?? '') as String;
    }
    for (final r in await db.query('chains')) {
      final c = Chain(r['id'] as int, r['slug'] as String, r['name'] as String, r['kind'] as String,
          parseColor(r['color'] as String?), r['url'] as String?, r['search_url'] as String?);
      chains[c.id] = c;
    }
    for (final r in await db.query('formats')) {
      final f = Format(r['id'] as int, r['chain_id'] as int, r['name'] as String);
      formats[f.id] = f;
      formatsOfChain.putIfAbsent(f.chainId, () => []).add(f);
    }
  }

  String get builtAt => meta['built_at'] ?? '';
  int get schema => int.tryParse(meta['schema'] ?? '') ?? 0;

  Chain? chainBySlug(String slug) {
    for (final c in chains.values) {
      if (c.slug == slug) return c;
    }
    return null;
  }

  /// ime cenovnika unutar lanca, null kad lanac ima samo jedan
  String? formatName(int formatId) {
    final f = formats[formatId];
    if (f == null || (formatsOfChain[f.chainId]?.length ?? 1) <= 1) return null;
    return prettyName(f.name);
  }

  /// „MERCATOR“ -> „Mercator“, „UNIVEREXPORT - M“ -> „Univerexport - M“; mešovita slova ostaju
  static String prettyName(String s) => s != s.toUpperCase()
      ? s
      : s.split(' ').map((w) => w.length <= 1 ? w : w[0] + w.substring(1).toLowerCase()).join(' ');

  /// cena sa akcijom ako akcija važi danas
  static String _effSql(int today) =>
      'CASE WHEN pr.sale_price IS NOT NULL AND (pr.sale_from IS NULL OR pr.sale_from <= $today) '
      'AND (pr.sale_to IS NULL OR pr.sale_to >= $today) THEN pr.sale_price ELSE pr.price END';

  String _chainOfSelected(Set<int> selected) {
    final known = selected.where(formats.containsKey).toList();
    if (known.isEmpty) return 'NULL';
    return 'CASE pr.format_id ${known.map((f) => 'WHEN $f THEN ${formats[f]!.chainId}').join(' ')} END';
  }

  static String _ids(Iterable<int> ids) => ids.isEmpty ? '-1' : ids.join(',');

  ProductHit _hit(Map<String, Object?> r) => ProductHit(
        id: r['id'] as int,
        ean: (r['ean'] ?? '') as String,
        name: (r['name'] ?? '') as String,
        brand: (r['brand'] ?? '') as String,
        unit: (r['unit'] ?? '') as String,
        image: r['image'] as String?,
        imageBig: r['image_big'] as String?,
        nChains: (r['n_chains'] ?? 0) as int,
        bestSelected: (r['best_sel'] as num?)?.toDouble(),
        bestAll: ((r['best_all'] ?? 0) as num).toDouble(),
        offers: (r['n_offers'] ?? 0) as int,
      );

  String _hitSelect(Set<int> selected) {
    final eff = _effSql(todayInt());
    return 'SELECT p.id, p.ean, p.name, p.brand, p.unit, p.image, p.image_big, p.n_chains, '
        'MIN(CASE WHEN pr.format_id IN (${_ids(selected)}) THEN $eff END) AS best_sel, '
        'MIN($eff) AS best_all, '
        // broj različitih izabranih lanaca (Maxi i Mega Maxi su jedan lanac); format→lanac je ugrađen u upit,
        // JOIN na formats bi naterao SQLite na ~15× sporiji plan
        'COUNT(DISTINCT ${_chainOfSelected(selected)}) AS n_offers '
        'FROM products p JOIN prices pr ON pr.product_id = p.id ';
  }

  /// Pretraga po rečima (sve reči moraju da postoje), bez obzira na dijakritike i pismo.
  /// Proizvodi dostupni u izabranim radnjama idu prvi.
  Future<List<ProductHit>> search(String query, Set<int> selected, {int limit = 60}) async {
    final q = query.trim();
    final digits = q.replaceAll(RegExp(r'\D'), '');
    if (digits.length >= 8 && digits.length == q.replaceAll(' ', '').length) {
      final rows = await db.rawQuery(
          '${_hitSelect(selected)} WHERE p.ean = ? GROUP BY p.id', [digits.replaceFirst(RegExp(r'^0+'), '')]);
      return rows.map(_hit).toList();
    }
    final toks = searchTokens(q);
    if (toks.isEmpty) return [];
    final where = toks.map((_) => 'p.search LIKE ?').join(' AND ');
    // rang: koliko celih reči upita se javlja kao reč u nazivu (search je ' '-odvojen)
    final words = queryWords(q);
    final whole = words.map((_) => "((' ' || p.search || ' ') LIKE ?)").join(' + ');
    final args = <Object>[...toks.map((t) => '%$t%'), ...words.map((w) => '% $w %'), '${toks.first}%'];
    final rows = await db.rawQuery(
        '${_hitSelect(selected)} WHERE $where GROUP BY p.id '
        'ORDER BY best_sel IS NULL, ($whole) DESC, (p.search LIKE ?) DESC, p.n_chains DESC, length(p.name) '
        'LIMIT $limit',
        args);
    return rows.map(_hit).toList();
  }

  Future<ProductHit?> product(int id, Set<int> selected) async {
    final rows = await db.rawQuery('${_hitSelect(selected)} WHERE p.id = ? GROUP BY p.id', [id]);
    return rows.isEmpty ? null : _hit(rows.first);
  }

  Future<List<ProductHit>> byEan(String ean, Set<int> selected) async {
    final rows = await db.rawQuery('${_hitSelect(selected)} WHERE p.ean = ? GROUP BY p.id', [ean]);
    return rows.map(_hit).toList();
  }

  /// Sve ponude za proizvode, od najjeftinije (po ceni koja važi danas).
  Future<Map<int, List<Offer>>> offersFor(Iterable<int> productIds) async {
    final out = <int, List<Offer>>{};
    if (productIds.isEmpty) return out;
    final rows = await db.rawQuery(
        'SELECT * FROM prices pr WHERE pr.product_id IN (${_ids(productIds)})');
    for (final r in rows) {
      final fid = r['format_id'] as int;
      final f = formats[fid];
      if (f == null) continue;
      final o = Offer(
        productId: r['product_id'] as int,
        formatId: fid,
        chain: chains[f.chainId]!,
        formatName: formatName(fid),
        price: (r['price'] as num).toDouble(),
        unitPrice: (r['unit_price'] as num?)?.toDouble(),
        salePrice: (r['sale_price'] as num?)?.toDouble(),
        saleFrom: r['sale_from'] as int?,
        saleTo: r['sale_to'] as int?,
        date: r['date'] as int?,
      );
      out.putIfAbsent(o.productId, () => []).add(o);
    }
    for (final l in out.values) {
      l.sort((a, b) => a.effective.compareTo(b.effective));
    }
    return out;
  }

  Future<List<Offer>> offers(int productId) async => (await offersFor([productId]))[productId] ?? [];

  Future<List<Store>> stores(Set<int> chainIds) async {
    if (chainIds.isEmpty) return [];
    final rows = await db.rawQuery('SELECT * FROM stores WHERE chain_id IN (${_ids(chainIds)})');
    return [
      for (final r in rows)
        Store(r['id'] as int, r['chain_id'] as int, r['format_id'] as int?, (r['name'] ?? '') as String,
            (r['address'] ?? '') as String, (r['city'] ?? '') as String,
            (r['lat'] as num).toDouble(), (r['lon'] as num).toDouble()),
    ];
  }

  Future<Map<int, int>> storeCounts() async {
    final rows = await db.rawQuery('SELECT chain_id, count(*) n FROM stores GROUP BY chain_id');
    return {for (final r in rows) r['chain_id'] as int: r['n'] as int};
  }
}
