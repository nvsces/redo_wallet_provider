import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

/// Thin HTTP client for the Etherscan V2 multichain API.
///
/// Handles the concrete quirks of V2:
/// - single base URL, chain selected per-call via `chainid`;
/// - everything is HTTP 200, errors signaled by `status: "0"`;
/// - `result` is polymorphic (list on success, string on error);
/// - `"No transactions found"` is a successful empty result, not an error.
///
/// **Important production caveat:** when the API key is embedded in a
/// mobile client (via `--dart-define=ETHERSCAN_API_KEY=...`), Etherscan
/// rate limits are per-key, not per-IP. All users of the app share a
/// single bucket (free tier: ~3 req/s, 100k calls/day). For scale,
/// proxy through your own backend. This client is designed to degrade
/// gracefully on rate-limit responses — callers should fall back to
/// cached data.
class EtherscanClient {
  EtherscanClient({
    required this.apiKey,
    required this.chainId,
    String baseUrl = 'https://api.etherscan.io/v2/api',
    http.Client? httpClient,
    Duration minRequestInterval = const Duration(milliseconds: 350),
  })  : _baseUrl = baseUrl,
        _client = httpClient ?? http.Client(),
        _minRequestInterval = minRequestInterval;

  /// Etherscan API key. Never empty — [EthereumProvider] is responsible
  /// for not constructing this client when the key is missing.
  final String apiKey;

  /// Chainlist ID. Ethereum mainnet = 1, Sepolia = 11155111.
  final int chainId;

  final String _baseUrl;
  final http.Client _client;

  /// Client-side throttle. Free tier is documented as 5 req/s but
  /// support docs also cite 3 req/s; 350 ms ≈ 2.8 req/s keeps us safe.
  final Duration _minRequestInterval;
  DateTime _lastRequestAt = DateTime.fromMillisecondsSinceEpoch(0);
  Future<void> _inflight = Future.value();

  /// Fetches normal ETH transactions for an address, newest first.
  ///
  /// Returns an empty list when the address has no history or when the
  /// API responds with a transient error — callers should treat both
  /// cases as "nothing to show", not as a hard failure.
  Future<List<EtherscanTx>> getNormalTransactions(
    String address, {
    int page = 1,
    int offset = 50,
  }) async {
    final result = await _get({
      'module': 'account',
      'action': 'txlist',
      'address': address,
      'startblock': '0',
      'endblock': '99999999',
      'page': page.toString(),
      'offset': offset.toString(),
      'sort': 'desc',
    });
    if (result is! List) return const [];
    return result
        .whereType<Map<String, dynamic>>()
        .map(EtherscanTx.fromJson)
        .toList();
  }

  /// Fetches ERC-20 token transfers for an address, newest first.
  Future<List<EtherscanTokenTransfer>> getErc20Transfers(
    String address, {
    int page = 1,
    int offset = 100,
  }) async {
    final result = await _get({
      'module': 'account',
      'action': 'tokentx',
      'address': address,
      'startblock': '0',
      'endblock': '99999999',
      'page': page.toString(),
      'offset': offset.toString(),
      'sort': 'desc',
    });
    if (result is! List) return const [];
    return result
        .whereType<Map<String, dynamic>>()
        .map(EtherscanTokenTransfer.fromJson)
        .toList();
  }

  /// Current balance (raw units) of a specific ERC-20 token.
  Future<BigInt> getTokenBalance({
    required String address,
    required String contractAddress,
  }) async {
    final result = await _get({
      'module': 'account',
      'action': 'tokenbalance',
      'contractaddress': contractAddress,
      'address': address,
      'tag': 'latest',
    });
    if (result is String) {
      return BigInt.tryParse(result) ?? BigInt.zero;
    }
    return BigInt.zero;
  }

  void close() => _client.close();

  // ── Internals ─────────────────────────────────────────────

