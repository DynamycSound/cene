import 'package:flutter/material.dart';

int todayInt([DateTime? d]) {
  d ??= DateTime.now();
  return d.year * 10000 + d.month * 100 + d.day;
}

String fmtDateInt(int? d) {
  if (d == null) return '';
  final y = d ~/ 10000, m = (d ~/ 100) % 100, day = d % 100;
  return '$day.$m.$y.';
}

String fmtPrice(double? p) {
  if (p == null) return '–';
  final whole = p.truncate();
  final dec = ((p - whole) * 100).round();
  final s = whole.toString().replaceAllMapped(RegExp(r'\B(?=(\d{3})+(?!\d))'), (_) => '.');
  return dec == 0 ? '$s din' : '$s,${dec.toString().padLeft(2, '0')} din';
}

Color parseColor(String? hex) {
  final h = (hex ?? '#607D8B').replaceFirst('#', '');
  return Color(int.parse('FF$h', radix: 16));
}

class Chain {
  final int id;
  final String slug, name, kind;
  final Color color;
  final String? url, searchUrl;
  Chain(this.id, this.slug, this.name, this.kind, this.color, this.url, this.searchUrl);

  /// gov = cene iz zvaničnih cenovnika u bazi; web = pretraga sajta uživo; link = samo link ka sajtu
  bool get isGov => kind == 'gov';
}

class Format {
  final int id, chainId;
  final String name;
  Format(this.id, this.chainId, this.name);
}

class ProductHit {
  final int id, nChains;
  final String ean, name, brand, unit;
  /// mala slika za listu i velika za ekran proizvoda
  final String? image, imageBig;
  /// najniža cena među izabranim radnjama (null = nema ga ni u jednoj izabranoj)
  final double? bestSelected;
  final double bestAll;
  /// broj izabranih lanaca koji imaju proizvod
  final int offers;
  ProductHit({required this.id, required this.ean, required this.name, required this.brand,
      required this.unit, this.image, this.imageBig, required this.nChains, this.bestSelected,
      required this.bestAll, required this.offers});
}

class Offer {
  final int productId, formatId;
  final Chain chain;
  /// cenovnik unutar lanca („Mega Maxi“), null kad lanac ima samo jedan
  final String? formatName;
  final double price;
  final double? unitPrice, salePrice;
  final int? saleFrom, saleTo, date;
  Offer({required this.productId, required this.formatId, required this.chain,
      this.formatName, required this.price, this.unitPrice, this.salePrice,
      this.saleFrom, this.saleTo, this.date});

  String get label => chain.name;

  bool get onSale {
    final t = todayInt();
    return salePrice != null && (saleFrom == null || saleFrom! <= t) && (saleTo == null || saleTo! >= t);
  }

  double get effective => onSale ? salePrice! : price;
}

/// Ponude jednog lanca za proizvod. Maxi, Mega Maxi, Shop&Go… su za kupca jedan lanac;
/// cenovnici (formati) se pominju samo kad im se cene razlikuju.
class ChainOffer {
  final List<Offer> offers; // od najjeftinije
  ChainOffer(this.offers);

  Chain get chain => offers.first.chain;
  Offer get best => offers.first;
  bool get varies => offers.last.effective - offers.first.effective >= 0.01;

  /// „ova cena: Shop and Go · drugde do 209,99 din“ kad cena zavisi od vrste radnje
  String? get formatNote {
    if (!varies) return null;
    final at = {
      for (final o in offers)
        if (o.effective - best.effective < 0.01 && o.formatName != null) o.formatName!,
    };
    return '${at.isEmpty ? '' : 'ova cena: ${at.join(', ')} · '}drugde do ${fmtPrice(offers.last.effective)}';
  }
}

/// po jedan red za lanac, od najjeftinijeg
List<ChainOffer> groupByChain(Iterable<Offer> offers) {
  final m = <int, List<Offer>>{};
  for (final o in offers) {
    m.putIfAbsent(o.chain.id, () => []).add(o);
  }
  return [for (final l in m.values) ChainOffer(l..sort((a, b) => a.effective.compareTo(b.effective)))]
    ..sort((a, b) => a.best.effective.compareTo(b.best.effective));
}

class Store {
  final int id, chainId;
  final int? formatId;
  final String name, address, city;
  final double lat, lon;
  Store(this.id, this.chainId, this.formatId, this.name, this.address, this.city, this.lat, this.lon);
}

/// „1 lanac“, „3 lanca“, „5 lanaca“, „21 lanac“ – srpska množina
String plural(int n, String one, String few, String many) {
  final d10 = n % 10, d100 = n % 100;
  if (d10 == 1 && d100 != 11) return '$n $one';
  if (d10 >= 2 && d10 <= 4 && (d100 < 12 || d100 > 14)) return '$n $few';
  return '$n $many';
}
