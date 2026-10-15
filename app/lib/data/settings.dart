import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'db.dart';

const defaultModel = 'openrouter/free';
const defaultDbUrl = 'https://github.com/DynamycSound/cene/releases/download/db/cene.sqlite.gz';

/// Podešavanja korisnika. Izbor radnji se čuva po lancu ("maxi|"), ne po id-u,
/// jer se id-evi menjaju pri svakom novom buildu baze. Svi cenovnici lanca (Maxi, Mega Maxi, Shop&Go…) idu zajedno.
class AppSettings extends ChangeNotifier {
  final _secure = const FlutterSecureStorage();
  late SharedPreferences _p;

  Set<String> selected = {};
  bool aiEnabled = false;
  String modelId = defaultModel;
  String? apiKey;
  double radiusKm = 0; // 0 = cela Srbija
  String dbUrl = defaultDbUrl;

  Future<void> load() async {
    _p = await SharedPreferences.getInstance();
    // ranije se biralo po formatu („maxi|Mega Maxi“) – svodi se na lanac
    selected = {for (final k in _p.getStringList('selected') ?? <String>[]) key(k.split('|').first)};
    aiEnabled = _p.getBool('ai') ?? false;
    modelId = _p.getString('model') ?? defaultModel;
    radiusKm = _p.getDouble('radius') ?? 0;
    dbUrl = _p.getString('db_url') ?? defaultDbUrl;
    apiKey = await _secure.read(key: 'openrouter_key');
  }

  bool get aiReady => aiEnabled && (apiKey?.isNotEmpty ?? false);

  static String key(String slug) => '$slug|';

  bool isSelected(String slug) => selected.contains(key(slug));

  Future<void> setSelected(Iterable<String> keys, bool on) async {
    if (on) {
      selected.addAll(keys);
    } else {
      selected.removeAll(keys);
    }
    await _p.setStringList('selected', selected.toList());
    notifyListeners();
  }

  /// id-evi svih cenovnika izabranih lanaca u trenutnoj bazi
  Set<int> selectedFormatIds(PriceDb db) => {
        for (final f in db.formats.values)
          if (isSelected(db.chains[f.chainId]!.slug)) f.id,
      };

  /// izabrani lanci (i web prodavnice)
  Set<int> selectedChainIds(PriceDb db) => {
        for (final c in db.chains.values)
          if (isSelected(c.slug)) c.id,
      };

  Future<void> setAi(bool v) async {
    aiEnabled = v;
    await _p.setBool('ai', v);
    notifyListeners();
  }

  Future<void> setModel(String v) async {
    modelId = v.trim().isEmpty ? defaultModel : v.trim();
    await _p.setString('model', modelId);
    notifyListeners();
  }

  Future<void> setApiKey(String? v) async {
    apiKey = (v == null || v.trim().isEmpty) ? null : v.trim();
    if (apiKey == null) {
      await _secure.delete(key: 'openrouter_key');
    } else {
      await _secure.write(key: 'openrouter_key', value: apiKey);
    }
    notifyListeners();
  }

  Future<void> setRadius(double v) async {
    radiusKm = v;
    await _p.setDouble('radius', v);
    notifyListeners();
  }

  Future<void> setDbUrl(String v) async {
    dbUrl = v.trim().isEmpty ? defaultDbUrl : v.trim();
    await _p.setString('db_url', dbUrl);
    notifyListeners();
  }
}
