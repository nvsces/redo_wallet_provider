import 'dart:convert';

import 'package:http/http.dart' as http;

/// Базовый JSON-RPC клиент.
/// Используется Ethereum, Solana и другими JSON-RPC блокчейнами.
class JsonRpcClient {
  final String url;
  final Map<String, String> headers;
  final http.Client _client;
  int _requestId = 0;

  JsonRpcClient({
    required this.url,
    this.headers = const {},
    http.Client? client,
  }) : _client = client ?? http.Client();

  /// Отправить JSON-RPC запрос.
  Future<dynamic> call(String method, [List<dynamic> params = const []]) async {
    _requestId++;
    final body = jsonEncode({
      'jsonrpc': '2.0',
      'id': _requestId,
      'method': method,
      'params': params,
    });

    final response = await _client.post(
      Uri.parse(url),
      headers: {'Content-Type': 'application/json', ...headers},
      body: body,
    );

    if (response.statusCode != 200) {
      throw JsonRpcException(
        code: response.statusCode,
        message: 'HTTP ${response.statusCode}: ${response.body.length > 200 ? response.body.substring(0, 200) : response.body}',
      );
    }

    final Map<String, dynamic> json;
    try {
      json = jsonDecode(response.body) as Map<String, dynamic>;
    } catch (e) {
      throw JsonRpcException(code: -1, message: 'Invalid JSON: ${response.body.length > 200 ? response.body.substring(0, 200) : response.body}');
    }

    if (json.containsKey('error')) {
      final error = json['error'];
      throw JsonRpcException(
        code: error['code'] as int? ?? -1,
        message: error['message'] as String? ?? 'Unknown error',
      );
    }

    return json['result'];
  }

  void close() => _client.close();
}

class JsonRpcException implements Exception {
  final int code;
  final String message;

  const JsonRpcException({required this.code, required this.message});

  @override
  String toString() => 'JsonRpcException($code): $message';
}
