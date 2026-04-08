import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:redo_wallet_provider/src/core/provider.dart';

/// UTXO (Unspent Transaction Output) для Bitcoin.
class Utxo {
  final String txHash;
  final int vout;
  final BigInt value;
  final TxStatus status;

  const Utxo({
    required this.txHash,
    required this.vout,
    required this.value,
    required this.status,
  });
}

/// Bitcoin провайдер через Blockstream/Mempool REST API.
class BitcoinProvider implements BlockchainProvider {
  final String baseUrl;
  final http.Client _client;
  final String _network;

  BitcoinProvider({
    required this.baseUrl,
    String network = 'bitcoin',
    http.Client? client,
  })  : _client = client ?? http.Client(),
        _network = network;

  factory BitcoinProvider.mainnet() => BitcoinProvider(
        baseUrl: 'https://blockstream.info/api',
        network: 'bitcoin-mainnet',
      );

  factory BitcoinProvider.testnet() => BitcoinProvider(
        baseUrl: 'https://blockstream.info/testnet/api',
        network: 'bitcoin-testnet',
      );

  factory BitcoinProvider.mempool() => BitcoinProvider(
        baseUrl: 'https://mempool.space/api',
        network: 'bitcoin-mainnet',
      );

  @override
  String get network => _network;

  Future<dynamic> _get(String path) async {
    final resp = await _client.get(Uri.parse('$baseUrl$path'));
    if (resp.statusCode != 200) {
      throw Exception('HTTP ${resp.statusCode}: ${resp.body}');
    }
    return jsonDecode(resp.body);
  }

  Future<String> _getText(String path) async {
    final resp = await _client.get(Uri.parse('$baseUrl$path'));
    if (resp.statusCode != 200) {
      throw Exception('HTTP ${resp.statusCode}: ${resp.body}');
    }
    return resp.body;
  }

  @override
  Future<Balance> getBalance(String address) async {
    final json = await _get('/address/$address');
    final stats = json as Map<String, dynamic>;
    final funded = BigInt.from(stats['chain_stats']?['funded_txo_sum'] as int? ?? 0);
    final spent = BigInt.from(stats['chain_stats']?['spent_txo_sum'] as int? ?? 0);
    // mempool (unconfirmed)
    final mFunded = BigInt.from(stats['mempool_stats']?['funded_txo_sum'] as int? ?? 0);
    final mSpent = BigInt.from(stats['mempool_stats']?['spent_txo_sum'] as int? ?? 0);
    final balance = (funded - spent) + (mFunded - mSpent);
    return Balance(amount: balance, decimals: 8, symbol: 'BTC');
  }

  @override
  Future<TxResult> broadcast(Uint8List signedTx) async {
    final hex = signedTx.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    final resp = await _client.post(
      Uri.parse('$baseUrl/tx'),
      body: hex,
    );
    if (resp.statusCode == 200) {
      return TxResult(hash: resp.body.trim(), success: true);
    }
    return TxResult(hash: '', success: false, error: resp.body);
  }

  @override
  Future<TxInfo?> getTransaction(String hash) async {
    try {
      final json = await _get('/tx/$hash');
      final map = json as Map<String, dynamic>;
      final status = map['status'] as Map<String, dynamic>?;
      final confirmed = status?['confirmed'] as bool? ?? false;

      BigInt totalIn = BigInt.zero;
      BigInt totalOut = BigInt.zero;
      String from = '';
      String to = '';

      final vin = map['vin'] as List? ?? [];
      for (final input in vin) {
        final prevout = (input as Map)['prevout'] as Map?;
        totalIn += BigInt.from(prevout?['value'] as int? ?? 0);
        from = prevout?['scriptpubkey_address'] as String? ?? from;
      }

      final vout = map['vout'] as List? ?? [];
      for (final output in vout) {
        totalOut += BigInt.from((output as Map)['value'] as int? ?? 0);
        to = output['scriptpubkey_address'] as String? ?? to;
      }

      return TxInfo(
        hash: hash,
        status: confirmed ? TxStatus.confirmed : TxStatus.pending,
        from: from,
        to: to,
        amount: totalOut,
        fee: totalIn - totalOut,
        blockNumber: status?['block_height'] as int?,
      );
    } catch (_) {
      return null;
    }
  }

  @override
  Future<int> getBlockNumber() async {
    final text = await _getText('/blocks/tip/height');
    return int.parse(text.trim());
  }

  @override
  Future<List<TxInfo>> getTransactionHistory(String address, {int limit = 20}) async {
    return [];
  }

  // ── Bitcoin-специфичные методы ──

  /// Получить UTXO для адреса (нужны для построения транзакции).
  Future<List<Utxo>> getUtxos(String address) async {
    final json = await _get('/address/$address/utxo');
    return (json as List).map((u) {
      final map = u as Map<String, dynamic>;
      final status = map['status'] as Map<String, dynamic>?;
      return Utxo(
        txHash: map['txid'] as String,
        vout: map['vout'] as int,
        value: BigInt.from(map['value'] as int),
        status: status?['confirmed'] == true ? TxStatus.confirmed : TxStatus.pending,
      );
    }).toList();
  }

  /// Рекомендуемые fee rates (sat/vB).
  Future<({int fastest, int halfHour, int hour, int economy})> getFeeEstimates() async {
    final json = await _get('/fee-estimates');
    final map = json as Map<String, dynamic>;
    return (
      fastest: (map['1'] as num?)?.toInt() ?? 1,
      halfHour: (map['3'] as num?)?.toInt() ?? 1,
      hour: (map['6'] as num?)?.toInt() ?? 1,
      economy: (map['25'] as num?)?.toInt() ?? 1,
    );
  }

  void close() => _client.close();
}
