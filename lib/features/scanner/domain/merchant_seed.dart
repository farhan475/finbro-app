/// Built-in dictionary of common Indonesian merchants → seeded expense
/// category ids. Used by `MerchantMappingRepository.suggest` only when the
/// user has no learned mapping; it is never written to the database.
library;

import 'text_normalizer.dart';

/// A well-known merchant and the system expense category it usually is.
class SeedMerchant {
  const SeedMerchant(this.name, this.categoryId, this.aliases);

  /// Display name, e.g. `Indomaret`.
  final String name;

  /// Seeded category id (`lib/core/database/seed.dart`).
  final String categoryId;

  /// Spellings matched against the text. Each alias matches only on token
  /// boundaries (see [seedMerchantFor]); spaces inside an alias are optional
  /// in the text (`super indo` = `superindo`).
  final List<String> aliases;
}

const _food = 'sys-expense-food';
const _transport = 'sys-expense-transport';
const _bills = 'sys-expense-bills';
const _shopping = 'sys-expense-shopping';
const _entertainment = 'sys-expense-entertainment';
const _health = 'sys-expense-health';
const _education = 'sys-expense-education';
const _personalCare = 'sys-expense-personal-care';
const _subscription = 'sys-expense-subscription';

/// Travel (airlines, booking apps) has no own category: mapped to Transport.
/// Minimarkets/supermarkets are Shopping, as in the keyword guess.
const seedMerchants = <SeedMerchant>[
  // Minimarkets.
  SeedMerchant('Indomaret', _shopping, ['indomaret', 'indomarco']),
  SeedMerchant('Alfamart', _shopping, ['alfamart', 'sumber alfaria', 'alfaria', 'alfa express']),
  SeedMerchant('Alfamidi', _shopping, ['alfamidi', 'midi utama']),
  SeedMerchant('Lawson', _shopping, ['lawson']),
  SeedMerchant('FamilyMart', _shopping, ['family mart']),
  SeedMerchant('Circle K', _shopping, ['circle k']),
  // Supermarkets.
  SeedMerchant('Superindo', _shopping, ['superindo']),
  SeedMerchant('Hypermart', _shopping, ['hypermart', 'matahari putra prima']),
  SeedMerchant('Transmart', _shopping, ['transmart', 'carrefour', 'trans retail']),
  SeedMerchant('Lotte Mart', _shopping, ['lotte mart', 'lotte grosir', 'lotte']),
  SeedMerchant('Ranch Market', _shopping, ['ranch market', 'ranch 99']),
  SeedMerchant('Farmers Market', _shopping, ['farmers market']),
  SeedMerchant('Hero', _shopping, ['hero supermarket', 'hero']),
  SeedMerchant('Giant', _shopping, ['giant']),
  SeedMerchant('Foodhall', _shopping, ['foodhall']),
  SeedMerchant('Grand Lucky', _shopping, ['grand lucky']),
  SeedMerchant('Tip Top', _shopping, ['tip top']),
  // Food delivery.
  SeedMerchant('GoFood', _food, ['gofood']),
  SeedMerchant('GrabFood', _food, ['grabfood']),
  SeedMerchant('ShopeeFood', _food, ['shopeefood']),
  // Ride hailing / taxi.
  SeedMerchant('Gojek', _transport, ['gojek', 'goride', 'gocar', 'gosend', 'gobluebird']),
  SeedMerchant('Grab', _transport, ['grab', 'grabcar', 'grabbike', 'grabexpress', 'grabtaxi']),
  SeedMerchant('Maxim', _transport, ['maxim']),
  SeedMerchant('inDrive', _transport, ['indrive', 'indriver']),
  SeedMerchant('Bluebird', _transport, ['bluebird', 'mybluebird']),
  // Coffee & F&B chains.
  SeedMerchant('Starbucks', _food, ['starbucks']),
  SeedMerchant('Kopi Kenangan', _food, ['kopi kenangan', 'kenangan signature', 'kenangan heritage']),
  SeedMerchant('Janji Jiwa', _food, ['janji jiwa', 'jiwa toast']),
  SeedMerchant('Fore Coffee', _food, ['fore coffee', 'fore']),
  SeedMerchant('Point Coffee', _food, ['point coffee']),
  SeedMerchant('Tomoro Coffee', _food, ['tomoro']),
  SeedMerchant('Kopi Kulo', _food, ['kopi kulo']),
  SeedMerchant('Kopi Soe', _food, ['kopi soe']),
  SeedMerchant('Flash Coffee', _food, ['flash coffee']),
  SeedMerchant('Excelso', _food, ['excelso']),
  SeedMerchant("McDonald's", _food, ['mcdonalds', 'mcdonald', 'mcd']),
  SeedMerchant('KFC', _food, ['kfc', 'fast food indonesia']),
  SeedMerchant('Burger King', _food, ['burger king']),
  SeedMerchant('Pizza Hut', _food, ['pizza hut', 'phd', 'sarimelati']),
  SeedMerchant("Domino's Pizza", _food, ['dominos']),
  SeedMerchant('HokBen', _food, ['hokben', 'hoka hoka bento']),
  SeedMerchant('Solaria', _food, ['solaria']),
  SeedMerchant('Richeese Factory', _food, ['richeese']),
  SeedMerchant('Mixue', _food, ['mixue']),
  SeedMerchant('Chatime', _food, ['chatime']),
  SeedMerchant('Gong Cha', _food, ['gong cha']),
  SeedMerchant('J.CO', _food, ['jco']),
  SeedMerchant('A&W', _food, ['a&w']),
  SeedMerchant('CFC', _food, ['cfc']),
  SeedMerchant('Mie Gacoan', _food, ['mie gacoan', 'gacoan']),
  SeedMerchant('Bakmi GM', _food, ['bakmi gm']),
  SeedMerchant('Yoshinoya', _food, ['yoshinoya']),
  SeedMerchant('Marugame Udon', _food, ['marugame']),
  SeedMerchant('Sushi Tei', _food, ['sushi tei']),
  SeedMerchant('Wingstop', _food, ['wingstop']),
  SeedMerchant('Es Teh Indonesia', _food, ['es teh indonesia']),
  SeedMerchant('Dunkin', _food, ['dunkin']),
  SeedMerchant('BreadTalk', _food, ['breadtalk']),
  SeedMerchant('Holland Bakery', _food, ['holland bakery']),
  SeedMerchant('Roti O', _food, ['roti o']),
  // Fuel.
  SeedMerchant('Pertamina', _transport, ['pertamina', 'mypertamina', 'pertamax', 'pertalite']),
  SeedMerchant('Shell', _transport, ['shell']),
  SeedMerchant('BP', _transport, ['bp', 'bp akr', 'aneka petroindo']),
  SeedMerchant('Vivo', _transport, ['vivo energy', 'spbu vivo']),
  // Utilities & telco.
  SeedMerchant('PLN', _bills, ['pln']),
  SeedMerchant('PDAM', _bills, ['pdam', 'palyja', 'aetra']),
  SeedMerchant('Telkomsel', _bills, ['telkomsel', 'tsel', 'simpati', 'byu']),
  SeedMerchant('Indosat', _bills, ['indosat', 'im3', 'ooredoo', 'indosat ooredoo hutchison']),
  SeedMerchant('XL', _bills, ['xl', 'xl axiata']),
  SeedMerchant('Axis', _bills, ['axis']),
  // "Tri" alone is too common in names (Tri Jaya, Trijaya); require context.
  SeedMerchant('Tri', _bills, ['tri indonesia', 'kartu tri', 'pulsa tri', 'paket tri', 'hutchison']),
  SeedMerchant('Smartfren', _bills, ['smartfren']),
  SeedMerchant('IndiHome', _bills, ['indihome', 'telkom indonesia', 'telkom']),
  SeedMerchant('Biznet', _bills, ['biznet']),
  SeedMerchant('First Media', _bills, ['first media']),
  SeedMerchant('MyRepublic', _bills, ['myrepublic']),
  SeedMerchant('ICONNET', _bills, ['iconnet', 'iconplus']),
  // E-commerce.
  SeedMerchant('Shopee', _shopping, ['shopee']),
  SeedMerchant('Tokopedia', _shopping, ['tokopedia', 'tokped']),
  SeedMerchant('Lazada', _shopping, ['lazada']),
  SeedMerchant('Blibli', _shopping, ['blibli']),
  SeedMerchant('Bukalapak', _shopping, ['bukalapak']),
  SeedMerchant('TikTok Shop', _shopping, ['tiktok shop']),
  SeedMerchant('Zalora', _shopping, ['zalora']),
  // Travel & public transport.
  SeedMerchant('Traveloka', _transport, ['traveloka']),
  SeedMerchant('tiket.com', _transport, ['tiket com']),
  SeedMerchant('KAI', _transport, ['kai', 'kereta api indonesia', 'access by kai']),
  SeedMerchant('Garuda Indonesia', _transport, ['garuda indonesia']),
  SeedMerchant('Citilink', _transport, ['citilink']),
  SeedMerchant('Lion Air', _transport, ['lion air', 'batik air', 'wings air']),
  SeedMerchant('AirAsia', _transport, ['air asia']),
  SeedMerchant('Super Air Jet', _transport, ['super air jet']),
  SeedMerchant('Transjakarta', _transport, ['transjakarta']),
  SeedMerchant('MRT Jakarta', _transport, ['mrt']),
  SeedMerchant('LRT', _transport, ['lrt']),
  SeedMerchant('KRL Commuter Line', _transport, ['krl', 'commuter line', 'kci', 'kai commuter']),
  SeedMerchant('Whoosh', _transport, ['whoosh', 'kcic', 'kereta cepat']),
  SeedMerchant('Jasa Marga', _transport, ['jasa marga']),
  SeedMerchant('DAMRI', _transport, ['damri']),
  // Health.
  SeedMerchant('BPJS Kesehatan', _health, ['bpjs', 'bpjs kesehatan']),
  SeedMerchant('BPJS Ketenagakerjaan', _bills, ['bpjs ketenagakerjaan', 'bpjs tk', 'bpjamsostek']),
  SeedMerchant('Kimia Farma', _health, ['kimia farma']),
  SeedMerchant('Century', _health, ['century']),
  SeedMerchant('K24', _health, ['k24']),
  SeedMerchant('Guardian', _health, ['guardian']),
  SeedMerchant('Watsons', _health, ['watsons', 'watson']),
  SeedMerchant('Halodoc', _health, ['halodoc']),
  SeedMerchant('Alodokter', _health, ['alodokter']),
  SeedMerchant('Siloam', _health, ['siloam']),
  SeedMerchant('Mitra Keluarga', _health, ['mitra keluarga']),
  // Subscriptions.
  SeedMerchant('Netflix', _subscription, ['netflix']),
  SeedMerchant('Spotify', _subscription, ['spotify']),
  SeedMerchant('YouTube Premium', _subscription, ['youtube premium', 'youtube']),
  SeedMerchant('Disney+ Hotstar', _subscription, ['disney', 'hotstar']),
  SeedMerchant('Vidio', _subscription, ['vidio']),
  SeedMerchant('iCloud', _subscription, ['icloud', 'apple com bill', 'apple com']),
  SeedMerchant('Google One', _subscription, ['google one', 'google storage']),
  SeedMerchant('Prime Video', _subscription, ['prime video', 'amazon prime']),
  SeedMerchant('ChatGPT', _subscription, ['chatgpt', 'openai']),
  SeedMerchant('Canva', _subscription, ['canva']),
  // Retail.
  SeedMerchant('Matahari', _shopping, ['matahari']),
  SeedMerchant('Uniqlo', _shopping, ['uniqlo']),
  SeedMerchant('H&M', _shopping, ['h&m', 'hennes']),
  SeedMerchant('Zara', _shopping, ['zara']),
  SeedMerchant('Ace Hardware / AZKO', _shopping, ['ace hardware', 'azko']),
  SeedMerchant('Informa', _shopping, ['informa']),
  SeedMerchant('IKEA', _shopping, ['ikea']),
  SeedMerchant('Gramedia', _shopping, ['gramedia']),
  SeedMerchant('Erafone', _shopping, ['erafone', 'erajaya']),
  SeedMerchant('iBox', _shopping, ['ibox']),
  SeedMerchant('Digimap', _shopping, ['digimap']),
  SeedMerchant('Miniso', _shopping, ['miniso']),
  SeedMerchant('Mr. DIY', _shopping, ['mr diy']),
  SeedMerchant('Sociolla', _personalCare, ['sociolla']),
  // Entertainment.
  SeedMerchant('CGV', _entertainment, ['cgv']),
  SeedMerchant('Cinema XXI', _entertainment, ['xxi', 'cinema xxi', 'cinema 21', 'mtix']),
  SeedMerchant('Cinépolis', _entertainment, ['cinepolis']),
  SeedMerchant('Timezone', _entertainment, ['timezone']),
  SeedMerchant('Steam', _entertainment, ['steam', 'steampowered']),
  SeedMerchant('PlayStation', _entertainment, ['playstation', 'psn']),
  // Education.
  SeedMerchant('Udemy', _education, ['udemy']),
  SeedMerchant('Coursera', _education, ['coursera']),
  SeedMerchant('Ruangguru', _education, ['ruangguru']),
  SeedMerchant('Zenius', _education, ['zenius']),
];

