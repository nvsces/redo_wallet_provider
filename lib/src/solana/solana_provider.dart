import 'dart:convert';
import 'dart:typed_data';

import 'package:redo_wallet_provider/src/core/json_rpc.dart';
import 'package:redo_wallet_provider/src/core/provider.dart';

/// Solana JSON-RPC провайдер.
class SolanaProvider implements BlockchainProvider {
  final JsonRpcClient _rpc;
  final String _network;

  SolanaProvider({
    required String rpcUrl,
    String network = 'solana',
    Map<String, String> headers = const {},
  })  : _rpc = JsonRpcClient(url: rpcUrl, headers: headers),
        _network = network;

  factory SolanaProvider.mainnet({String? rpcUrl}) => SolanaProvider(
        rpcUrl: rpcUrl ?? 'https://api.mainnet-beta.solana.com',
        network: 'solana-mainnet',
      );

  factory SolanaProvider.devnet({String? rpcUrl}) => SolanaProvider(
        rpcUrl: rpcUrl ?? 'https://api.devnet.solana.com',
        network: 'solana-devnet',
      );

  @override
  String get network => _network;

  @override
  Future<Balance> getBalance(String address) async {
    final result = await _rpc.call('getBalance', [address]);
    final lamports = BigInt.from((result as Map)['value'] as int);
    return Balance(amount: lamports, decimals: 9, symbol: 'SOL');
  }

  @override
  Future<TxResult> broadcast(Uint8List signedTx) async {
    final b64 = base64Encode(signedTx);
    try {
      final result = await _rpc.call('sendTransaction', [
        b64,
        {'encoding': 'base64'},
      ]);
      return TxResult(hash: result as String, success: true);
    } on JsonRpcException catch (e) {
      return TxResult(hash: '', success: false, error: e.message);
    }
  }

  @override
  Future<TxInfo?> getTransaction(String hash) async {
    final result = await _rpc.call('getTransaction', [
      hash,
      {'encoding': 'json', 'maxSupportedTransactionVersion': 0},
    ]);
    if (result == null) return null;
    final map = result as Map<String, dynamic>;
    final meta = map['meta'] as Map<String, dynamic>?;
    final status = meta?['err'] == null ? TxStatus.confirmed : TxStatus.failed;

    return TxInfo(
      hash: hash,
      status: status,
      from: '',
      to: '',
      amount: BigInt.zero,
      fee: BigInt.from(meta?['fee'] as int? ?? 0),
      blockNumber: map['slot'] as int?,
    );
  }

  @override
  Future<int> getBlockNumber() async {
    final result = await _rpc.call('getSlot');
    return result as int;
  }

  @override
  Future<List<TxInfo>> getTransactionHistory(String address, {int limit = 20}) async {
    return [];
  }

  // ── Solana-специфичные методы ──

  /// Получить последний blockhash (нужен для транзакций).
  Future<({String blockhash, int lastValidBlockHeight})> getLatestBlockhash() async {
    final result = await _rpc.call('getLatestBlockhash');
    final value = (result as Map)['value'] as Map;
    return (
      blockhash: value['blockhash'] as String,
      lastValidBlockHeight: value['lastValidBlockHeight'] as int,
    );
  }

  /// Минимальный баланс для rent-exempt аккаунта.
  Future<int> getMinimumBalanceForRentExemption(int dataLength) async {
    final result = await _rpc.call('getMinimumBalanceForRentExemption', [dataLength]);
    return result as int;
  }

  /// Получить баланс SPL-токена.
  Future<BigInt> getTokenBalance(String tokenAccount) async {
    try {
      final result = await _rpc.call('getTokenAccountBalance', [tokenAccount]);
      final amount = (result as Map)['value']?['amount'] as String? ?? '0';
      return BigInt.parse(amount);
    } on JsonRpcException {
      return BigInt.zero;
    }
  }

  /// Получить все токен-аккаунты владельца.
  Future<List<Map<String, dynamic>>> getTokenAccountsByOwner(
    String owner,
    String programId,
  ) async {
    final result = await _rpc.call('getTokenAccountsByOwner', [
      owner,
      {'programId': programId},
      {'encoding': 'jsonParsed'},
    ]);
    return ((result as Map)['value'] as List).cast<Map<String, dynamic>>();
  }

  /// Получить информацию об аккаунте.
  Future<Map<String, dynamic>?> getAccountInfo(String address) async {
    final result = await _rpc.call('getAccountInfo', [
      address,
      {'encoding': 'jsonParsed'},
    ]);
    return (result as Map)['value'] as Map<String, dynamic>?;
  }

  void close() => _rpc.close();
}
