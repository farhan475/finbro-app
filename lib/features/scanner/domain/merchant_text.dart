/// Merchant text helpers: mapping keys, display clean-up, similarity and a
/// small offline keyword → category suggestion used when no mapping exists.
library;

/// Key stored in `merchant_mappings.raw_merchant`: lower-cased,
/// whitespace-collapsed, trimmed.
String merchantKey(String raw) => raw.toLowerCase().replaceAll(RegExp(r'\s+'), ' ').trim();

/// Key without punctuation, for fuzzy "same merchant" comparisons.
String merchantCompareKey(String raw) =>
    merchantKey(raw.replaceAll(RegExp(r'[^A-Za-z0-9 ]'), ' '));

/// True when one merchant text contains the other (both ≥ 3 chars), e.g.
/// note "Kopi Kenangan Tebet" vs OCR "KOPI KENANGAN".
bool merchantsSimilar(String? a, String? b) {
  if (a == null || b == null) return false;
  final x = merchantCompareKey(a);
  final y = merchantCompareKey(b);
  if (x.length < 3 || y.length < 3) return false;
  return x.contains(y) || y.contains(x);
}

const _acronyms = {
  'PT', 'CV', 'TBK', 'UD', 'KFC', 'BCA', 'BRI', 'BNI', 'BSI', 'BTN', 'OVO', 'DANA', 'SPBU', 'ATM',
  'RS', 'MCD', 'JCO', 'CFC', 'AW', 'PLN', 'PDAM', 'KRL', 'MRT', 'LRT', 'TIX', 'XXI', 'CGV',
};

/// Cleans an OCR merchant line for display: trims decoration characters and
/// title-cases ALL-CAPS text (`KOPI KENANGAN - TEBET` → `Kopi Kenangan - Tebet`).
String prettifyMerchant(String raw) {
  var s = raw
      .replaceAll(RegExp(r'^[\s*=#~_.:\-|]+'), '')
      .replaceAll(RegExp(r'[\s*=#~_.:\-|]+$'), '')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  if (s.isEmpty) return s;
  final hasLower = RegExp(r'[a-z]').hasMatch(s);
  if (hasLower) return s;
  s = s.split(' ').map((w) {
    if (_acronyms.contains(w.replaceAll(RegExp(r'[^A-Z]'), '')) || !RegExp(r'[A-Z]').hasMatch(w)) {
      return w;
    }
    return w[0] + w.substring(1).toLowerCase();
  }).join(' ');
  return s;
}

/// Generic words only; named merchants live in `merchant_seed.dart`, which
/// `MerchantMappingRepository.suggest` consults first.
const _keywordCategories = <String, List<String>>{
  'sys-expense-food': [
    'resto', 'restoran', 'restaurant', 'rumah makan', 'warung', 'warteg', 'cafe', 'kafe', 'coffee',
    'kopi', 'bakso', 'mie', 'ayam', 'sate', 'soto', 'nasi', 'pizza', 'burger', 'sushi', 'bakery',
    'roti', 'food', 'boba', 'teh', 'dimsum', 'padang', 'eatery', 'kitchen', 'dapur', 'catering',
    'martabak', 'seblak',
  ],
  'sys-expense-transport': [
    'spbu', 'parkir', 'parking', 'tol', 'toll', 'taxi', 'taksi', 'kereta', 'bensin',
  ],
  'sys-expense-bills': [
    'listrik', 'air minum', 'pulsa', 'token', 'internet', 'wifi', 'tagihan', 'iuran', 'sewa', 'kos',
    'kost',
  ],
  'sys-expense-shopping': [
    'supermarket', 'hypermarket', 'minimarket', 'mart', 'toko', 'store', 'shop', 'market',
    'swalayan', 'grosir',
  ],
  'sys-expense-health': [
    'apotek', 'apotik', 'pharmacy', 'klinik', 'clinic', 'rumah sakit', 'hospital', 'rs', 'dokter',
    'lab', 'laboratorium', 'optik',
  ],
  'sys-expense-entertainment': [
    'cinema', 'bioskop', 'karaoke', 'game', 'konser', 'tiket', 'ticket',
  ],
  'sys-expense-subscription': ['google play', 'langganan', 'subscription'],
  'sys-expense-personal-care': [
    'salon', 'barber', 'barbershop', 'spa', 'laundry', 'cukur', 'kosmetik',
  ],
  'sys-expense-education': ['kursus', 'course', 'sekolah', 'kampus', 'universitas', 'les ', 'bimbel'],
};

/// Offline keyword guess of a system expense category id for [merchant], or
/// null. Longer keywords win so "kimia farma" beats "farma".
String? keywordCategoryFor(String merchant) {
  final text = ' ${merchantCompareKey(merchant)} ';
  String? bestId;
  var bestLen = 0;
  for (final e in _keywordCategories.entries) {
    for (final k in e.value) {
      final needle = ' ${merchantCompareKey(k)} ';
      final hit = text.contains(needle) ||
          (k.length >= 5 && text.contains(merchantCompareKey(k)));
      if (hit && k.length > bestLen) {
        bestId = e.key;
        bestLen = k.length;
      }
    }
  }
  return bestId;
}