/// Aliases at least this long also match as the start of a single glued
/// token (`INDOMARETJL` → `indomaret`).
const _prefixMinLength = 8;

/// Aliases at least this long tolerate one OCR edit (`INDOMARFT`).
const _fuzzyMinLength = 8;

/// Most consecutive text tokens one alias may span.
const _maxWindow = 4;

/// Lower-case ASCII tokens of [text] for seed matching: punctuation splits
/// tokens, `&` reads as `and` (`H&M`), and in tokens mixing letters and
/// digits the usual OCR confusions `0/1/5` read as `o/i/s`.
List<String> seedTokens(String text) {
  final cleaned = text
      .toLowerCase()
      .replaceAll('&', ' and ')
      .replaceAll(RegExp(r'[^a-z0-9]+'), ' ')
      .trim();
  if (cleaned.isEmpty) return const [];
  return [for (final t in cleaned.split(' ')) _readDigitsAsLetters(t)];
}

final _letter = RegExp('[a-z]');
final _digit = RegExp('[0-9]');

String _readDigitsAsLetters(String token) {
  if (!_letter.hasMatch(token) || !_digit.hasMatch(token)) return token;
  return token.replaceAll('0', 'o').replaceAll('1', 'i').replaceAll('5', 's');
}

class _Alias {
  _Alias(this.merchant, String alias) : compact = seedTokens(alias).join();
  final SeedMerchant merchant;
  final String compact;
}

