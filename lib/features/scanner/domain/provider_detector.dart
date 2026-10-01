/// Bank / e-wallet provider detection and provider → account matching.
library;

import '../../../core/database/app_database.dart';
import 'scan_models.dart';

class _Signature {
  const _Signature(this.provider, this.strong, this.weak, {this.caseSensitiveWeak = const []});
  final WalletProvider provider;

  /// App-specific UI phrases (lower-case): strong evidence.
  final List<String> strong;

  /// Brand mentions (lower-case): weak evidence.
  final List<String> weak;

  /// Mentions that only count in this exact casing (`DANA` vs "dana masuk").
  final List<String> caseSensitiveWeak;
}

const _signatures = [
  _Signature(WalletProvider.bca, ['m-transfer', 'm-bca', 'mybca', 'klikbca', 'bca mobile', 'm-payment'], ['bca']),
  _Signature(WalletProvider.gopay, ['gojek', 'saldo gopay', 'gopay saldo', 'gopay coins', 'gopaylater'], ['gopay']),
  _Signature(WalletProvider.ovo, ['ovo cash', 'ovo points', 'saldo ovo', 'ovo balance'], ['ovo']),
  _Signature(WalletProvider.dana, ['saldo dana', 'dana balance', 'dana.id', 'dana protection'], [],
      caseSensitiveWeak: ['DANA']),
  _Signature(WalletProvider.shopeePay, ['shopeepay', 'shopee pay', 'spaylater', 'saldo shopeepay'], ['shopee']),
  _Signature(WalletProvider.seaBank, ['seabank', 'sea bank'], []),
  _Signature(WalletProvider.jago, ['bank jago', 'jago syariah', 'kantong utama', 'kantong'], ['jago']),
  _Signature(WalletProvider.bri, ['brimo'], ['bri']),
  _Signature(WalletProvider.mandiri, ['livin', "livin' by mandiri"], ['mandiri']),
  _Signature(WalletProvider.bni, ['bni mobile', 'wondr'], ['bni']),
  _Signature(WalletProvider.linkAja, ['linkaja', 'link aja'], []),
];

RegExp _word(String k, {bool caseSensitive = false}) => RegExp(
  '(?<![A-Za-z0-9])${RegExp.escape(k)}(?![A-Za-z0-9])',
  caseSensitive: caseSensitive,
);

/// Most likely provider mentioned in [lines]; lines in [excluded] (e.g. the
/// destination "Ke BCA - 123…") are ignored. High confidence needs an
/// app-specific phrase; a bare brand mention is medium.
Extracted<WalletProvider> detectProvider(List<String> lines, {Set<int> excluded = const {}}) {
  final scores = <WalletProvider, int>{};
  final firstSeen = <WalletProvider, int>{};
  final strongHit = <WalletProvider>{};
  for (var i = 0; i < lines.length; i++) {
    if (excluded.contains(i)) continue;
    final line = lines[i];
    for (final s in _signatures) {
      var score = 0;
      for (final k in s.strong) {
        if (_word(k).hasMatch(line)) {
          score += 3;
          strongHit.add(s.provider);
          break;
        }
      }
      if (score == 0) {
        for (final k in s.weak) {
          if (_word(k).hasMatch(line)) score += 1;
        }
        for (final k in s.caseSensitiveWeak) {
          if (_word(k, caseSensitive: true).hasMatch(line)) score += 1;
        }
      }
      if (score > 0) {
        scores[s.provider] = (scores[s.provider] ?? 0) + score;
        firstSeen.putIfAbsent(s.provider, () => i);
      }
    }
  }
  if (scores.isEmpty) return const Extracted.none();
  final ranked = scores.keys.toList()
    ..sort((a, b) {
      final byScore = scores[b]!.compareTo(scores[a]!);
      return byScore != 0 ? byScore : firstSeen[a]!.compareTo(firstSeen[b]!);
    });
  final best = ranked.first;
  final tie = ranked.length > 1 && scores[ranked[1]] == scores[best];
  final confidence = strongHit.contains(best) && !tie
      ? FieldConfidence.high
      : (tie ? FieldConfidence.low : FieldConfidence.medium);
  return Extracted(best, confidence);
}

/// Active account whose name contains the provider name (word match), e.g.
/// provider GoPay → account "GoPay". Accounts of the provider's type win.
Account? accountForProvider(List<Account> accounts, WalletProvider provider) {
  final matches = [
    for (final a in accounts)
      if (a.isActive && provider.accountKeys.any((k) => _word(k).hasMatch(a.name))) a,
  ];
  if (matches.isEmpty) return null;
  return matches.firstWhere((a) => a.type == provider.accountType, orElse: () => matches.first);
}
