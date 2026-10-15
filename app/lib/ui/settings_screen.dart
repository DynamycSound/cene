import 'package:flutter/material.dart';

import '../agent/openrouter.dart';
import '../app_state.dart';
import '../data/settings.dart';
import 'widgets.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});
  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final _key = TextEditingController();
  final _model = TextEditingController();
  final _dbUrl = TextEditingController();
  bool _showKey = false;
  List<FreeModel>? _models;
  String? _modelsError;
  bool _loadingModels = false;

  @override
  void initState() {
    super.initState();
    _key.text = app.settings.apiKey ?? '';
    _model.text = app.settings.modelId;
    _dbUrl.text = app.settings.dbUrl;
  }

  @override
  void dispose() {
    _key.dispose();
    _model.dispose();
    _dbUrl.dispose();
    super.dispose();
  }

  Future<void> _loadModels() async {
    setState(() {
      _loadingModels = true;
      _modelsError = null;
    });
    try {
      final m = await OpenRouter.freeToolModels();
      setState(() => _models = m);
    } catch (e) {
      setState(() => _modelsError = e.toString());
    } finally {
      if (mounted) setState(() => _loadingModels = false);
    }
  }

  void _snack(String s) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(s)));

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final s = app.settings;
    return Scaffold(
      appBar: AppBar(title: const Text('Podešavanja')),
      body: ListenableBuilder(
        listenable: Listenable.merge([s, app.store]),
        builder: (context, _) => ListView(padding: const EdgeInsets.only(bottom: 32), children: [
          SwitchListTile(
            secondary: const Icon(Icons.auto_awesome),
            title: const Text('AI agent'),
            subtitle: Text(s.apiKey == null
                ? 'Treba OpenRouter API ključ (besplatan nalog na openrouter.ai)'
                : 'Pitaj običnim rečima, npr. „gde je najjeftinije mleko i hleb?“'),
            value: s.aiEnabled,
            onChanged: s.setAi,
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: TextField(
              controller: _key,
              obscureText: !_showKey,
              autocorrect: false,
              enableSuggestions: false,
              decoration: InputDecoration(
                labelText: 'OpenRouter API ključ',
                helperText: 'Čuva se šifrovano samo na ovom telefonu.',
                border: const OutlineInputBorder(),
                suffixIcon: IconButton(
                  icon: Icon(_showKey ? Icons.visibility_off : Icons.visibility),
                  onPressed: () => setState(() => _showKey = !_showKey),
                ),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(mainAxisAlignment: MainAxisAlignment.end, children: [
              TextButton(onPressed: () => openUrl(context, 'https://openrouter.ai/keys'), child: const Text('Napravi ključ')),
              const SizedBox(width: 8),
              FilledButton(
                onPressed: () async {
                  await s.setApiKey(_key.text);
                  if (s.apiKey != null && !s.aiEnabled) await s.setAi(true);
                  _snack(s.apiKey == null ? 'Ključ obrisan' : 'Ključ sačuvan');
                },
                child: const Text('Sačuvaj ključ'),
              ),
            ]),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: TextField(
              controller: _model,
              autocorrect: false,
              decoration: InputDecoration(
                labelText: 'Model ID',
                helperText: 'Podrazumevano $defaultModel (OpenRouter sam bira besplatan model)',
                border: const OutlineInputBorder(),
                suffixIcon: IconButton(icon: const Icon(Icons.check), onPressed: () async {
                  await s.setModel(_model.text);
                  _model.text = s.modelId;
                  _snack('Model: ${s.modelId}');
                }),
              ),
              onSubmitted: (v) async {
                await s.setModel(v);
                _model.text = s.modelId;
              },
            ),
          ),
          ListTile(
            leading: const Icon(Icons.list_alt),
            title: const Text('Izaberi besplatan model'),
            subtitle: Text(_modelsError ?? 'Lista free modela koji podržavaju alate'),
            trailing: _loadingModels ? const CircularProgressIndicator() : const Icon(Icons.chevron_right),
            onTap: _loadingModels
                ? null
                : () async {
                    if (_models == null) await _loadModels();
                    if (!context.mounted || _models == null) return;
                    final picked = await showModalBottomSheet<String>(
                      context: context,
                      isScrollControlled: true,
                      builder: (c) => DraggableScrollableSheet(
                        expand: false,
                        initialChildSize: 0.7,
                        builder: (c, sc) => ListView(controller: sc, children: [
                          ListTile(
                            title: const Text(defaultModel),
                            subtitle: const Text('Automatski izbor besplatnog modela (preporučeno)'),
                            onTap: () => Navigator.pop(c, defaultModel),
                          ),
                          for (final m in _models!)
                            ListTile(
                              title: Text(m.name),
                              subtitle: Text('${m.id} · ${(m.context / 1000).round()}k'),
                              selected: m.id == s.modelId,
                              onTap: () => Navigator.pop(c, m.id),
                            ),
                        ]),
                      ),
                    );
                    if (picked != null) {
                      await s.setModel(picked);
                      _model.text = s.modelId;
                    }
                  },
          ),
          const Divider(),
          _dbSection(context),
          const Divider(),
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text(
              'Izvori: zvanični cenovnici trgovaca po Pravilniku o objavljivanju cenovnika (data.gov.rs), '
              'radnje i mapa © OpenStreetMap saradnici, slike proizvoda Open Food Facts, tehnika sa sajtova '
              'Gigatron i Uspon u trenutku pretrage.',
              style: t.textTheme.bodySmall,
            ),
          ),
        ]),
      ),
    );
  }

  Widget _dbSection(BuildContext context) {
    final st = app.store;
    final db = st.db;
    final t = Theme.of(context);
    final built = DateTime.tryParse(db?.builtAt ?? '')?.toLocal();
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      ListTile(
        leading: const Icon(Icons.storage),
        title: const Text('Baza cena'),
        subtitle: Text([
          if (built != null) 'napravljena ${built.day}.${built.month}.${built.year}. u ${built.hour}:${built.minute.toString().padLeft(2, '0')}',
          if (db != null) '${db.meta['products']} proizvoda, ${db.meta['chains']} lanaca, ${db.meta['stores']} radnji',
          if (st.updateAvailable) 'dostupna novija verzija',
        ].join('\n')),
      ),
      if (st.progress != null)
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: LinearProgressIndicator(value: st.progress == 0 ? null : st.progress),
        )
      else
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: OutlinedButton.icon(
            icon: const Icon(Icons.refresh),
            label: const Text('Osveži cene'),
            onPressed: () async {
              if (await st.download(app.settings.dbUrl)) _snack('Cene su osvežene.');
            },
          ),
        ),
      if (st.error != null)
        Padding(
          padding: const EdgeInsets.all(16),
          child: Text(st.error!, style: TextStyle(color: t.colorScheme.error)),
        ),
      ExpansionTile(
        title: const Text('Napredno'),
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: TextField(
              controller: _dbUrl,
              decoration: const InputDecoration(labelText: 'Adresa baze (cene.sqlite.gz)', border: OutlineInputBorder()),
              onSubmitted: app.settings.setDbUrl,
            ),
          ),
        ],
      ),
    ]);
  }
}
