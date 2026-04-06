import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:redo_wallet_provider/src/core/provider.dart';

/// TON провайдер через toncenter HTTP API v2.
class TonProvider implements BlockchainProvider {
  final String baseUrl;
  final String? apiKey;
  final http.Client _client;
  final String _network;

  TonProvider({
    required this.baseUrl,
    this.apiKey,
    String network = 'ton',
    http.Client? client,
  })  : _client = client ?? http.Client(),
        _network = network;

  factory TonProvider.mainnet({String? apiKey}) => TonProvider(
        baseUrl: 'https://toncenter.com/api/v2',
        apiKey: apiKey,
        network: 'ton-mainnet',
      );

  factory TonProvider.testnet({String? apiKey}) => TonProvider(
        baseUrl: 'https://testnet.toncenter.com/api/v2',
        apiKey: apiKey,
        network: 'ton-testnet',
      );

  @override
  String get network => _network;

  Map<String, String> get _headers => {
        'Content-Type': 'application/json',
        if (apiKey != null) 'X-API-Key': apiKey!,
      };

  Future<Map<String, dynamic>> _get(String method, Map<String, String> params) async {
    final uri = Uri.parse('$baseUrl/$method').replace(queryParameters: params);
    final resp = await _client.get(uri, headers: _headers);
    return jsonDecode(resp.body) as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> _post(String method, Map<String, dynamic> body) async {
    final resp = await _client.post(
      Uri.parse('$baseUrl/$method'),
      headers: _headers,
      body: jsonEncode(body),
    );
    return jsonDecode(resp.body) as Map<String, dynamic>;
  }

  @override
  Future<Balance> getBalance(String address) async {
    final json = await _get('getAddressBalance', {'address': address});
    final amount = BigInt.parse(json['result'].toString());
    return Balance(amount: amount, decimals: 9, symbol: 'TON');
  }

  @override
  Future<TxResult> broadcast(Uint8List signedTx) async {
    // TON broadcast принимает BOC в base64
    // signedTx здесь — UTF-8 bytes base64-строки BOC
    final boc = utf8.decode(signedTx);
    return sendBoc(boc);
  }

  /// Отправить BOC (base64) в сеть.
  Future<TxResult> sendBoc(String bocBase64) async {
    final json = await _post('sendBoc', {'boc': bocBase64});
    if (json['ok'] == true) {
      final hash = json['result']?['hash']?.toString() ?? '';
      return TxResult(hash: hash, success: true);
    }
    return TxResult(
      hash: '',
      success: false,
      error: json['error']?.toString() ?? json['result']?.toString() ?? 'Unknown error',
    );
  }

  @override
  Future<TxInfo?> getTransaction(String hash) async {
    // TON не поддерживает прямой поиск по hash через v2 API
    // Нужен lt + hash. Возвращаем null.
    return null;
  }

  @override
  Future<int> getBlockNumber() async {
    final json = await _get('getMasterchainInfo', {});
    if (json['ok'] != true) return 0;
    return (json['result'] as Map)['last']?['seqno'] as int? ?? 0;
  }

  // ── TON-специфичные методы ──

  /// Получить sequence number (seqno) кошелька.
  Future<int> getSeqno(String address) async {
    final json = await _post('runGetMethod', {
      'address': address,
      'method': 'seqno',
      'stack': [],
    });
    if (json['ok'] != true) return 0;
    final stack = (json['result'] as Map)['stack'] as List?;
    if (stack == null || stack.isEmpty) return 0;
    return int.parse(stack[0][1].toString().replaceFirst('0x', ''), radix: 16);
  }

  /// Получить состояние аккаунта.
  Future<Map<String, dynamic>?> getAddressInfo(String address) async {
    final json = await _get('getAddressInformation', {'address': address});
    if (json['ok'] != true) return null;
    return json['result'] as Map<String, dynamic>?;
  }

  /// Получить список транзакций.
  Future<List<Map<String, dynamic>>> getTransactions(String address, {int limit = 10}) async {
    final json = await _get('getTransactions', {
      'address': address,
      'limit': limit.toString(),
    });
    if (json['ok'] != true) return [];
    return (json['result'] as List).cast<Map<String, dynamic>>();
  }

  /// Получить баланс Jetton (TON токен).
  Future<BigInt> getJettonBalance(String ownerAddress, String jettonMaster) async {
    // Используем getJettonWalletAddress + balance
    final json = await _post('runGetMethod', {
      'address': jettonMaster,
      'method': 'get_wallet_address',
      'stack': [
        ['tvm.Slice', ownerAddress],
      ],
    });
    if (json['ok'] != true) return BigInt.zero;
    // Упрощённо — для полной реализации нужен парсинг TVM cell
    return BigInt.zero;
  }

  void close() => _client.close();
}
