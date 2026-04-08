import 'dart:typed_data';

/// Баланс аккаунта.
class Balance {
  final BigInt amount;
  final int decimals;
  final String symbol;

  const Balance({required this.amount, required this.decimals, required this.symbol});

  double get asDouble => amount.toDouble() / BigInt.from(10).pow(decimals).toDouble();

  @override
  String toString() => '${asDouble.toStringAsFixed(decimals > 6 ? 6 : decimals)} $symbol';
}

/// Статус транзакции.
enum TxStatus { pending, confirmed, failed, unknown }

/// Результат отправки транзакции.
class TxResult {
  final String hash;
  final bool success;
  final String? error;

  const TxResult({required this.hash, required this.success, this.error});

  @override
  String toString() => success ? 'TX $hash' : 'FAILED: $error';
}

/// Информация о транзакции.
class TxInfo {
  final String hash;
  final TxStatus status;
  final String from;
  final String to;
  final BigInt amount;
  final BigInt fee;
  final int? blockNumber;
  final DateTime? timestamp;
  final String? comment;
  final Uint8List? bodyData;

  const TxInfo({
    required this.hash,
    required this.status,
    required this.from,
    required this.to,
    required this.amount,
    required this.fee,
    this.blockNumber,
    this.timestamp,
    this.comment,
    this.bodyData,
  });
}

/// Информация о балансе токена (Jetton, TRC-20, ERC-20, SPL).
class TokenBalanceInfo {
  final String contractAddress;
  final String walletAddress;
  final BigInt balance;
  final String symbol;
  final String name;
  final int decimals;
  final String? imageUrl;

  const TokenBalanceInfo({
    required this.contractAddress,
    required this.walletAddress,
    required this.balance,
    required this.symbol,
    required this.name,
    required this.decimals,
    this.imageUrl,
  });
}

/// Абстрактный провайдер блокчейна.
///
/// Каждый блокчейн реализует этот интерфейс.
/// Провайдер = связь с сетью (HTTP к ноде/API).
abstract class BlockchainProvider {
  /// Название сети (ethereum-mainnet, ton-testnet, ...)
  String get network;

  /// Получить баланс адреса.
  Future<Balance> getBalance(String address);

  /// Отправить подписанную транзакцию в сеть.
  /// [signedTx] — сериализованная подписанная транзакция.
  Future<TxResult> broadcast(Uint8List signedTx);

  /// Получить информацию о транзакции по хешу.
  Future<TxInfo?> getTransaction(String hash);

  /// Текущая высота блока.
  Future<int> getBlockNumber();

  /// История транзакций для адреса.
  Future<List<TxInfo>> getTransactionHistory(String address, {int limit = 20});
}
