import 'dart:typed_data';

import 'package:redo_wallet_provider/src/core/json_rpc.dart';
import 'package:redo_wallet_provider/src/core/provider.dart';
import 'package:redo_wallet_provider/src/ethereum/etherscan_client.dart';

/// Ethereum JSON-RPC провайдер.
///
/// Работает с любой EVM-совместимой сетью:
/// Ethereum, Polygon, Arbitrum, Optimism, BSC, Base...
///
/// History and ERC-20 discovery require an [EtherscanClient] — without
/// one, [getTransactionHistory] and [getErc20Balances] return empty.
class EthereumProvider implements BlockchainProvider {
  final JsonRpcClient _rpc;
  final String _network;
  final String symbol;
  final int decimals;
  final EtherscanClient? _etherscan;

  EthereumProvider({
    required String rpcUrl,
    String network = 'ethereum',
    this.symbol = 'ETH',
    this.decimals = 18,
    Map<String, String> headers = const {},
    EtherscanClient? etherscanClient,
  })  : _rpc = JsonRpcClient(url: rpcUrl, headers: headers),
        _network = network,
        _etherscan = etherscanClient;

  /// Популярные пресеты.
  factory EthereumProvider.mainnet({
    String? rpcUrl,
    EtherscanClient? etherscanClient,
  }) =>
      EthereumProvider(
        rpcUrl: rpcUrl ?? 'https://ethereum-rpc.publicnode.com',
        network: 'ethereum-mainnet',
        etherscanClient: etherscanClient,
      );

  factory EthereumProvider.sepolia({
    String? rpcUrl,
    EtherscanClient? etherscanClient,
  }) =>
      EthereumProvider(
        // publicnode is the same infra we use for mainnet; the legacy
        // rpc.sepolia.org endpoint frequently times out.
        rpcUrl: rpcUrl ?? 'https://ethereum-sepolia-rpc.publicnode.com',
        network: 'ethereum-sepolia',
        etherscanClient: etherscanClient,
      );

  factory EthereumProvider.polygon({String? rpcUrl}) => EthereumProvider(
        rpcUrl: rpcUrl ?? 'https://polygon-rpc.com',
        network: 'polygon-mainnet',
        symbol: 'MATIC',
      );

  factory EthereumProvider.bsc({String? rpcUrl}) => EthereumProvider(
        rpcUrl: rpcUrl ?? 'https://bsc-dataseed.binance.org',
        network: 'bsc-mainnet',
        symbol: 'BNB',
      );

  /// Etherscan client, if configured. Exposed so higher layers can
  /// reuse it for ERC-20 discovery without re-constructing it.
  EtherscanClient? get etherscan => _etherscan;

  @override
  String get network => _network;

  @override
  Future<Balance> getBalance(String address) async {
    final result = await _rpc.call('eth_getBalance', [address, 'latest']);
    return Balance(
      amount: _parseHexBigInt(result),
      decimals: decimals,
      symbol: symbol,
    );
  }

  @override
  Future<TxResult> broadcast(Uint8List signedTx) async {
    final hex = '0x${signedTx.map((b) => b.toRadixString(16).padLeft(2, '0')).join()}';
    try {
      final result = await _rpc.call('eth_sendRawTransaction', [hex]);
      return TxResult(hash: result as String, success: true);
    } on JsonRpcException catch (e) {
      return TxResult(hash: '', success: false, error: e.message);
    }
  }

  @override
  Future<TxInfo?> getTransaction(String hash) async {
    final tx = await _rpc.call('eth_getTransactionByHash', [hash]);
    if (tx == null) return null;
    final map = tx as Map<String, dynamic>;

    final receipt = await _rpc.call('eth_getTransactionReceipt', [hash]);
    final status = receipt != null
        ? ((receipt as Map)['status'] == '0x1' ? TxStatus.confirmed : TxStatus.failed)
        : TxStatus.pending;

    return TxInfo(
      hash: hash,
      status: status,
      from: map['from'] as String? ?? '',
      to: map['to'] as String? ?? '',
      amount: _parseHexBigInt(map['value']),
      fee: _calculateFee(map, receipt as Map<String, dynamic>?),
      blockNumber: map['blockNumber'] != null
          ? _parseHexInt(map['blockNumber'])
          : null,
    );
  }

  @override
  Future<int> getBlockNumber() async {
    final result = await _rpc.call('eth_blockNumber');
    return _parseHexInt(result);
  }

  @override
  Future<List<TxInfo>> getTransactionHistory(String address, {int limit = 20}) async {
    // Ethereum JSON-RPC has no history endpoint. We use Etherscan V2
    // as the indexer; without a configured client we honestly return
    // empty rather than silently making something up.
    final etherscan = _etherscan;
    if (etherscan == null) return const [];

    try {
      final rows = await etherscan.getNormalTransactions(
        address,
        offset: limit,
      );
      return rows
          .map((r) => TxInfo(
                hash: r.hash,
                status: r.isError ? TxStatus.failed : TxStatus.confirmed,
                from: r.from,
                to: r.to,
                amount: r.value,
                fee: r.fee,
                blockNumber: r.blockNumber,
                timestamp: r.timestamp,
              ))
          .toList();
    } catch (_) {
      // Indexer failure shouldn't bring down the wallet. Callers
      // already fall back to cached history.
      return const [];
    }
  }

  // ── Ethereum-специфичные методы ──

  /// Получить nonce (кол-во транзакций) для адреса.
  Future<int> getNonce(String address) async {
    final result =
        await _rpc.call('eth_getTransactionCount', [address, 'latest']);
    return _parseHexInt(result);
  }

