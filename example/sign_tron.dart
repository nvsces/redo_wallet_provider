// ═══════════════════════════════════════════════════════════════
//  Tron: подпись TRX перевода и TRC-20 USDT перевода
//
//  wallet_core (подпись) + wallet_provider (сеть)
//
//  Запуск: dart run example/sign_tron.dart
// ═══════════════════════════════════════════════════════════════

import 'dart:typed_data';

import 'package:fixnum/fixnum.dart';
import 'package:redo_wallet_core/redo_wallet_core.dart';
import 'package:redo_wallet_core/src/proto/Tron.pb.dart' as tron;
import 'package:redo_wallet_provider/redo_wallet_provider.dart';

String _hex(Uint8List data) =>
    data.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

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

void main() async {
  print('=== Tron Transaction Signing ===\n');

  final core = WalletCoreAPI();
  final provider = TronProvider.mainnet();

  // ── 1. Кошелёк ──
  const mnemonic =
      'abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about';
  final wallet = core.hdWalletFromMnemonic(mnemonic);
  final senderAddress = wallet.getAddressForCoin(TWCoinType.tron);
  final privateKey = wallet.getPrivateKeyForCoin(TWCoinType.tron);

  print('Отправитель: $senderAddress');
  print('');

  // ── 2. Получаем данные блока из сети (для ref_block) ──
  final latestBlock = await provider.getLatestBlock();
  final now = DateTime.now().millisecondsSinceEpoch;

  print('Последний блок: ${latestBlock.number}');
  print('Block hash: ${latestBlock.hash.substring(0, 16)}...');
  print('');

  // ref_block_bytes = последние 2 байта номера блока
  // ref_block_hash = байты 8-16 хеша блока
  final blockBytes = _hexToBytes(
    latestBlock.number.toRadixString(16).padLeft(16, '0').substring(12, 16),
  );
  final blockHash = _hexToBytes(latestBlock.hash.substring(16, 32));

  // ═══════════════════════════════════════════
  //  Пример 1: TRX Transfer (нативная монета)
  // ═══════════════════════════════════════════
  print('═══ TRX Transfer ═══');
  const receiverAddress = 'TJRabPrwbZy45sbavfcjinPJC18kjpRTv8'; // пример

  final trxInput = tron.SigningInput(
    transaction: tron.Transaction(
      timestamp: Int64(now),
      expiration: Int64(now + 600000),
      blockHeader: tron.BlockHeader(
        timestamp: Int64(now),
        number: Int64(latestBlock.number),
        txTrieRoot: blockBytes,
        parentHash: blockHash,
      ),
      transfer: tron.TransferContract(
        ownerAddress: senderAddress,
        toAddress: receiverAddress,
        amount: Int64(1000000), // 1 TRX = 1_000_000 Sun
      ),
    ),
    privateKey: privateKey,
  );

  final trxInputBytes = Uint8List.fromList(trxInput.writeToBuffer());
  final trxOutputBytes = core.signTransaction(trxInputBytes, TWCoinType.tron);
  final trxOutput = tron.SigningOutput.fromBuffer(trxOutputBytes);

  if (trxOutput.errorMessage.isNotEmpty) {
    print('  ОШИБКА: ${trxOutput.errorMessage}');
  } else {
    print('  TX ID:     ${_hex(Uint8List.fromList(trxOutput.id))}');
    print('  Signature: ${_hex(Uint8List.fromList(trxOutput.signature)).substring(0, 32)}...');
    print('  JSON size: ${trxOutput.json.length} chars');
    print('  Сумма:     1 TRX → $receiverAddress');
    print('');
  }

  // ═══════════════════════════════════════════
  //  Пример 2: TRC-20 USDT Transfer
  // ═══════════════════════════════════════════
  print('═══ TRC-20 USDT Transfer ═══');
  const usdtContract = 'TR7NHqjeKQxGTCi8q282JJUC56ChsPr1gT';

  final usdtInput = tron.SigningInput(
    transaction: tron.Transaction(
      timestamp: Int64(now),
      expiration: Int64(now + 600000),
      blockHeader: tron.BlockHeader(
        timestamp: Int64(now),
        number: Int64(latestBlock.number),
        txTrieRoot: blockBytes,
        parentHash: blockHash,
      ),
      feeLimit: Int64(40000000), // 40 TRX fee limit (для energy)
      transferTrc20Contract: tron.TransferTRC20Contract(
        contractAddress: usdtContract,
        ownerAddress: senderAddress,
        toAddress: receiverAddress,
        amount: _bigIntToBytes(BigInt.from(10000000)), // 10 USDT (6 decimals)
      ),
    ),
    privateKey: privateKey,
  );

  final usdtInputBytes = Uint8List.fromList(usdtInput.writeToBuffer());
  final usdtOutputBytes = core.signTransaction(usdtInputBytes, TWCoinType.tron);
  final usdtOutput = tron.SigningOutput.fromBuffer(usdtOutputBytes);

  if (usdtOutput.errorMessage.isNotEmpty) {
    print('  ОШИБКА: ${usdtOutput.errorMessage}');
  } else {
    print('  TX ID:     ${_hex(Uint8List.fromList(usdtOutput.id))}');
    print('  Signature: ${_hex(Uint8List.fromList(usdtOutput.signature)).substring(0, 32)}...');
    print('  Сумма:     10 USDT → $receiverAddress');
    print('  Fee limit: 40 TRX (для energy)');
    print('');

    // Показываем как отправить
    print('  Для отправки в сеть:');
    print('  final result = await provider.broadcastTransaction(');
    print('    jsonDecode(output.json),');
    print('  );');
  }

  // ── Проверяем баланс (нужен для реальной отправки) ──
  print('');
  await Future.delayed(const Duration(seconds: 2));
  final balance = await provider.getBalance(senderAddress);
  print('Баланс: $balance');
  if (balance.amount == BigInt.zero) {
    print('Баланс 0 — транзакции не отправляем (демо).');
    print('Пополните $senderAddress для реальной отправки.');
  }

  wallet.delete();
  provider.close();
  print('\n=== Done! ===');
}

Uint8List _hexToBytes(String hex) {
  final bytes = <int>[];
  for (var i = 0; i < hex.length; i += 2) {
    bytes.add(int.parse(hex.substring(i, i + 2), radix: 16));
  }
  return Uint8List.fromList(bytes);
}
