// Desktop sidecar CLI: hosts stdio MCP servers and exposes them to the phone
// app over LAN HTTP. Not part of the Flutter build; run with
// `dart run tool/mcp_bridge.dart --config bridge.json --token <secret>`.
// ignore_for_file: avoid_print
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:shelly_hermes/core/mcp/bridge_server.dart';

Future<void> main(List<String> arguments) async {
  int port = 8766;
  String token = '';
  String? configPath;

  for (var i = 0; i < arguments.length; i++) {
    final arg = arguments[i];
    switch (arg) {
      case '--port':
        port = int.tryParse(_value(arguments, ++i, arg)) ?? 8766;
      case '--token':
        token = _value(arguments, ++i, arg);
      case '--config':
        configPath = _value(arguments, ++i, arg);
      case '--help':
      case '-h':
        print(_usage);
        return;
      default:
        print('未知参数:$arg');
        print(_usage);
        exitCode = 64;
        return;
    }
  }

  if (configPath == null) {
    print('缺少 --config <json 文件>(stdio 服务器定义数组)');
    print(_usage);
    exitCode = 64;
    return;
  }

  List<dynamic> rawServers;
  try {
    rawServers = jsonDecode(File(configPath).readAsStringSync()) as List<dynamic>;
  } catch (error) {
    print('无法读取配置文件 $configPath:$error');
    exitCode = 66;
    return;
  }

  if (token.isEmpty) {
    token = _randomToken();
    print('未提供 --token,已生成随机令牌:$token');
  }

  final config = BridgeConfig.fromJsonList(rawServers, token: token);
  if (config.servers.isEmpty) {
    print('配置文件中没有 stdio 服务器定义');
    exitCode = 65;
    return;
  }

  final server = BridgeServer(config: config);
  try {
    await server.start(port: port);
  } catch (error) {
    print('桥接服务启动失败:$error');
    exitCode = 71;
    return;
  }

  print('Shelly MCP 桥接服务已启动 (端口 ${server.port})');
  print('LAN 地址:');
  final interfaces = await NetworkInterface.list();
  for (final interface in interfaces) {
    for (final address in interface.addresses) {
      if (address.type == InternetAddressType.IPv4 &&
          !address.isLoopback) {
        print('  http://${address.address}:${server.port}');
      }
    }
  }
  for (final def in config.servers) {
    print('  stdio 服务器 ${def.id} (${def.name}): ${def.command}');
  }
  print('Ctrl+C 停止。');

  _handleTermination(() async {
    print('正在停止桥接服务…');
    await server.stop();
    exit(0);
  });
}

String _value(List<String> arguments, int index, String flag) {
  if (index >= arguments.length) {
    print('参数 $flag 缺少值');
    exit(64);
  }
  return arguments[index];
}

void _handleTermination(Future<void> Function() shutdown) {
  try {
    ProcessSignal.sigint.watch().listen((_) {
      shutdown();
    });
  } on SignalException {
    // No signal handling available (e.g. some CI sandboxes); the process can
    // still be terminated externally.
  }
  try {
    ProcessSignal.sigterm.watch().listen((_) {
      shutdown();
    });
  } on SignalException {
    // sigterm watch is unsupported on Windows — ignore.
  }
}

String _randomToken() {
  final random = Random.secure();
  final bytes = List<int>.generate(16, (_) => random.nextInt(256));
  return base64Url.encode(bytes).replaceAll('=', '');
}

const _usage = '''
用法: dart run tool/mcp_bridge.dart --config <json 文件> [--port 8766] [--token <令牌>]

--config   JSON 文件,内容为 stdio 服务器定义数组:
             [{"id":"filesys","name":"文件系统","command":"node","args":["fs-mcp.js"],"env":{}}]
--port     HTTP 监听端口 (默认 8766)
--token    访问令牌;省略时自动生成并打印
''';
