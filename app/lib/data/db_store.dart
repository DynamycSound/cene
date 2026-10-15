import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import 'db.dart';

const supportedSchema = 2;

/// Drži otvorenu bazu i zna da skine novu sa GitHub Release-a.
class DbStore extends ChangeNotifier {
  PriceDb? db;
  double? progress; // 0..1 dok traje preuzimanje
  String? error;
  String? remoteBuiltAt;

  Future<String> _path() async => p.join(await getDatabasesPath(), 'cene.sqlite');

  Future<void> openExisting() async {
    final path = await _path();
    if (!File(path).existsSync()) return;
    try {
      final d = await PriceDb.open(path);
      if (d.schema != supportedSchema) {
        // baza iz starije verzije aplikacije nema nove kolone – mora nova
        await d.close();
        error = 'Ova verzija aplikacije traži noviju bazu cena. Preuzmi je ponovo.';
        db = null;
      } else {
        db = d;
      }
    } catch (e) {
      error = 'Lokalna baza je oštećena ($e). Preuzmi je ponovo.';
      db = null;
    }
    notifyListeners();
  }

  /// manifest.json je pored baze u istom Release-u
  Future<Map<String, dynamic>?> fetchManifest(String dbUrl) async {
    final url = dbUrl.replaceFirst(RegExp(r'cene\.sqlite\.gz$'), 'manifest.json');
    final r = await http.get(Uri.parse(url)).timeout(const Duration(seconds: 20));
    if (r.statusCode != 200) throw HttpException('manifest: HTTP ${r.statusCode}', uri: Uri.parse(url));
    final m = jsonDecode(utf8.decode(r.bodyBytes)) as Map<String, dynamic>;
    remoteBuiltAt = m['built_at'] as String?;
    notifyListeners();
    return m;
  }

  bool get updateAvailable =>
      db != null && remoteBuiltAt != null && remoteBuiltAt!.compareTo(db!.builtAt) > 0;

  /// Vrati true ako je nova baza preuzeta; inače je razlog u [error] (prikazuje se korisniku).
  Future<bool> download(String dbUrl) async {
    progress = 0;
    error = null;
    notifyListeners();
    final dir = await getDatabasesPath();
    await Directory(dir).create(recursive: true);
    final gz = File(p.join(dir, 'cene.download.gz'));
    final tmp = File(p.join(dir, 'cene.new.sqlite'));
    final client = http.Client();
    try {
      final resp = await client.send(http.Request('GET', Uri.parse(dbUrl)));
      if (resp.statusCode != 200) {
        throw HttpException('HTTP ${resp.statusCode}', uri: Uri.parse(dbUrl));
      }
      final total = resp.contentLength ?? 0;
      var got = 0;
      final sink = gz.openWrite();
      await for (final chunk in resp.stream) {
        sink.add(chunk);
        got += chunk.length;
        if (total > 0 && got / total - progress! >= 0.01) {
          progress = got / total;
          notifyListeners();
        }
      }
      await sink.close();
      await gz.openRead().transform(gzip.decoder).pipe(tmp.openWrite());

      // proveri novu bazu pre nego što zameni staru
      final check = await PriceDb.open(tmp.path);
      final schema = check.schema;
      final n = check.chains.length;
      await check.close();
      if (schema != supportedSchema || n == 0) {
        throw StateError('Baza ima šemu $schema (aplikacija podržava $supportedSchema). Ažuriraj aplikaciju.');
      }
      // db ostaje postavljen do kraja (bez notifyListeners između), da UI ne skoči na ekran za preuzimanje
      await db?.close();
      final path = await _path();
      await deleteDatabase(path); // zatvara i briše staru (sqflite drži keš otvorenih baza)
      await tmp.rename(path);
      db = await PriceDb.open(path);
      return true;
    } catch (e) {
      error = 'Preuzimanje baze nije uspelo: $e';
      return false;
    } finally {
      client.close();
      progress = null;
      if (gz.existsSync()) gz.deleteSync();
      if (tmp.existsSync()) tmp.deleteSync();
      notifyListeners();
    }
  }
}
