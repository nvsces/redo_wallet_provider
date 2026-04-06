import 'dart:typed_data';

import 'package:redo_wallet_provider/src/core/json_rpc.dart';
import 'package:redo_wallet_provider/src/core/provider.dart';

/// Ethereum JSON-RPC провайдер.
///
/// Работает с любой EVM-совместимой сетью:
/// Ethereum, Polygon, Arbitrum, Optimism, BSC, Base...
class EthereumProvider implements BlockchainProvider {
  final JsonRpcClient _rpc;
  final String _network;
  final String symbol;
  final int decimals;

  EthereumProvider({
    required String rpcUrl,
    String network = 'ethereum',
    this.symbol = 'ETH',
    this.decimals = 18,
    Map<String, String> headers = const {},
  })  : _rpc = JsonRpcClient(url: rpcUrl, headers: headers),
        _network = network;

  /// Популярные пресеты.
  factory EthereumProvider.mainnet({String? rpcUrl}) => EthereumProvider(
        rpcUrl: rpcUrl ?? 'https://ethereum-rpc.publicnode.com',
        network: 'ethereum-mainnet',
      );

  factory EthereumProvider.sepolia({String? rpcUrl}) => EthereumProvider(
        rpcUrl: rpcUrl ?? 'https://rpc.sepolia.org',
        network: 'ethereum-sepolia',
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

  @override
  String get network => _network;

  @override
  Future<Balance> getBalance(String address) async {
    final result = await _rpc.call('eth_getBalance', [address, 'latest']);
    final amount = BigInt.parse(result as String);
    return Balance(amount: amount, decimals: decimals, symbol: symbol);
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
      amount: BigInt.parse(map['value'] as String? ?? '0x0'),
      fee: _calculateFee(map, receipt as Map<String, dynamic>?),
      blockNumber: map['blockNumber'] != null ? int.parse(map['blockNumber'] as String) : null,
    );
  }

  @override
  Future<int> getBlockNumber() async {
    final result = await _rpc.call('eth_blockNumber');
    return int.parse(result as String);
  }

  // ── Ethereum-специфичные методы ──

  /// Получить nonce (кол-во транзакций) для адреса.
  Future<int> getNonce(String address) async {
    final result = await _rpc.call('eth_getTransactionCount', [address, 'latest']);
    return int.parse(result as String);
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
    return BigInt.parse(result as String);
  }

  /// Получить текущий gas price (legacy).
  Future<BigInt> getGasPrice() async {
    final result = await _rpc.call('eth_gasPrice');
    return BigInt.parse(result as String);
  }

  /// Получить EIP-1559 fee data.
  Future<({BigInt baseFee, BigInt priorityFee})> getFeeData() async {
    final block = await _rpc.call('eth_getBlockByNumber', ['latest', false]);
    final baseFee = BigInt.parse((block as Map)['baseFeePerGas'] as String? ?? '0x0');

    final priorityFee = await _rpc.call('eth_maxPriorityFeePerGas');
    return (
      baseFee: baseFee,
      priorityFee: BigInt.parse(priorityFee as String),
    );
  }

  /// Получить chain ID.
  Future<int> getChainId() async {
    final result = await _rpc.call('eth_chainId');
    return int.parse(result as String);
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
    return BigInt.parse(result);
  }

  BigInt _calculateFee(Map<String, dynamic> tx, Map<String, dynamic>? receipt) {
    if (receipt == null) return BigInt.zero;
    final gasUsed = BigInt.parse(receipt['gasUsed'] as String? ?? '0x0');
    final gasPrice = BigInt.parse(tx['gasPrice'] as String? ?? '0x0');
    return gasUsed * gasPrice;
  }

  void close() => _rpc.close();
}
