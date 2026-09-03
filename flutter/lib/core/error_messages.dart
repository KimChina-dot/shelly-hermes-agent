import 'gateway/openai_gateway.dart';

/// Error copy mapping (V2.1 PHASE 28): turns raw gateway / transport
/// exceptions into one-line Chinese explanations a non-engineer can act
/// on. The trailing detail (status or raw text) stays appended so bug
/// reports keep their signal.
String humanizeAgentError(Object? error) {
  if (error == null) return '未知错误';

  // Gateway failures: status code decides the copy; body sniffing refines
  // the common provider-side shapes.
  if (error is GatewayException) {
    final status = error.statusCode;
    final body = (error.body ?? '').toLowerCase();
    switch (status) {
      case 400:
        if (body.contains('max_tokens') || body.contains('context length')) {
          return '上下文超出模型限制,试试开一个新会话或换长上下文模型';
        }
        if (body.contains('model')) {
          return '模型名称不正确,请检查「我的」页或模型选择器中的模型 ID';
        }
        return '请求被接口拒绝(400),请检查接口地址与模型配置';
      case 401:
        return 'API 密钥无效或已过期,请到「我的」页更新密钥';
      case 402:
        return '账户余额不足,请充值后重试';
      case 403:
        return '没有访问该模型的权限(403),请检查密钥对应的套餐';
      case 404:
        return '接口地址不存在(404),地址通常以 /v1 结尾';
      case 408:
        return '请求超时,请检查网络后重试';
      case 413:
        return '请求体过大,试试开一个新会话缩短上下文';
      case 429:
        return '触发限流(429),请稍等片刻再试,或降低任务频率';
      case 500:
      case 502:
      case 503:
      case 504:
        return '模型服务暂时不可用($status),请稍后重试';
    }
    return status == null
        ? '连接失败:${error.message}'
        : '请求失败($status):${error.message}';
  }

  final text = error.toString();
  // Transport-level failures (SocketException, TimeoutException, …).
  if (text.contains('TimeoutException')) return '连接超时,请检查网络或代理设置';
  if (text.contains('SocketException') ||
      text.contains('Connection refused') ||
      text.contains('Failed host lookup') ||
      text.contains('Network is unreachable')) {
    return '无法连接到模型服务,请检查网络、地址与防火墙设置';
  }
  if (text.contains('HandshakeException')) {
    return '安全连接失败,请确认接口地址支持 HTTPS';
  }
  if (text.contains('FormatException')) return '接口返回了无法解析的内容';
  final brief = text.length <= 120 ? text : '${text.substring(0, 120)}…';
  return '任务失败:$brief';
}