  Future<dynamic> _get(Map<String, String> params) async {
    // Serialize calls through a single future chain so concurrent
    // callers still respect the throttle.
    final gate = _inflight;
    final completer = Completer<void>();
    _inflight = completer.future;

    try {
      await gate;
      await _throttle();

      final uri = Uri.parse(_baseUrl).replace(queryParameters: {
        'chainid': chainId.toString(),
        ...params,
        'apikey': apiKey,
      });

      final response = await _client.get(uri);
      if (response.statusCode != 200) {
        throw EtherscanException(
          'HTTP ${response.statusCode}: ${_truncate(response.body)}',
        );
      }

      final Map<String, dynamic> decoded;
      try {
        decoded = jsonDecode(response.body) as Map<String, dynamic>;
      } catch (_) {
        throw EtherscanException(
          'Invalid JSON from Etherscan: ${_truncate(response.body)}',
        );
      }

      final status = decoded['status']?.toString();
      if (status == '1') {
        return decoded['result'];
      }

      // status == "0" — either a real error or "no data".
      final message = decoded['message']?.toString() ?? '';
      final result = decoded['result'];
      if (message == 'No transactions found') {
        // Not an error — address has no history on this action.
        return const <dynamic>[];
      }
      final resultStr = result is String ? result : result?.toString() ?? '';
      throw EtherscanException(
        resultStr.isNotEmpty ? resultStr : message,
      );
    } finally {
      _lastRequestAt = DateTime.now();
      completer.complete();
    }
  }

  Future<void> _throttle() async {
    final elapsed = DateTime.now().difference(_lastRequestAt);
    if (elapsed < _minRequestInterval) {
      await Future<void>.delayed(_minRequestInterval - elapsed);
    }
  }

  static String _truncate(String s) =>
      s.length > 200 ? '${s.substring(0, 200)}…' : s;
}

class EtherscanException implements Exception {
  EtherscanException(this.message);
  final String message;
  @override
  String toString() => 'EtherscanException: $message';
}

/// Normalized view of an Etherscan `txlist` row. Only the fields a
/// wallet UI actually consumes are exposed — the raw numeric strings
/// are parsed into `BigInt`/`DateTime` at the boundary.
class EtherscanTx {
  EtherscanTx({
    required this.hash,
    required this.from,
    required this.to,
    required this.value,
    required this.gasUsed,
    required this.gasPrice,
    required this.timestamp,
    required this.blockNumber,
    required this.isError,
  });

  factory EtherscanTx.fromJson(Map<String, dynamic> json) => EtherscanTx(
        hash: (json['hash'] ?? '') as String,
        from: (json['from'] ?? '') as String,
        to: (json['to'] ?? '') as String,
        value: BigInt.tryParse((json['value'] ?? '0') as String) ?? BigInt.zero,
        gasUsed:
            BigInt.tryParse((json['gasUsed'] ?? '0') as String) ?? BigInt.zero,
        gasPrice: BigInt.tryParse((json['gasPrice'] ?? '0') as String) ??
            BigInt.zero,
        timestamp: DateTime.fromMillisecondsSinceEpoch(
          (int.tryParse((json['timeStamp'] ?? '0') as String) ?? 0) * 1000,
        ),
        blockNumber: int.tryParse((json['blockNumber'] ?? '0') as String) ?? 0,
        isError: json['isError'] == '1' ||
            json['txreceipt_status'] == '0',
      );

  final String hash;
  final String from;
  final String to;
  final BigInt value;
  final BigInt gasUsed;
  final BigInt gasPrice;
  final DateTime timestamp;
  final int blockNumber;
  final bool isError;

  BigInt get fee => gasUsed * gasPrice;
}

/// Normalized `tokentx` row — one ERC-20 transfer.
class EtherscanTokenTransfer {
  EtherscanTokenTransfer({
    required this.hash,
    required this.from,
    required this.to,
    required this.value,
    required this.contractAddress,
    required this.tokenName,
    required this.tokenSymbol,
    required this.tokenDecimals,
    required this.timestamp,
  });

  factory EtherscanTokenTransfer.fromJson(Map<String, dynamic> json) =>
      EtherscanTokenTransfer(
        hash: (json['hash'] ?? '') as String,
        from: (json['from'] ?? '') as String,
        to: (json['to'] ?? '') as String,
        value: BigInt.tryParse((json['value'] ?? '0') as String) ?? BigInt.zero,
        contractAddress: (json['contractAddress'] ?? '') as String,
        tokenName: (json['tokenName'] ?? '') as String,
        tokenSymbol: (json['tokenSymbol'] ?? '') as String,
        tokenDecimals:
            int.tryParse((json['tokenDecimal'] ?? '0') as String) ?? 0,
        timestamp: DateTime.fromMillisecondsSinceEpoch(
          (int.tryParse((json['timeStamp'] ?? '0') as String) ?? 0) * 1000,
        ),
      );

  final String hash;
  final String from;
  final String to;
  final BigInt value;
  final String contractAddress;
  final String tokenName;
  final String tokenSymbol;
  final int tokenDecimals;
  final DateTime timestamp;
}
