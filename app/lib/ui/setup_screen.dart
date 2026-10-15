import 'package:flutter/material.dart';

import '../app_state.dart';

/// Prvo pokretanje: preuzimanje baze cena.
class SetupScreen extends StatelessWidget {
  const SetupScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final s = app.store;
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: ListenableBuilder(
            listenable: Listenable.merge([s, app.settings]),
            builder: (context, _) => Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Icon(Icons.local_offer_outlined, size: 72, color: Theme.of(context).colorScheme.primary),
                const SizedBox(height: 16),
                Text('Cene', textAlign: TextAlign.center, style: Theme.of(context).textTheme.headlineMedium),
                const SizedBox(height: 8),
                const Text(
                  'Za poređenje cena aplikacija koristi zvanične cenovnike trgovinskih lanaca '
                  '(data.gov.rs), osvežene svaki dan. Baza se preuzme jednom (~18 MB), '
                  'a pretraga posle radi i bez interneta.',
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 24),
                if (s.progress != null) ...[
                  LinearProgressIndicator(value: s.progress == 0 ? null : s.progress),
                  const SizedBox(height: 8),
                  Text('${((s.progress ?? 0) * 100).round()} %', textAlign: TextAlign.center),
                ] else
                  FilledButton.icon(
                    icon: const Icon(Icons.download),
                    label: const Text('Preuzmi cene'),
                    onPressed: () => s.download(app.settings.dbUrl),
                  ),
                if (s.error != null) ...[
                  const SizedBox(height: 16),
                  Text(s.error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
                  const SizedBox(height: 4),
                  Text('Adresa baze: ${app.settings.dbUrl}', style: Theme.of(context).textTheme.bodySmall),
                ],
                if (s.progress == null) ...[
                  const SizedBox(height: 8),
                  TextButton(onPressed: () => _editUrl(context), child: const Text('Druga adresa baze…')),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _editUrl(BuildContext context) async {
    final v = await showDialog<String>(context: context, builder: (_) => const _UrlDialog());
    if (v != null) await app.settings.setDbUrl(v);
  }
}

/// Dijalog drži svoj kontroler, pa ga uništava tek kad se dijalog zaista ukloni (posle animacije).
class _UrlDialog extends StatefulWidget {
  const _UrlDialog();
  @override
  State<_UrlDialog> createState() => _UrlDialogState();
}

class _UrlDialogState extends State<_UrlDialog> {
  late final _c = TextEditingController(text: app.settings.dbUrl);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: const Text('Adresa baze'),
        content: TextField(
          controller: _c,
          keyboardType: TextInputType.url,
          decoration: const InputDecoration(helperText: 'Prazno = podrazumevana (GitHub Release)'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Otkaži')),
          FilledButton(onPressed: () => Navigator.pop(context, _c.text), child: const Text('Sačuvaj')),
        ],
      );
}