  /// Оценить gas для транзакции.
  Future<BigInt> estimateGas({
    required String from,
    required String to,
    BigInt? value,
    String? data,
  }) async {
    final params = <String, dynamic>{'from': from, 'to': to};
    if (value != null) params['value'] = '0x${value.toRadixString(16)}';
    if (data != null) params['data'] = data;
    final result = await _rpc.call('eth_estimateGas', [params]);
    return _parseHexBigInt(result);
  }

  /// Получить текущий gas price (legacy).
  Future<BigInt> getGasPrice() async {
    final result = await _rpc.call('eth_gasPrice');
    return _parseHexBigInt(result);
  }

  /// Получить EIP-1559 fee data.
  Future<({BigInt baseFee, BigInt priorityFee})> getFeeData() async {
    final block = await _rpc.call('eth_getBlockByNumber', ['latest', false]);
    final baseFee = _parseHexBigInt((block as Map)['baseFeePerGas']);

    final priorityFee = await _rpc.call('eth_maxPriorityFeePerGas');
    return (
      baseFee: baseFee,
      priorityFee: _parseHexBigInt(priorityFee),
    );
  }

  /// Получить chain ID.
  Future<int> getChainId() async {
    final result = await _rpc.call('eth_chainId');
    return _parseHexInt(result);
  }

  /// Вызвать read-only метод контракта (eth_call).
  Future<String> ethCall({
    required String to,
    required String data,
    String? from,
  }) async {
    final params = <String, dynamic>{'to': to, 'data': data};
    if (from != null) params['from'] = from;
    final result = await _rpc.call('eth_call', [params, 'latest']);
    return result as String;
  }

  /// Получить баланс ERC-20 токена.
  Future<BigInt> getTokenBalance(String address, String tokenContract) async {
    // balanceOf(address) = 0x70a08231 + address padded to 32 bytes
    final paddedAddress = address.replaceFirst('0x', '').padLeft(64, '0');
    final data = '0x70a08231$paddedAddress';
    final result = await ethCall(to: tokenContract, data: data);
    return _parseHexBigInt(result);
  }

  /// Discover ERC-20 tokens the address currently holds.
  ///
  /// Uses the free-tier Etherscan workflow: walk `tokentx` to collect
  /// every contract the address has ever transferred, then query each
  /// contract's current balance via `tokenbalance`. Returns the subset
  /// with non-zero balance, ordered by symbol for stable UI.
  ///
  /// Returns empty when no Etherscan client is configured. Any
  /// per-token balance failure is skipped rather than propagated so
  /// one bad contract can't hide the rest of the portfolio.
  Future<List<TokenBalanceInfo>> getErc20Balances(
    String address, {
    int maxTokens = 40,
  }) async {
    final etherscan = _etherscan;
    if (etherscan == null) return const [];

    final List<EtherscanTokenTransfer> transfers;
    try {
      transfers = await etherscan.getErc20Transfers(address, offset: 500);
    } catch (_) {
      return const [];
    }

    // Dedupe by contract, preferring the most recent metadata row.
    final seen = <String, EtherscanTokenTransfer>{};
    for (final t in transfers) {
      final key = t.contractAddress.toLowerCase();
      if (key.isEmpty) continue;
      seen.putIfAbsent(key, () => t);
      if (seen.length >= maxTokens) break;
    }

    final balances = <TokenBalanceInfo>[];
    for (final entry in seen.values) {
      try {
        final raw = await etherscan.getTokenBalance(
          address: address,
          contractAddress: entry.contractAddress,
        );
        if (raw == BigInt.zero) continue;
        balances.add(TokenBalanceInfo(
          contractAddress: entry.contractAddress,
          walletAddress: address,
          balance: raw,
          symbol: entry.tokenSymbol,
          name: entry.tokenName,
          decimals: entry.tokenDecimals,
        ));
      } catch (_) {
        // Ignore individual token lookup failures.
      }
    }

    balances.sort((a, b) => a.symbol.compareTo(b.symbol));
    return balances;
  }

  BigInt _calculateFee(Map<String, dynamic> tx, Map<String, dynamic>? receipt) {
    if (receipt == null) return BigInt.zero;
    final gasUsed = _parseHexBigInt(receipt['gasUsed']);
    final gasPrice = _parseHexBigInt(tx['gasPrice']);
    return gasUsed * gasPrice;
  }

  void close() => _rpc.close();
}

/// Parses an Ethereum JSON-RPC hex-quantity like `"0x2386f26fc10000"` into
/// a [BigInt]. Accepts `null`, empty string, and bare/prefixed hex. Decimal
/// input is tolerated as a fallback so we don't regress if a node ever
/// returns a non-standard payload.
BigInt _parseHexBigInt(Object? raw) {
  if (raw == null) return BigInt.zero;
  var s = raw.toString().trim();
  if (s.isEmpty) return BigInt.zero;
  if (s.startsWith('0x') || s.startsWith('0X')) {
    s = s.substring(2);
    if (s.isEmpty) return BigInt.zero;
    return BigInt.parse(s, radix: 16);
  }
  return BigInt.parse(s);
}

/// Same as [_parseHexBigInt] but for values that fit in a Dart [int]
/// (block numbers, nonces, chain IDs).
int _parseHexInt(Object? raw) {
  if (raw == null) return 0;
  var s = raw.toString().trim();
  if (s.isEmpty) return 0;
  if (s.startsWith('0x') || s.startsWith('0X')) {
    s = s.substring(2);
    if (s.isEmpty) return 0;
    return int.parse(s, radix: 16);
  }
  return int.parse(s);
}
