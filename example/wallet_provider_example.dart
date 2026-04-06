// ═══════════════════════════════════════════════════════════════
//  wallet_provider — запросы к реальным блокчейнам
//
//  Запуск: dart run example/wallet_provider_example.dart
// ═══════════════════════════════════════════════════════════════

import 'package:redo_wallet_provider/redo_wallet_provider.dart';

void main() async {
  print('=== Blockchain Providers ===\n');

  // ════════════════════════════════════════════
  //  Ethereum (mainnet)
  // ════════════════════════════════════════════
  print('--- Ethereum ---');
  final eth = EthereumProvider.mainnet();

  final vitalik = '0xd8dA6BF26964aF9D7eEd9e03E53415D37aA96045';
  final ethBalance = await eth.getBalance(vitalik);
  print('  Vitalik balance: $ethBalance');

  final ethBlock = await eth.getBlockNumber();
  print('  Block number:    $ethBlock');

  final gasPrice = await eth.getGasPrice();
  print('  Gas price:       ${gasPrice ~/ BigInt.from(1000000000)} Gwei');

  final chainId = await eth.getChainId();
  print('  Chain ID:        $chainId');

  // ERC-20 USDT баланс
  const usdt = '0xdAC17F958D2ee523a2206206994597C13D831ec7';
  final usdtBalance = await eth.getTokenBalance(vitalik, usdt);
  print('  USDT balance:    ${usdtBalance.toDouble() / 1e6} USDT');
  print('');

  eth.close();

  // ════════════════════════════════════════════
  //  Bitcoin (mainnet)
  // ════════════════════════════════════════════
  print('--- Bitcoin ---');
  final btc = BitcoinProvider.mainnet();

  // Satoshi's genesis address
  const satoshi = '1A1zP1eP5QGefi2DMPTfTL5SLmv7DivfNa';
  final btcBalance = await btc.getBalance(satoshi);
  print('  Satoshi genesis: $btcBalance');

  final btcBlock = await btc.getBlockNumber();
  print('  Block height:    $btcBlock');

  final fees = await btc.getFeeEstimates();
  print('  Fee rates:       fastest=${fees.fastest} halfHour=${fees.halfHour} hour=${fees.hour} sat/vB');
  print('');

  btc.close();

  // ════════════════════════════════════════════
  //  Solana (mainnet)
  // ════════════════════════════════════════════
  print('--- Solana ---');
  final sol = SolanaProvider.mainnet();

  // Solana known address
  const toly = 'GUfCR9mK6azb9vcpsxgXyj7XRPAKJFKa7RWo9AMCycrA';
  try {
    final solBalance = await sol.getBalance(toly);
    print('  Toly balance:    $solBalance');
  } catch (e) {
    print('  Toly balance:    (rate limited or error: $e)');
  }

  final slot = await sol.getBlockNumber();
  print('  Current slot:    $slot');

  final blockhash = await sol.getLatestBlockhash();
  print('  Blockhash:       ${blockhash.blockhash.substring(0, 20)}...');
  print('');

  sol.close();

  // ════════════════════════════════════════════
  //  TON (mainnet)
  // ════════════════════════════════════════════
  print('--- TON ---');
  final ton = TonProvider.mainnet();

  // TON Foundation
  const tonFoundation = 'EQDtFpEwcFAEcRe5mLVh2N6C0x-_hJEM7W61_JLnSF74p4q2';
  final tonBalance = await ton.getBalance(tonFoundation);
  print('  TON Foundation:  $tonBalance');

  final tonBlock = await ton.getBlockNumber();
  print('  MC seqno:        $tonBlock');
  print('');

  ton.close();

  // ════════════════════════════════════════════
  //  Мульти-чейн сводка
  // ════════════════════════════════════════════
  print('=== Summary ===');
  print('  ETH block: $ethBlock | BTC block: $btcBlock | SOL slot: $slot | TON MC: $tonBlock');
  print('=== Done! ===');
}
