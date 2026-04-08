import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:http/http.dart' as http;
import 'package:redo_wallet_provider/src/core/provider.dart';

/// Ресурсы аккаунта Tron (bandwidth + energy).
class TronResources {
  final int freeNetLimit;
  final int freeNetUsed;
  final int netLimit;
  final int netUsed;
  final int energyLimit;
  final int energyUsed;

  const TronResources({
    required this.freeNetLimit,
    required this.freeNetUsed,
    required this.netLimit,
    required this.netUsed,
    required this.energyLimit,
    required this.energyUsed,
  });

  int get freeBandwidth => freeNetLimit - freeNetUsed;
  int get stakedBandwidth => netLimit - netUsed;
  int get availableEnergy => energyLimit - energyUsed;

  @override
  String toString() =>
      'Bandwidth: $freeBandwidth free + $stakedBandwidth staked, Energy: $availableEnergy';
}

/// Информация о блоке для формирования транзакции.
class TronBlockInfo {
  final int number;
  final String hash;
  final int timestamp;
  final String txTrieRoot;
  final String parentHash;
  final String witnessAddress;
  final int version;

  const TronBlockInfo({
    required this.number,
    required this.hash,
    required this.timestamp,
    required this.txTrieRoot,
    required this.parentHash,
    required this.witnessAddress,
    required this.version,
  });
}

/// Tron провайдер через TronGrid HTTP API.
///
/// Tron использует Sun как минимальную единицу: 1 TRX = 1_000_000 Sun.
/// Tron НЕ использует nonce — вместо этого ref_block для replay protection.
class TronProvider implements BlockchainProvider {
  final String baseUrl;
  final String? apiKey;
  final http.Client _client;
  final String _network;

  TronProvider({
    required this.baseUrl,
    this.apiKey,
    String network = 'tron',
    http.Client? client,
  })  : _client = client ?? http.Client(),
        _network = network;

  factory TronProvider.mainnet({String? apiKey}) => TronProvider(
        baseUrl: 'https://api.trongrid.io',
        apiKey: apiKey,
        network: 'tron-mainnet',
      );

  factory TronProvider.shasta() => TronProvider(
        baseUrl: 'https://api.shasta.trongrid.io',
        network: 'tron-shasta',
      );

  factory TronProvider.nile() => TronProvider(
        baseUrl: 'https://nile.trongrid.io',
        network: 'tron-nile',
      );

  @override
  String get network => _network;

  Map<String, String> get _headers => {
        'Content-Type': 'application/json',
        if (apiKey != null) 'TRON-PRO-API-KEY': apiKey!,
      };

  Future<Map<String, dynamic>> _post(String path, Map<String, dynamic> body) async {
    final resp = await _client.post(
      Uri.parse('$baseUrl$path'),
      headers: _headers,
      body: jsonEncode(body),
    );
    if (resp.statusCode != 200) {
      throw Exception('HTTP ${resp.statusCode}: ${resp.body}');
    }
    return jsonDecode(resp.body) as Map<String, dynamic>;
  }

  // ════════════════════════════════════════════
  //  BlockchainProvider interface
  // ════════════════════════════════════════════

  @override
  Future<Balance> getBalance(String address) async {
    final json = await _post('/wallet/getaccount', {
      'address': address,
      'visible': true,
    });
    final balance = BigInt.from(json['balance'] as int? ?? 0);
    return Balance(amount: balance, decimals: 6, symbol: 'TRX');
  }

  @override
  Future<TxResult> broadcast(Uint8List signedTx) async {
    // signedTx = JSON bytes подписанной транзакции
    final txJson = jsonDecode(utf8.decode(signedTx)) as Map<String, dynamic>;
    return broadcastTransaction(txJson);
  }

  @override
  Future<TxInfo?> getTransaction(String hash) async {
    final json = await _post('/wallet/gettransactioninfobyid', {'value': hash});
    if (json.isEmpty) return null;

    final blockNumber = json['blockNumber'] as int? ?? 0;
    final fee = BigInt.from(json['fee'] as int? ?? 0);
    final result = json['receipt']?['result'] as String?;

    return TxInfo(
      hash: hash,
      status: blockNumber > 0
          ? (result == 'SUCCESS' || result == null ? TxStatus.confirmed : TxStatus.failed)
          : TxStatus.pending,
      from: '',
      to: '',
      amount: BigInt.zero,
      fee: fee,
      blockNumber: blockNumber > 0 ? blockNumber : null,
      timestamp: json['blockTimeStamp'] != null
          ? DateTime.fromMillisecondsSinceEpoch(json['blockTimeStamp'] as int)
          : null,
    );
  }

