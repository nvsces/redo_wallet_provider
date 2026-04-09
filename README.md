# redo_wallet_provider

Multi-chain blockchain network providers for Dart. One small, uniform API for
querying balances, fetching transaction history, and broadcasting signed
transactions across **Ethereum (and EVMs), TON, Solana, Bitcoin, and Tron**.

This package is the network layer of a wallet stack:

- It does **not** generate keys, derive addresses, or sign transactions —
  that lives in `redo_wallet_core`.
- It **does** talk to nodes and indexers (JSON-RPC, REST, Etherscan,
  toncenter, Blockstream, TronGrid) and normalize their responses into a
  common shape.

## Features

- Unified [`BlockchainProvider`](lib/src/core/provider.dart) interface across
  all chains: `getBalance`, `getTransaction`, `getTransactionHistory`,
  `getBlockNumber`, `broadcast`.
- Common value types: `Balance`, `TxInfo`, `TxResult`, `TxStatus`,
  `TokenBalanceInfo`.
- **Ethereum / EVM** — JSON-RPC client with mainnet/Sepolia/Polygon/BSC
  presets, gas estimation, EIP-1559 fee data, ERC-20 balance reads, and
  optional Etherscan-backed history + ERC-20 token discovery.
- **TON** — toncenter v2/v3 client with jetton balance support.
- **Solana** — JSON-RPC client (mainnet/devnet).
- **Bitcoin** — Blockstream / mempool.space REST client with UTXO listing
  and transaction history.
- **Tron** — TronGrid client with bandwidth/energy resource queries and
  TRC-20 support.
- Shared lightweight [`JsonRpcClient`](lib/src/core/json_rpc.dart) used by
  the EVM and Solana providers.

## Installation

This package is path-published inside the wallet monorepo. Add it from your
app's `pubspec.yaml`:

```yaml
dependencies:
  redo_wallet_provider:
    path: ../redo_wallet_provider
```

It depends on `redo_wallet_core` (also path-resolved) for shared types.

## Quick start

```dart
import 'package:redo_wallet_provider/redo_wallet_provider.dart';

Future<void> main() async {
  final eth = EthereumProvider.mainnet();

  final balance = await eth.getBalance('0xd8dA6BF26964aF9D7eEd9e03E53415D37aA96045');
  print(balance); // 1.234567 ETH

  final block = await eth.getBlockNumber();
  print('head: $block');

  eth.close();
}
```

Every provider implements the same interface, so swapping chains is a
matter of constructing a different provider:

```dart
final providers = <BlockchainProvider>[
  EthereumProvider.mainnet(),
  TonProvider.mainnet(),
  SolanaProvider.mainnet(),
  BitcoinProvider.mainnet(),
  TronProvider.mainnet(),
];

for (final p in providers) {
  print('${p.network}: head=${await p.getBlockNumber()}');
}
```

## Core types

All providers normalize results into the same shapes:

```dart
class Balance {
  final BigInt amount;     // raw, in the smallest unit
  final int decimals;
  final String symbol;
  double get asDouble;     // amount / 10^decimals
}

enum TxStatus { pending, confirmed, failed, unknown }

class TxInfo {
  final String hash;
  final TxStatus status;
  final String from;
  final String to;
  final BigInt amount;     // smallest unit
  final BigInt fee;        // smallest unit
  final int? blockNumber;
  final DateTime? timestamp;
  final String? comment;   // chain-specific (e.g. TON memo)
}

class TxResult {
  final String hash;
  final bool success;
  final String? error;
}

class TokenBalanceInfo {
  final String contractAddress;
  final String walletAddress;
  final BigInt balance;
  final String symbol;
  final String name;
  final int decimals;
}
```

See [`lib/src/core/provider.dart`](lib/src/core/provider.dart) for the full
interface.

## Per-chain notes

### Ethereum (and EVMs)

```dart
// Read-only usage with public RPC.
final eth = EthereumProvider.mainnet();

// History + ERC-20 discovery require an Etherscan API key.
final eth = EthereumProvider.mainnet(
  etherscanClient: EtherscanClient(apiKey: 'YOUR_KEY'),
);

final txs = await eth.getTransactionHistory('0xabc...', limit: 25);
final tokens = await eth.getErc20Balances('0xabc...');
```

EVM-specific helpers on `EthereumProvider`:

