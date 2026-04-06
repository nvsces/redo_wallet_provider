// ═══════════════════════════════════════════════════════════════
//  Tron Provider — TRX баланс + TRC-20 USDT
//
//  Запуск: dart run example/tron_example.dart
// ═══════════════════════════════════════════════════════════════

import 'package:redo_wallet_core/redo_wallet_core.dart';
import 'package:redo_wallet_provider/redo_wallet_provider.dart';

void main() async {
  print('=== Tron Provider ===\n');

  final core = WalletCoreAPI();
  final tron = TronProvider.mainnet();

  // ── 1. Кошелёк из мнемоники ──
  const mnemonic =
      'abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about';
  final wallet = core.hdWalletFromMnemonic(mnemonic);
  final tronAddress = wallet.getAddressForCoin(TWCoinType.tron);
  print('Адрес: $tronAddress');
  print('');

  // ── 2. Баланс TRX ──
  print('--- TRX ---');
  final balance = await tron.getBalance(tronAddress);
  print('  Баланс: $balance');

  // ── 3. Ресурсы (bandwidth, energy) ──
  print('');
  print('--- Ресурсы ---');
  final resources = await tron.getAccountResources(tronAddress);
  print('  $resources');

  // ── 4. TRC-20 USDT ──
  print('');
  print('--- TRC-20 USDT ---');
  const usdtContract = 'TR7NHqjeKQxGTCi8q282JJUC56ChsPr1gT';

  await Future.delayed(const Duration(seconds: 2));

  // USDT баланс нашего кошелька
  try {
    final usdtBalance = await tron.getTrc20Balance(tronAddress, usdtContract);
    final usdtFormatted = usdtBalance.toDouble() / 1e6;
    print('  USDT баланс: $usdtFormatted USDT');
  } catch (e) {
    print('  USDT баланс: (rate limited, попробуйте с API key)');
  }

  // ── 5. Блокчейн инфо ──
  print('');
  print('--- Блокчейн ---');
  await Future.delayed(const Duration(seconds: 2));
  final block = await tron.getBlockNumber();
  print('  Текущий блок: $block');

  // ── 7. Валидация адреса через wallet_core ──
  print('');
  print('--- Валидация ---');
  print('  $tronAddress valid? ${core.addressIsValid(tronAddress, TWCoinType.tron)}');
  print('  "invalid" valid? ${core.addressIsValid("invalid", TWCoinType.tron)}');
  print('  Explorer: ${core.coinTransactionURL(TWCoinType.tron, "abc123")}');

  wallet.delete();
  tron.close();
  print('\n=== Done! ===');
}