  @override
  Future<int> getBlockNumber() async {
    final json = await _post('/wallet/getnowblock', {});
    return json['block_header']?['raw_data']?['number'] as int? ?? 0;
  }

  @override
  Future<List<TxInfo>> getTransactionHistory(String address, {int limit = 20}) async {
    try {
      final uri = Uri.parse('$baseUrl/v1/accounts/$address/transactions')
          .replace(queryParameters: {
        'limit': limit.toString(),
        'only_confirmed': 'true',
      });

      final resp = await _client.get(uri, headers: _headers);
      if (resp.statusCode != 200) return [];
      final decoded = jsonDecode(resp.body) as Map<String, dynamic>;
      final data = decoded['data'] as List? ?? [];

      return data.map<TxInfo>((tx) => _parseTxInfo(tx, address)).toList();
    } catch (_) {
      return [];
    }
  }

  // ════════════════════════════════════════════
  //  Tron-специфичные методы
  // ════════════════════════════════════════════

  /// Отправить подписанную транзакцию (JSON).
  Future<TxResult> broadcastTransaction(Map<String, dynamic> signedTx) async {
    final json = await _post('/wallet/broadcasttransaction', signedTx);
    if (json['result'] == true) {
      return TxResult(hash: json['txid']?.toString() ?? '', success: true);
    }
    return TxResult(
      hash: '',
      success: false,
      error: json['message'] != null
          ? utf8.decode(base64Decode(json['message'] as String))
          : json.toString(),
    );
  }

  /// Ресурсы аккаунта (bandwidth, energy).
  Future<TronResources> getAccountResources(String address) async {
    final json = await _post('/wallet/getaccountresource', {
      'address': address,
      'visible': true,
    });
    return TronResources(
      freeNetLimit: json['freeNetLimit'] as int? ?? 600,
      freeNetUsed: json['freeNetUsed'] as int? ?? 0,
      netLimit: json['NetLimit'] as int? ?? 0,
      netUsed: json['NetUsed'] as int? ?? 0,
      energyLimit: json['EnergyLimit'] as int? ?? 0,
      energyUsed: json['EnergyUsed'] as int? ?? 0,
    );
  }

  /// Получить баланс TRC-20 токена.
  ///
  /// [tokenContract] — адрес контракта токена (base58).
  /// Например USDT: TR7NHqjeKQxGTCi8q282JJUC56ChsPr1gT
  Future<BigInt> getTrc20Balance(String ownerAddress, String tokenContract) async {
    // balanceOf(address) — ABI encoded
    final addressHex = _base58ToHex(ownerAddress);
    if (addressHex == null) return BigInt.zero;
    // Убираем 41 префикс (Tron address prefix) и паддим до 32 байт
    final paddedAddress = addressHex.substring(2).padLeft(64, '0');

    final json = await _post('/wallet/triggerconstantcontract', {
      'contract_address': tokenContract,
      'function_selector': 'balanceOf(address)',
      'parameter': paddedAddress,
      'owner_address': ownerAddress,
      'visible': true,
    });

    if (json['result']?['result'] != true) return BigInt.zero;

    final results = json['constant_result'] as List?;
    if (results == null || results.isEmpty) return BigInt.zero;
    final hex = results[0] as String;
    if (hex.isEmpty || hex == '0' * 64) return BigInt.zero;
    return BigInt.parse(hex, radix: 16);
  }

