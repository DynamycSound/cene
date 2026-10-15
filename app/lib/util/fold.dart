// Ista normalizacija kao u pipeline/cene/text.py: mala slova, ćirilica -> latinica, bez dijakritika.

const _map = {
  'а': 'a', 'б': 'b', 'в': 'v', 'г': 'g', 'д': 'd', 'ђ': 'dj', 'е': 'e', 'ж': 'z', 'з': 'z',
  'и': 'i', 'ј': 'j', 'к': 'k', 'л': 'l', 'љ': 'lj', 'м': 'm', 'н': 'n', 'њ': 'nj', 'о': 'o',
  'п': 'p', 'р': 'r', 'с': 's', 'т': 't', 'ћ': 'c', 'у': 'u', 'ф': 'f', 'х': 'h', 'ц': 'c',
  'ч': 'c', 'џ': 'dz', 'ш': 's',
  'đ': 'dj', 'ð': 'dj', 'č': 'c', 'ć': 'c', 'š': 's', 'ž': 'z',
  'á': 'a', 'à': 'a', 'â': 'a', 'ä': 'a', 'ã': 'a', 'å': 'a', 'é': 'e', 'è': 'e', 'ê': 'e',
  'ë': 'e', 'í': 'i', 'ì': 'i', 'î': 'i', 'ï': 'i', 'ó': 'o', 'ò': 'o', 'ô': 'o', 'ö': 'o',
  'õ': 'o', 'ő': 'o', 'ú': 'u', 'ù': 'u', 'û': 'u', 'ü': 'u', 'ű': 'u', 'ý': 'y', 'ñ': 'n',
  'ç': 'c', 'ł': 'l', 'ř': 'r', 'ě': 'e', 'ů': 'u', 'ţ': 't', 'ș': 's', 'ş': 's', 'ț': 't',
};

String fold(String s) {
  final b = StringBuffer();
  for (final ch in s.toLowerCase().split('')) {
    b.write(_map[ch] ?? ch);
  }
  return b.toString();
}

final _word = RegExp(r'[a-z0-9]+(?:[.,][0-9]+)?');

/// Reči upita za LIKE pretragu. Duže reči gube poslednje slovo da bi „mleka“ našlo „mleko“.
/// Cele reči upita (bez skraćivanja) – za rangiranje: „milka“ ispred „milk shake“.
List<String> queryWords(String query) =>
    {for (final m in _word.allMatches(fold(query))) m.group(0)!}.toList();

List<String> searchTokens(String query) {
  final out = <String>[];
  for (final m in _word.allMatches(fold(query))) {
    var t = m.group(0)!;
    if (t.length >= 5 && RegExp(r'[a-z]$').hasMatch(t)) t = t.substring(0, t.length - 1);
    if (!out.contains(t)) out.add(t);
  }
  return out;
}
