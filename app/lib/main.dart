import 'package:flutter/material.dart';

import 'app_state.dart';
import 'ui/list_screen.dart';
import 'ui/map_screen.dart';
import 'ui/search_screen.dart';
import 'ui/settings_screen.dart';
import 'ui/setup_screen.dart';
import 'ui/stores_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await app.init();
  runApp(const CeneApp());
}

/// aktivna kartica – ekrani mogu da prebace korisnika (npr. „Izaberi radnje“)
final currentTab = ValueNotifier<int>(0);

class CeneApp extends StatelessWidget {
  const CeneApp({super.key});

  @override
  Widget build(BuildContext context) {
    ThemeData theme(Brightness b) => ThemeData(
          colorSchemeSeed: const Color(0xFF2E7D32),
          brightness: b,
          useMaterial3: true,
        );
    return MaterialApp(
      title: 'Cene',
      debugShowCheckedModeBanner: false,
      theme: theme(Brightness.light),
      darkTheme: theme(Brightness.dark),
      home: ListenableBuilder(
        listenable: app.store,
        builder: (context, _) => app.store.db == null ? const SetupScreen() : const HomeShell(),
      ),
    );
  }
}

class HomeShell extends StatefulWidget {
  const HomeShell({super.key});
  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  @override
  void initState() {
    super.initState();
    // prvo pokretanje: bez izabranih radnji nema poređenja
    if (app.settings.selected.isEmpty) currentTab.value = 3;
    _checkUpdate();
  }

  Future<void> _checkUpdate() async {
    try {
      await app.store.fetchManifest(app.settings.dbUrl);
    } catch (e) {
      // bez interneta aplikacija radi sa postojećom bazom; korisnik vidi razlog
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Provera novih cena nije uspela: $e')));
      }
      return;
    }
    if (app.store.updateAvailable && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: const Text('Dostupne su nove cene.'),
        duration: const Duration(seconds: 10),
        action: SnackBarAction(label: 'Osveži', onPressed: () => app.store.download(app.settings.dbUrl)),
      ));
    }
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<int>(
      valueListenable: currentTab,
      builder: (context, tab, _) => Scaffold(
        body: IndexedStack(index: tab, children: const [
          SearchScreen(),
          ListScreen(),
          MapScreen(),
          StoresScreen(),
          SettingsScreen(),
        ]),
        bottomNavigationBar: NavigationBar(
          selectedIndex: tab,
          onDestinationSelected: (i) => currentTab.value = i,
          destinations: [
            const NavigationDestination(icon: Icon(Icons.search), label: 'Pretraga'),
            NavigationDestination(
              icon: ListenableBuilder(
                listenable: app.list,
                builder: (_, _) => Badge(
                  isLabelVisible: app.list.items.isNotEmpty,
                  label: Text('${app.list.items.length}'),
                  child: const Icon(Icons.checklist),
                ),
              ),
              label: 'Spisak',
            ),
            const NavigationDestination(icon: Icon(Icons.map_outlined), label: 'Mapa'),
            const NavigationDestination(icon: Icon(Icons.storefront_outlined), label: 'Radnje'),
            const NavigationDestination(icon: Icon(Icons.settings_outlined), label: 'Opcije'),
          ],
        ),
      ),
    );
  }
}
