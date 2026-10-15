import 'data/db_store.dart';
import 'data/images.dart';
import 'data/settings.dart';
import 'data/shopping_list.dart';

/// Globalno stanje aplikacije (jednostavno – aplikacija ima jednog korisnika i jednu bazu).
class AppState {
  final settings = AppSettings();
  final store = DbStore();
  final list = ShoppingList();

  Future<void> init() async {
    await settings.load();
    await list.load();
    await ProductImages.instance.load();
    await store.openExisting();
  }
}

final app = AppState();
