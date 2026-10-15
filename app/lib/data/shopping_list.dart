import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'models.dart';

/// Stavka spiska se pamti po EAN-u i nazivu (id proizvoda se menja sa svakom bazom).
class ListItem {
  final String ean;
  String name; // prikazni naziv; osvežava se iz nove baze (čišći nazivi)
  int qty;
  ListItem(this.ean, this.name, [this.qty = 1]);
  Map<String, dynamic> toJson() => {'ean': ean, 'name': name, 'qty': qty};
  factory ListItem.fromJson(Map<String, dynamic> j) =>
      ListItem(j['ean'] as String, j['name'] as String, (j['qty'] ?? 1) as int);
}

class ShoppingList extends ChangeNotifier {
  late SharedPreferences _p;
  final List<ListItem> items = [];

  Future<void> load() async {
    _p = await SharedPreferences.getInstance();
    final raw = _p.getString('list');
    if (raw != null) {
      items.addAll((jsonDecode(raw) as List).map((e) => ListItem.fromJson(e as Map<String, dynamic>)));
    }
  }

  Future<void> _save() async {
    await _p.setString('list', jsonEncode(items.map((e) => e.toJson()).toList()));
    notifyListeners();
  }

  bool contains(String ean) => items.any((i) => i.ean == ean);

  Future<void> add(String ean, String name) async {
    final ex = items.where((i) => i.ean == ean);
    if (ex.isNotEmpty) {
      ex.first.qty++;
    } else {
      items.add(ListItem(ean, name));
    }
    await _save();
  }

  /// nazivi iz trenutne baze; čuva se samo ako se nešto promenilo
  Future<void> rename(Map<ListItem, String> names) async {
    var changed = false;
    for (final e in names.entries) {
      if (items.contains(e.key) && e.key.name != e.value) {
        e.key.name = e.value;
        changed = true;
      }
    }
    if (changed) await _save();
  }

  Future<void> setQty(ListItem it, int qty) async {
    if (qty <= 0) {
      items.remove(it);
    } else {
      it.qty = qty;
    }
    await _save();
  }

  Future<void> clear() async {
    items.clear();
    await _save();
  }
}

/// Ukupno za ceo spisak u jednom lancu (u njegovom najpovoljnijem cenovniku).
class StoreTotal {
  final Chain chain;
  final int formatId;
  /// cenovnik lanca po kome je računato („Shop and Go“), null kad lanac ima samo jedan
  final String? formatName;
  final double total;
  final List<String> missing; // nazivi stavki kojih nema u tom lancu
  StoreTotal(this.chain, this.formatId, this.formatName, this.total, this.missing);

  String get label => chain.name;
}

class SplitLine {
  final String item;
  final int qty;
  final Offer offer;
  SplitLine(this.item, this.qty, this.offer);
}

class BasketResult {
  final List<StoreTotal> stores; // sve izabrane radnje, prvo one koje imaju najviše stavki, pa najjeftinije
  final List<SplitLine> split; // najjeftinije po stavci
  final double splitTotal;
  final List<String> nowhere; // stavke kojih nema ni u jednoj izabranoj radnji
  BasketResult(this.stores, this.split, this.splitTotal, this.nowhere);

  StoreTotal? get bestSingle => stores.isEmpty ? null : stores.first;
}

/// [offers] su ponude po stavci, već filtrirane na izabrane radnje.
/// Jedna fizička radnja ima jedan cenovnik, pa se zbir računa po cenovniku, a za svaki lanac
/// ostaje njegov najpovoljniji (najviše stavki, pa najniži zbir).
BasketResult planBasket(List<ListItem> items, Map<ListItem, List<Offer>> offers) {
  final totals = <int, double>{};
  final have = <int, Set<ListItem>>{};
  final sample = <int, Offer>{};
  final split = <SplitLine>[];
  final nowhere = <String>[];
  for (final it in items) {
    final os = offers[it] ?? const [];
    if (os.isEmpty) {
      nowhere.add(it.name);
      continue;
    }
    // ista stavka u istoj radnji može imati više proizvoda (npr. interne šifre) – uzmi najjeftiniji
    final perFormat = <int, Offer>{};
    for (final o in os) {
      final old = perFormat[o.formatId];
      if (old == null || o.effective < old.effective) perFormat[o.formatId] = o;
    }
    for (final o in perFormat.values) {
      totals[o.formatId] = (totals[o.formatId] ?? 0) + o.effective * it.qty;
      have.putIfAbsent(o.formatId, () => {}).add(it);
      sample[o.formatId] = o;
    }
    final best = perFormat.values.reduce((a, b) => a.effective <= b.effective ? a : b);
    split.add(SplitLine(it.name, it.qty, best));
  }
  int order(StoreTotal a, StoreTotal b) {
    final m = a.missing.length.compareTo(b.missing.length);
    return m != 0 ? m : a.total.compareTo(b.total);
  }

  final bestOfChain = <int, StoreTotal>{};
  for (final fid in totals.keys) {
    final o = sample[fid]!;
    final t = StoreTotal(o.chain, fid, o.formatName, totals[fid]!,
        [for (final it in items) if (!have[fid]!.contains(it)) it.name]);
    final old = bestOfChain[o.chain.id];
    if (old == null || order(t, old) < 0) bestOfChain[o.chain.id] = t;
  }
  final stores = bestOfChain.values.toList()..sort(order);
  final splitTotal = split.fold<double>(0, (s, l) => s + l.offer.effective * l.qty);
  return BasketResult(stores, split, splitTotal, nowhere);
}
