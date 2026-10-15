import 'dart:convert';

import 'package:http/http.dart' as http;

class OpenRouterError implements Exception {
  final int? status;
  final String message;
  OpenRouterError(this.status, this.message);

  bool get rateLimited => status == 429;

  @override
  String toString() {
    switch (status) {
      case 401:
        return 'OpenRouter: neispravan API ključ (401).';
      case 402:
        return 'OpenRouter: nema kredita za ovaj model (402) – izaberi free model.';
      case 429:
        return 'OpenRouter: dostignut limit besplatnih modela (429). Probaj malo kasnije ili koristi klasičnu pretragu.';
      default:
        return 'OpenRouter greška${status == null ? '' : ' $status'}: $message';
    }
  }
}

class FreeModel {
  final String id, name;
  final int context;
  FreeModel(this.id, this.name, this.context);
}

class OpenRouter {
  static const base = 'https://openrouter.ai/api/v1';
  final String apiKey;
  final http.Client _c;
  OpenRouter(this.apiKey, {http.Client? client}) : _c = client ?? http.Client();

  /// Jedan poziv chat/completions (OpenAI format, sa alatima). Vraća choices[0].message.
  Future<Map<String, dynamic>> chat(String model, List<Map<String, dynamic>> messages,
      {List<Map<String, dynamic>>? tools}) async {
    final r = await _c
        .post(Uri.parse('$base/chat/completions'),
            headers: {
              'Authorization': 'Bearer $apiKey',
              'Content-Type': 'application/json',
              'X-Title': 'Cene',
            },
            body: jsonEncode({
              'model': model,
              'messages': messages,
              'tools': ?tools,
              if (tools != null) 'tool_choice': 'auto',
            }))
        .timeout(const Duration(seconds: 90));
    final body = utf8.decode(r.bodyBytes);
    Map<String, dynamic>? j;
    try {
      j = jsonDecode(body) as Map<String, dynamic>;
    } on FormatException {
      throw OpenRouterError(r.statusCode, body.length > 200 ? body.substring(0, 200) : body);
    }
    final err = j['error'];
    if (r.statusCode != 200 || err != null) {
      final msg = err is Map ? (err['message'] ?? err.toString()).toString() : body;
      final code = err is Map && err['code'] is int ? err['code'] as int : r.statusCode;
      throw OpenRouterError(code, msg);
    }
    final choices = j['choices'] as List?;
    if (choices == null || choices.isEmpty) throw OpenRouterError(r.statusCode, 'prazan odgovor modela');
    return (choices.first as Map<String, dynamic>)['message'] as Map<String, dynamic>;
  }

  /// Besplatni modeli koji podržavaju alate (tool calling) – za padajuću listu u podešavanjima.
  static Future<List<FreeModel>> freeToolModels({http.Client? client}) async {
    final c = client ?? http.Client();
    try {
      final r = await c.get(Uri.parse('$base/models')).timeout(const Duration(seconds: 20));
      if (r.statusCode != 200) throw OpenRouterError(r.statusCode, 'lista modela');
      final data = (jsonDecode(utf8.decode(r.bodyBytes)) as Map)['data'] as List;
      final out = <FreeModel>[];
      for (final m in data.cast<Map<String, dynamic>>()) {
        final pr = m['pricing'] as Map? ?? {};
        final params = (m['supported_parameters'] as List?)?.cast<String>() ?? const [];
        if (pr['prompt'] == '0' && pr['completion'] == '0' && params.contains('tools')) {
          out.add(FreeModel(m['id'] as String, (m['name'] ?? m['id']) as String,
              (m['context_length'] as num?)?.toInt() ?? 0));
        }
      }
      out.sort((a, b) => a.name.compareTo(b.name));
      return out;
    } finally {
      if (client == null) c.close();
    }
  }
}
