import 'package:flutter/material.dart';

import '../agent/agent.dart';
import '../agent/openrouter.dart';
import '../app_state.dart';
import '../data/models.dart';
import 'product_screen.dart';
import 'web_product_screen.dart';
import 'widgets.dart';

class _Msg {
  final bool user;
  final String text;
  final List<ProductHit> products;
  final AgentReply? reply;
  final bool error;
  _Msg(this.user, this.text, {this.products = const [], this.reply, this.error = false});
}

/// AI agent: pitanje običnim rečima, odgovor sa karticama proizvoda (cene iz lokalne baze).
class AgentView extends StatefulWidget {
  const AgentView({super.key});
  @override
  State<AgentView> createState() => _AgentViewState();
}

class _AgentViewState extends State<AgentView> {
  final _input = TextEditingController();
  final _scroll = ScrollController();
  final _msgs = <_Msg>[];
  Agent? _agent;
  String? _agentKey;
  bool _busy = false;

  Agent _get() {
    final s = app.settings;
    final key = '${s.apiKey}|${s.modelId}|${app.store.db.hashCode}';
    if (_agent == null || _agentKey != key) {
      _agent = Agent(app.store.db!, s, OpenRouter(s.apiKey!));
      _agentKey = key;
    }
    return _agent!;
  }

  Future<void> _send() async {
    final text = _input.text.trim();
    if (text.isEmpty || _busy) return;
    _input.clear();
    setState(() {
      _msgs.add(_Msg(true, text));
      _busy = true;
    });
    _toEnd();
    try {
      final r = await _get().ask(text);
      final db = app.store.db!;
      final sel = app.settings.selectedFormatIds(db);
      final products = <ProductHit>[];
      for (final id in r.productIds.take(8)) {
        final p = await db.product(id, sel);
        if (p != null) products.add(p);
      }
      setState(() => _msgs.add(_Msg(false, r.text.isEmpty ? '(model nije vratio tekst)' : r.text, products: products, reply: r)));
    } on OpenRouterError catch (e) {
      setState(() => _msgs.add(_Msg(false, e.toString(), error: true)));
    } catch (e) {
      setState(() => _msgs.add(_Msg(false, 'Greška: $e', error: true)));
    } finally {
      if (mounted) setState(() => _busy = false);
      _toEnd();
    }
  }

  void _toEnd() => WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scroll.hasClients) {
          _scroll.animateTo(_scroll.position.maxScrollExtent,
              duration: const Duration(milliseconds: 250), curve: Curves.easeOut);
        }
      });

  @override
  void dispose() {
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Column(children: [
      Expanded(
        child: _msgs.isEmpty
            ? EmptyHint(Icons.auto_awesome,
                'Pitaj, npr: „Treba mi mleko, hleb i jaja – gde je najjeftinije?“ ili „najjeftiniji airfryer“.\n\n'
                'Model: ${app.settings.modelId}')
            : ListView.builder(
                controller: _scroll,
                padding: const EdgeInsets.symmetric(vertical: 8),
                itemCount: _msgs.length,
                itemBuilder: (context, i) => _bubble(context, _msgs[i]),
              ),
      ),
      if (_busy) const LinearProgressIndicator(),
      SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
          child: Row(children: [
            Expanded(
              child: TextField(
                controller: _input,
                minLines: 1,
                maxLines: 4,
                textInputAction: TextInputAction.send,
                onSubmitted: (_) => _send(),
                decoration: const InputDecoration(hintText: 'Šta kupuješ?', border: OutlineInputBorder()),
              ),
            ),
            const SizedBox(width: 8),
            IconButton.filled(onPressed: _busy ? null : _send, icon: const Icon(Icons.send)),
          ]),
        ),
      ),
      if (_msgs.isNotEmpty)
        TextButton(
          onPressed: _busy ? null : () => setState(() {
            _msgs.clear();
            _agent = null;
          }),
          child: Text('Nov razgovor', style: t.textTheme.bodySmall),
        ),
    ]);
  }

  Widget _bubble(BuildContext context, _Msg m) {
    final t = Theme.of(context);
    final db = app.store.db!;
    final r = m.reply;
    return Align(
      alignment: m.user ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * (m.user ? 0.8 : 0.95)),
        decoration: BoxDecoration(
          color: m.user
              ? t.colorScheme.primaryContainer
              : (m.error ? t.colorScheme.errorContainer : t.colorScheme.surfaceContainerHigh),
          borderRadius: BorderRadius.circular(16),
        ),
        padding: const EdgeInsets.all(12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          SelectableText(m.text),
          if (r != null && r.toolLog.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text('alati: ${r.toolLog.join(' → ')}', style: t.textTheme.labelSmall?.copyWith(color: t.colorScheme.outline)),
            ),
          if (m.products.isNotEmpty) ...[
            const SizedBox(height: 8),
            Card(
              margin: EdgeInsets.zero,
              child: Column(children: [
                for (final p in m.products)
                  ProductTile(p,
                      onTap: () => Navigator.push(
                          context, MaterialPageRoute(builder: (_) => ProductScreen(productId: p.id)))),
              ]),
            ),
          ],
          if (r != null && r.web.isNotEmpty) ...[
            const SizedBox(height: 8),
            Card(
              margin: EdgeInsets.zero,
              child: Column(children: [
                for (final w in r.web.take(6))
                  WebProductTile(w,
                      chain: db.chainBySlug(w.shop),
                      shopName: db.chainBySlug(w.shop)?.name ?? w.shop,
                      onTap: () => Navigator.push(
                          context, MaterialPageRoute(builder: (_) => WebProductScreen(product: w)))),
              ]),
            ),
          ],
        ]),
      ),
    );
  }
}
