// ═══════════════════════════════════════════════════════════════
//  End-to-end: wallet_core (подпись) + wallet_provider (сеть)
//
//  Показывает полный цикл:
//  1. Создать кошелёк (wallet_core)
//  2. Получить баланс из сети (wallet_provider)
//  3. Подписать транзакцию (wallet_core)
//  4. Отправить в сеть (wallet_provider)
//
//  Запуск: dart run example/end_to_end.dart
// ═══════════════════════════════════════════════════════════════

import 'dart:typed_data';

import 'package:redo_wallet_core/redo_wallet_core.dart';
import 'package:redo_wallet_core/src/proto/Ethereum.pb.dart' as eth_proto;
import 'package:redo_wallet_provider/redo_wallet_provider.dart';

Uint8List _bigIntToBytes(BigInt value) {
  if (value == BigInt.zero) return Uint8List.fromList([0]);
  var hex = value.toRadixString(16);
  if (hex.length.isOdd) hex = '0$hex';
  final bytes = <int>[];
  for (var i = 0; i < hex.length; i += 2) {
    bytes.add(int.parse(hex.substring(i, i + 2), radix: 16));
  }
  return Uint8List.fromList(bytes);
}

String _hex(Uint8List data) =>
    data.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

void main() async {
  print('=== End-to-End: Wallet Core + Provider ===\n');

  // ── 1. OFFLINE: Создать кошелёк ──
  final core = WalletCoreAPI();
  const mnemonic = 'abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about';
  final wallet = core.hdWalletFromMnemonic(mnemonic);

  final ethAddress = wallet.getAddressForCoin(TWCoinType.ethereum);
  final btcAddress = wallet.getAddressForCoin(TWCoinType.bitcoin);
  final tonAddress = wallet.getAddressForCoin(TWCoinType.ton);
  final solAddress = wallet.getAddressForCoin(TWCoinType.solana);

  print('Кошелёк создан (offline — wallet_core):');
  print('  ETH: $ethAddress');
  print('  BTC: $btcAddress');
  print('  TON: $tonAddress');
  print('  SOL: $solAddress');

  // Информация о монетах
  print('');
  for (final coin in [TWCoinType.ethereum, TWCoinType.bitcoin, TWCoinType.ton, TWCoinType.solana]) {
    final name = core.coinName(coin);
    final symbol = core.coinSymbol(coin);
    final decimals = core.coinDecimals(coin);
    print('  $name: $symbol, $decimals decimals');
  }
  print('');

  // ── 2. ONLINE: Балансы из сети ──
  print('Балансы из сети (online — wallet_provider):');
  final ethProvider = EthereumProvider.mainnet();
  final btcProvider = BitcoinProvider.mainnet();
  final tonProvider = TonProvider.mainnet();

  final ethBal = await ethProvider.getBalance(ethAddress);
  print('  ETH: $ethBal');
  final btcBal = await btcProvider.getBalance(btcAddress);
  print('  BTC: $btcBal');
  final tonBal = await tonProvider.getBalance(tonAddress);
  print('  TON: $tonBal');
  print('');

  // ── 3. Параметры сети для транзакции ──
  print('Параметры сети для ETH транзакции:');
  final nonce = await ethProvider.getNonce(ethAddress);
  final feeData = await ethProvider.getFeeData();
  final chainId = await ethProvider.getChainId();
  print('  Nonce:         $nonce');
  print('  Base fee:      ${feeData.baseFee ~/ BigInt.from(1000000000)} Gwei');
  print('  Priority fee:  ${feeData.priorityFee ~/ BigInt.from(1000000000)} Gwei');
  print('  Chain ID:      $chainId');
  print('');

  // ── 4. OFFLINE: Подписываем транзакцию ──
  print('Подписываем ETH транзакцию (offline — wallet_core):');
  final privateKey = wallet.getPrivateKeyForCoin(TWCoinType.ethereum);
  final maxFee = feeData.baseFee * BigInt.two + feeData.priorityFee;

  final signingInput = eth_proto.SigningInput(
    chainId: _bigIntToBytes(BigInt.from(chainId)),
    nonce: _bigIntToBytes(BigInt.from(nonce)),
    txMode: eth_proto.TransactionMode.Enveloped,
    maxInclusionFeePerGas: _bigIntToBytes(feeData.priorityFee),
    maxFeePerGas: _bigIntToBytes(maxFee),
    gasLimit: _bigIntToBytes(BigInt.from(21000)),
    toAddress: '0x0000000000000000000000000000000000000000',
    privateKey: privateKey,
    transaction: eth_proto.Transaction(
      transfer: eth_proto.Transaction_Transfer(
        amount: _bigIntToBytes(BigInt.zero), // 0 ETH (демо)
      ),
    ),
  );

  final inputBytes = Uint8List.fromList(signingInput.writeToBuffer());
  final outputBytes = core.signTransaction(inputBytes, TWCoinType.ethereum);
  final output = eth_proto.SigningOutput.fromBuffer(outputBytes);

  print('  Signed tx:  ${_hex(Uint8List.fromList(output.encoded)).substring(0, 40)}...');
  print('  Size:       ${output.encoded.length} bytes');
  print('  V: ${_hex(Uint8List.fromList(output.v))}');
  print('  R: ${_hex(Uint8List.fromList(output.r)).substring(0, 16)}...');
  print('  S: ${_hex(Uint8List.fromList(output.s)).substring(0, 16)}...');
  print('');

  // ── 5. НЕ отправляем (баланс 0, это демо) ──
  if (ethBal.amount > BigInt.zero) {
    print('Отправляем в сеть...');
    final result = await ethProvider.broadcast(Uint8List.fromList(output.encoded));
    print('  Result: $result');
  } else {
    print('Баланс 0 — не отправляем (это демо).');
    print('Для реальной отправки пополните $ethAddress');
  }

  // Explorer URLs
  print('');
  print('Explorer URLs:');
  print('  ${core.coinTransactionURL(TWCoinType.ethereum, "0xabc")}');
  print('  ${core.coinTransactionURL(TWCoinType.bitcoin, "abc")}');

  wallet.delete();
  ethProvider.close();
  btcProvider.close();
  tonProvider.close();
  print('\n=== Done! ===');
}
