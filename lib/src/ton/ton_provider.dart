import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:redo_wallet_provider/src/core/provider.dart';

/// TON провайдер через toncenter HTTP API v2/v3.
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

  bool get isTestnet => _network.contains('testnet');

  /// Base URL for v3 API (jetton endpoints).
  String get _v3BaseUrl {
    final host = Uri.parse(baseUrl).host;
    return 'https://$host/api/v3';
  }

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

  /// JSON-RPC POST (для sendBoc и estimateFee).
  Future<Map<String, dynamic>> _jsonRpc(String method, Map<String, dynamic> params) async {
    final resp = await _client.post(
      Uri.parse('$baseUrl/jsonRPC'),
      headers: _headers,
      body: jsonEncode({
        'id': '1',
        'jsonrpc': '2.0',
        'method': method,
        'params': params,
      }),
    );
    return jsonDecode(resp.body) as Map<String, dynamic>;
  }

  // ═══════════════════════════════════════════════════════
  //  BlockchainProvider interface
  // ═══════════════════════════════════════════════════════

  @override
  Future<Balance> getBalance(String address) async {
    final json = await _get('getAddressBalance', {'address': address});
    final amount = BigInt.parse(json['result'].toString());
    return Balance(amount: amount, decimals: 9, symbol: 'TON');
  }

  @override
  Future<TxResult> broadcast(Uint8List signedTx) async {
    final boc = utf8.decode(signedTx);
    return sendBoc(boc);
  }

  @override
  Future<TxInfo?> getTransaction(String hash) async {
    // TON v2 API не поддерживает прямой поиск по hash (нужен lt + hash).
    return null;
  }

  @override
  Future<int> getBlockNumber() async {
    final json = await _get('getMasterchainInfo', {});
    if (json['ok'] != true) return 0;
    return (json['result'] as Map)['last']?['seqno'] as int? ?? 0;
  }

  @override
  Future<List<TxInfo>> getTransactionHistory(String address, {int limit = 20}) async {
    final rawList = await getTransactions(address, limit: limit);
    return rawList.map((raw) => _parseTxInfo(raw, address)).toList();
  }

  // ═══════════════════════════════════════════════════════
  //  TON-специфичные методы
  // ═══════════════════════════════════════════════════════

  /// Отправить BOC (base64) в сеть.
  Future<TxResult> sendBoc(String bocBase64) async {
    final json = await _jsonRpc('sendBoc', {'boc': bocBase64});
    if (json['ok'] == true || json['result'] != null && json['error'] == null) {
      final hash = json['result']?['hash']?.toString() ?? '';
      return TxResult(hash: hash, success: true);
    }
    return TxResult(
      hash: '',
      success: false,
      error: json['error']?.toString() ?? json['result']?.toString() ?? 'Unknown error',
    );
  }

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

  /// Проверить, задеплоен ли контракт.
  Future<bool> isContractDeployed(String address) async {
    final info = await getAddressInfo(address);
    if (info == null) return false;
    final state = info['state']?.toString() ?? '';
    return state == 'active';
  }

  /// Получить список транзакций (raw JSON).
  Future<List<Map<String, dynamic>>> getTransactions(String address, {int limit = 10}) async {
    final json = await _get('getTransactions', {
      'address': address,
      'limit': limit.toString(),
    });
    if (json['ok'] != true) return [];
    return (json['result'] as List).cast<Map<String, dynamic>>();
  }

  /// Оценить комиссию для внешнего сообщения.
  Future<BigInt> estimateExternalMessageFee(String address, String bocBase64) async {
    final json = await _jsonRpc('estimateFee', {
      'address': address,
      'body': bocBase64,
      'ignore_chksig': true,
    });
    if (json['error'] != null) return BigInt.from(5000000); // fallback ~0.005 TON
    final result = json['result'] as Map<String, dynamic>? ?? {};
    final sourceFees = result['source_fees'] as Map<String, dynamic>? ?? {};
    final total = (sourceFees['in_fwd_fee'] as int? ?? 0) +
        (sourceFees['storage_fee'] as int? ?? 0) +
        (sourceFees['gas_fee'] as int? ?? 0) +
        (sourceFees['fwd_fee'] as int? ?? 0);
    return BigInt.from(total);
  }

  /// Получить балансы всех Jetton-токенов (через v3 API).
  Future<List<TokenBalanceInfo>> getJettonBalances(String ownerAddress) async {
    try {
      final uri = Uri.parse('$_v3BaseUrl/jetton/wallets').replace(
        queryParameters: {
          'owner_address': ownerAddress,
          'exclude_zero_balance': 'true',
          'limit': '50',
        },
      );

      final response = await _client.get(uri, headers: _headers);
      final decoded = jsonDecode(response.body) as Map<String, dynamic>;

      final wallets = decoded['jetton_wallets'] as List? ?? [];
      final metadata = decoded['metadata'] as Map<String, dynamic>? ?? {};

      final result = <TokenBalanceInfo>[];

      for (final w in wallets) {
        final balance = BigInt.tryParse(w['balance']?.toString() ?? '0') ?? BigInt.zero;
        if (balance <= BigInt.zero) continue;

        final jettonMaster = w['jetton'] as String? ?? '';
        final walletAddr = w['address'] as String? ?? '';

        String symbol = '';
        String name = '';
        int decimals = 9;
        String? imageUrl;

        final masterMeta = metadata[jettonMaster];
        if (masterMeta != null) {
          final tokenInfoList = masterMeta['token_info'] as List? ?? [];
          for (final info in tokenInfoList) {
            if (info['type'] == 'jetton_masters') {
              symbol = info['symbol']?.toString() ?? '';
              name = info['name']?.toString() ?? '';
              imageUrl = info['image']?.toString();
              final extra = info['extra'] as Map<String, dynamic>? ?? {};
              decimals = int.tryParse(extra['decimals']?.toString() ?? '9') ?? 9;
            }
          }
        }

        if (symbol.isEmpty) continue;

        result.add(TokenBalanceInfo(
          contractAddress: jettonMaster,
          walletAddress: walletAddr,
          balance: balance,
          symbol: symbol,
          name: name,
          decimals: decimals,
          imageUrl: imageUrl,
        ));
      }

      result.sort((a, b) => b.balance.compareTo(a.balance));
      return result;
    } catch (_) {
      return [];
    }
  }

  void close() => _client.close();

  // ═══════════════════════════════════════════════════════
  //  Private helpers
  // ═══════════════════════════════════════════════════════

  TxInfo _parseTxInfo(Map<String, dynamic> raw, String myAddress) {
    BigInt amount = BigInt.zero;
    String from = myAddress;
    String to = '';
    String? comment;

    final outMsgs = raw['out_msgs'] as List? ?? [];
    final inMsg = raw['in_msg'] as Map<String, dynamic>?;
    final fee = BigInt.tryParse(raw['fee']?.toString() ?? '0') ?? BigInt.zero;
    final utime = raw['utime'] as int? ?? 0;

    if (outMsgs.isNotEmpty) {
      // Outgoing transaction
      for (final msg in outMsgs) {
        final value = BigInt.tryParse(msg['value']?.toString() ?? '0') ?? BigInt.zero;
        amount += value;
        if (to.isEmpty) {
          to = msg['destination']?.toString() ?? '';
        }
        if (comment == null) {
          final msgData = msg['msg_data'] as Map<String, dynamic>?;
          if (msgData != null && msgData['@type'] == 'msg.dataText') {
            try {
              comment = utf8.decode(base64Decode(msgData['text'] as String));
            } catch (_) {}
          }
        }
      }
      from = myAddress;
    } else if (inMsg != null) {
      // Incoming transaction
      final value = BigInt.tryParse(inMsg['value']?.toString() ?? '0') ?? BigInt.zero;
      amount = value;
      from = inMsg['source']?.toString() ?? '';
      to = myAddress;

      final msgData = inMsg['msg_data'] as Map<String, dynamic>?;
      if (msgData != null && msgData['@type'] == 'msg.dataText') {
        try {
          comment = utf8.decode(base64Decode(msgData['text'] as String));
        } catch (_) {}
      }
    }

    final hash = raw['transaction_id']?['hash']?.toString() ?? '';

    return TxInfo(
      hash: hash,
      status: TxStatus.confirmed,
      from: from,
      to: to,
      amount: amount,
      fee: fee,
      timestamp: DateTime.fromMillisecondsSinceEpoch(utime * 1000),
      comment: comment,
    );
  }
}