- `getNonce(address)` — `eth_getTransactionCount`
- `estimateGas({from, to, value, data})`
- `getGasPrice()` — legacy `eth_gasPrice`
- `getFeeData()` — `(baseFee, priorityFee)` for EIP-1559
- `getChainId()`
- `ethCall({to, data, from})` — read-only contract call
- `getErc20Balance(tokenContract, address)` — single-token balance
- `getErc20Balances(address)` — full portfolio (Etherscan-backed)

Built-in presets: `mainnet`, `sepolia`, `polygon`, `bsc`. For Arbitrum,
Optimism, Base, etc., construct directly with the appropriate `rpcUrl`,
`network`, and `symbol`.

> History and ERC-20 token discovery require an `EtherscanClient`. Without
> one, `getTransactionHistory` and `getErc20Balances` return an empty list
> rather than throwing — wallets typically fall back to cached data.

### TON

```dart
final ton = TonProvider.mainnet(apiKey: 'OPTIONAL_TONCENTER_KEY');

final balance = await ton.getBalance('EQ...');
final history = await ton.getTransactionHistory('EQ...');
```

Backed by toncenter v2 (account/transaction queries) and v3 (jetton
endpoints). An API key is optional but strongly recommended for production
to avoid rate limits.

### Solana

```dart
final sol = SolanaProvider.mainnet();
final balance = await sol.getBalance('9xQeWvG816bUx9EPa2v7vXk...');
```

Pure JSON-RPC against `api.mainnet-beta.solana.com` (or `devnet`). Pass a
custom `rpcUrl` for paid providers (Helius, QuickNode, etc.).

### Bitcoin

```dart
final btc = BitcoinProvider.mainnet();           // blockstream.info
// or
final btc = BitcoinProvider.mempool();           // mempool.space
final btc = BitcoinProvider.testnet();           // blockstream testnet

final balance = await btc.getBalance('bc1q...');
final utxos = await btc.getUtxos('bc1q...');
final history = await btc.getTransactionHistory('bc1q...');
```

Uses the Esplora REST API. `getTransactionHistory` returns the most recent
transactions newest-first; for the viewer's perspective `TxInfo.amount` is
the absolute net flow and `TxInfo.fee` is attributed only when the viewer
actually paid it.

### Tron

```dart
final tron = TronProvider.mainnet();
final balance = await tron.getBalance('TR7...');
final res = await tron.getResources('TR7...');   // bandwidth + energy
```

Backed by TronGrid. Surfaces account resources (bandwidth + energy) which
wallets typically need before constructing a TRC-20 transfer.

## Sending a transaction

This package broadcasts already-signed transactions; signing happens in
`redo_wallet_core`:

```dart
final signed = await wallet.signTransfer(...);   // from redo_wallet_core
final result = await provider.broadcast(signed);

if (result.success) {
  print('sent: ${result.hash}');
} else {
  print('failed: ${result.error}');
}
```

`broadcast` never throws on chain-level rejection — it returns `TxResult`
with `success: false` and an `error` message. Network/transport errors
still surface as exceptions.

## Error handling

- Transport / HTTP errors: thrown as `Exception` (or `JsonRpcException`
  for the EVM/Solana JSON-RPC path).
- Chain rejections during `broadcast`: returned as `TxResult(success: false)`.
- Indexer (Etherscan, Blockstream) failures inside history / token
  discovery: swallowed and returned as empty lists, so a flaky indexer
  cannot break a wallet's main UI. Callers are expected to fall back to
  cached data.

## Resource management

EVM and Solana providers hold an internal `JsonRpcClient` (which owns an
`http.Client`). Call `close()` when you're done:

```dart
final eth = EthereumProvider.mainnet();
try {
  // ... use eth ...
} finally {
  eth.close();
}
```

TON, Bitcoin, and Tron providers accept an optional `http.Client` for
injection during tests.

## Project layout

```
lib/
  redo_wallet_provider.dart      // public exports
  src/
    core/
      provider.dart              // BlockchainProvider + value types
      json_rpc.dart              // shared JSON-RPC client
    ethereum/
      ethereum_provider.dart
      etherscan_client.dart
    ton/ton_provider.dart
    solana/solana_provider.dart
    bitcoin/bitcoin_provider.dart
    tron/tron_provider.dart
```

## License

MIT — see [LICENSE](LICENSE).
