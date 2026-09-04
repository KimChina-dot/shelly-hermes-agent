import 'providers.dart';

/// Rewrites the chat/completions JSON body right before it is sent. Used to
/// flip provider-specific web-search switches without the gateway knowing
/// about any vendor.
typedef RequestBodyDecorator = Map<String, dynamic> Function(
    Map<String, dynamic> body);

/// Builds the decorator for the given model config, or null when web search
/// is off / unsupported — in which case the request body passes through
/// untouched.
RequestBodyDecorator? webSearchBodyDecorator({
  required bool enabled,
  required String baseUrl,
}) {
  if (!enabled) return null;
  switch (webSearchSupportFor(baseUrl)) {
    case WebSearchSupport.none:
      return null;
    case WebSearchSupport.pluginTool:
      return (body) {
        final existing = body['tools'];
        final tools = [
          if (existing is List)
            for (final entry in existing)
              if (entry is Map<String, dynamic>) entry,
          // 智谱服务端搜索插件:与 function tools 同列,由服务端执行检索。
          {
            'type': 'web_search',
            'web_search': {'enable': true},
          },
        ];
        return {...body, 'tools': tools};
      };
    case WebSearchSupport.modelSuffix:
      return (body) {
        final model = body['model'] as String? ?? '';
        if (model.endsWith(':online')) return body;
        return {...body, 'model': '$model:online'};
      };
  }
}