  /// Получить информацию о TRC-20 токене (symbol, decimals, name).
  Future<({String name, String symbol, int decimals})?> getTrc20Info(String tokenContract) async {
    // name()
    final nameJson = await _post('/wallet/triggerconstantcontract', {
      'contract_address': tokenContract,
      'function_selector': 'name()',
      'parameter': '',
      'owner_address': tokenContract,
      'visible': true,
    });
    // symbol()
    final symbolJson = await _post('/wallet/triggerconstantcontract', {
      'contract_address': tokenContract,
      'function_selector': 'symbol()',
      'parameter': '',
      'owner_address': tokenContract,
      'visible': true,
    });
    // decimals()
    final decimalsJson = await _post('/wallet/triggerconstantcontract', {
      'contract_address': tokenContract,
      'function_selector': 'decimals()',
      'parameter': '',
      'owner_address': tokenContract,
      'visible': true,
    });

    if (nameJson['result']?['result'] != true) return null;

    return (
      name: _decodeAbiString(nameJson['constant_result']?[0] as String? ?? ''),
      symbol: _decodeAbiString(symbolJson['constant_result']?[0] as String? ?? ''),
      decimals: _decodeAbiUint(decimalsJson['constant_result']?[0] as String? ?? '0'),
    );
  }

  /// Получить последний блок (нужен для ref_block при создании транзакции).
  Future<TronBlockInfo> getLatestBlock() async {
    final json = await _post('/wallet/getnowblock', {});
    final rawData = json['block_header']?['raw_data'] as Map<String, dynamic>? ?? {};
    return TronBlockInfo(
      number: rawData['number'] as int? ?? 0,
      hash: json['blockID'] as String? ?? '',
      timestamp: rawData['timestamp'] as int? ?? 0,
      txTrieRoot: rawData['txTrieRoot'] as String? ?? '',
      parentHash: rawData['parentHash'] as String? ?? '',
      witnessAddress: rawData['witness_address'] as String? ?? '',
      version: rawData['version'] as int? ?? 0,
    );
  }

  /// Получить аккаунт (полная информация).
  Future<Map<String, dynamic>?> getAccount(String address) async {
    final json = await _post('/wallet/getaccount', {
      'address': address,
      'visible': true,
    });
    if (json.isEmpty || json.containsKey('Error')) return null;
    return json;
  }

  // ════════════════════════════════════════════
  //  Утилиты
  // ════════════════════════════════════════════

  /// Декодировать ABI-encoded string.
  String _decodeAbiString(String hex) {
    if (hex.length < 128) return '';
    // offset (32 bytes) + length (32 bytes) + data
    final lengthHex = hex.substring(64, 128);
    final length = int.parse(lengthHex, radix: 16);
    final dataHex = hex.substring(128, 128 + length * 2);
    final bytes = <int>[];
    for (var i = 0; i < dataHex.length; i += 2) {
      bytes.add(int.parse(dataHex.substring(i, i + 2), radix: 16));
    }
    return utf8.decode(bytes);
  }

  /// Декодировать ABI-encoded uint256.
  int _decodeAbiUint(String hex) {
    if (hex.isEmpty) return 0;
    return int.parse(hex, radix: 16);
  }

  /// Конвертировать Tron base58 адрес в hex.
  /// Tron base58 адрес → 21 bytes (prefix 0x41 + 20 bytes address) → hex.
  String? _base58ToHex(String address) {
    // Упрощённая конвертация через ASCII → hex для visible=true API
    // Для точной конвертации нужен base58 decode
    // TronGrid API с visible=true принимает base58 напрямую
    // Но для parameter encoding нужен hex
    try {
      // Base58Check decode
      const alphabet = '123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz';
      var result = BigInt.zero;
      for (final c in address.codeUnits) {
        final index = alphabet.indexOf(String.fromCharCode(c));
        if (index < 0) return null;
        result = result * BigInt.from(58) + BigInt.from(index);
      }
      var hex = result.toRadixString(16);
      // Tron address = 42 hex chars (21 bytes)
      while (hex.length < 42) {
        hex = '0$hex';
      }
      // Убираем checksum (последние 8 hex = 4 bytes)
      return hex.substring(0, 42);
    } catch (_) {
      return null;
    }
  }