final _aliases = [
  for (final m in seedMerchants)
    for (final a in m.aliases) _Alias(m, a),
];

/// The built-in merchant named in [text] (an OCR merchant line or a bank
/// mutation description), or null.
///
/// An alias matches whole tokens only, with spaces between its words
/// optional (`KOPIKENANGAN`, `J.CO`), so short aliases like `bp`, `xl` or
/// `kai` never match inside other words (`BPJS`, `XLARGE`, `KAIZEN`). Long
/// aliases also match a glued branch suffix and one OCR misread. The longest
/// (most specific) alias wins: `GRAB FOOD` is GrabFood, not Grab.
SeedMerchant? seedMerchantFor(String text) {
  final tokens = seedTokens(text);
  if (tokens.isEmpty) return null;
  SeedMerchant? best;
  var bestScore = 0;
  for (final a in _aliases) {
    final score = _matchScore(tokens, a.compact);
    if (score > bestScore) {
      best = a.merchant;
      bestScore = score;
    }
  }
  return best;
}

/// 0 when [alias] does not occur in [tokens]; otherwise grows with the alias
/// length, exact matches above glued-prefix above one-edit matches.
int _matchScore(List<String> tokens, String alias) {
  if (alias.isEmpty) return 0;
  var best = 0;
  for (var i = 0; i < tokens.length; i++) {
    var joined = '';
    for (var j = i; j < tokens.length && j < i + _maxWindow; j++) {
      joined += tokens[j];
      var score = 0;
      if (joined == alias) {
        score = alias.length * 4;
      } else if (j == i && alias.length >= _prefixMinLength && joined.startsWith(alias)) {
        score = alias.length * 4 - 1;
      } else if (alias.length >= _fuzzyMinLength &&
          (joined.length - alias.length).abs() <= 1 &&
          editDistanceAtMostOne(joined, alias)) {
        score = alias.length * 4 - 3;
      }
      if (score > best) best = score;
      if (joined.length > alias.length + 1) break;
    }
  }
  return best;
}