  /// Получить балансы всех TRC-20 токенов.
  Future<List<TokenBalanceInfo>> getTrc20Balances(String ownerAddress) async {
    try {
      final uri = Uri.parse('$baseUrl/v1/accounts/$ownerAddress');
      final resp = await _client.get(uri, headers: _headers);
      if (resp.statusCode != 200) return [];
      final decoded = jsonDecode(resp.body) as Map<String, dynamic>;
      final data = decoded['data'] as List? ?? [];
      if (data.isEmpty) return [];

      final account = data[0] as Map<String, dynamic>;
      final trc20 = account['trc20'] as List? ?? [];

      final result = <TokenBalanceInfo>[];

      for (final tokenMap in trc20) {
        if (tokenMap is! Map<String, dynamic>) continue;
        for (final entry in tokenMap.entries) {
          final contractAddress = entry.key;
          final balance = BigInt.tryParse(entry.value?.toString() ?? '0') ?? BigInt.zero;
          if (balance <= BigInt.zero) continue;

          final info = await getTrc20Info(contractAddress);
          if (info == null) continue;

          result.add(TokenBalanceInfo(
            contractAddress: contractAddress,
            walletAddress: ownerAddress,
            balance: balance,
            symbol: info.symbol,
            name: info.name,
            decimals: info.decimals,
          ));
        }
      }

      return result;
    } catch (_) {
      return [];
    }
  }

  void close() => _client.close();

  // ════════════════════════════════════════════
  //  Private helpers
  // ════════════════════════════════════════════

  TxInfo _parseTxInfo(Map<String, dynamic> tx, String myAddress) {
    BigInt amount = BigInt.zero;
    String from = '';
    String to = '';

    final rawData = tx['raw_data'] as Map<String, dynamic>? ?? {};
    final contracts = rawData['contract'] as List? ?? [];

    if (contracts.isNotEmpty) {
      final contract = contracts[0] as Map<String, dynamic>;
      final type = contract['type'] as String? ?? '';
      final param = contract['parameter']?['value'] as Map<String, dynamic>? ?? {};

      if (type == 'TransferContract') {
        amount = BigInt.from(param['amount'] as int? ?? 0);
        final rawFrom = param['owner_address'] as String? ?? '';
        final rawTo = param['to_address'] as String? ?? '';
        // API v1 returns hex addresses — convert to base58
        from = rawFrom.startsWith('41') && rawFrom.length == 42
            ? _hexToBase58(rawFrom) ?? rawFrom
            : rawFrom;
        to = rawTo.startsWith('41') && rawTo.length == 42
            ? _hexToBase58(rawTo) ?? rawTo
            : rawTo;
      }
    }

    final timestamp = tx['block_timestamp'] as int? ?? 0;
    final fee = tx['ret']?[0]?['fee'] as int? ?? 0;
    final hash = tx['txID'] as String? ?? '';
    final ret = tx['ret']?[0]?['contractRet'] as String?;

    return TxInfo(
      hash: hash,
      status: ret == 'SUCCESS' ? TxStatus.confirmed : TxStatus.failed,
      from: from,
      to: to,
      amount: amount,
      fee: BigInt.from(fee),
      timestamp: DateTime.fromMillisecondsSinceEpoch(timestamp),
    );
  }

  /// Конвертировать hex адрес (41-prefixed) в Tron base58check.
  String? _hexToBase58(String hex) {
    try {
      const alphabet = '123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz';

      // Decode hex to bytes
      final bytes = <int>[];
      for (var i = 0; i < hex.length; i += 2) {
        bytes.add(int.parse(hex.substring(i, i + 2), radix: 16));
      }
      final payload = Uint8List.fromList(bytes);

      // Double SHA-256 for checksum
      final hash1 = crypto.sha256.convert(payload).bytes;
      final hash2 = crypto.sha256.convert(hash1).bytes;
      final checksum = hash2.sublist(0, 4);

      final addressBytes = Uint8List.fromList([...payload, ...checksum]);

      // Encode to base58
      var num = BigInt.zero;
      for (final b in addressBytes) {
        num = num * BigInt.from(256) + BigInt.from(b);
      }

      final sb = StringBuffer();
      while (num > BigInt.zero) {
        final rem = (num % BigInt.from(58)).toInt();
        num = num ~/ BigInt.from(58);
        sb.write(alphabet[rem]);
      }

      // Add leading '1' for each leading zero byte
      for (final b in addressBytes) {
        if (b == 0) {
          sb.write('1');
        } else {
          break;
        }
      }

      return sb.toString().split('').reversed.join();
    } catch (_) {
      return null;
    }
  }
}
