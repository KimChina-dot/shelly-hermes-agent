import 'package:flutter_test/flutter_test.dart';

import 'package:shelly_hermes/agent/brain/intent_router.dart';
import 'package:shelly_hermes/agent/brain/planner.dart';
import 'package:shelly_hermes/core/agent_core.dart';
import 'package:shelly_hermes/core/models.dart';

/// Gateway stub that replays canned replies and records every request
/// (same scripted pattern as test/core/memory/memory_extractor_test.dart).
class _ScriptedGateway implements ModelGateway {
  _ScriptedGateway(this.replies);

  final List<ModelReply> replies;
  final List<List<AgentMessage>> seenMessages = [];

  @override
  Future<ModelReply> complete(List<AgentMessage> messages) async {
    seenMessages.add(List.of(messages));
    return replies.removeAt(0);
  }
}

class _ThrowingGateway implements ModelGateway {
  @override
  Future<ModelReply> complete(List<AgentMessage> messages) async =>
      throw StateError('gateway down');
}

void main() {
  group('IntentRouter.parseKind', () {
    test('reads a bare label', () {
      final router = IntentRouter(gateway: _ScriptedGateway([]));

      expect(router.parseKind('multiStep'), IntentKind.multiStep);
      expect(router.parseKind('quickAnswer'), IntentKind.quickAnswer);
    });

    test('reads a fenced label', () {
      final router = IntentRouter(gateway: _ScriptedGateway([]));

      expect(router.parseKind('```\nmultiStep\n```'), IntentKind.multiStep);
      expect(
        router.parseKind('```text\nquickAnswer\n```'),
        IntentKind.quickAnswer,
      );
    });

    test('reads a label wrapped in surrounding prose', () {
      final router = IntentRouter(gateway: _ScriptedGateway([]));

      expect(
        router.parseKind('分类结果:multiStep。请按计划执行。'),
        IntentKind.multiStep,
      );
      expect(
        router.parseKind('这个请求很简单,标签是 quickAnswer。'),
        IntentKind.quickAnswer,
      );
    });

    test('is case-insensitive and tolerates surrounding whitespace', () {
      final router = IntentRouter(gateway: _ScriptedGateway([]));

      expect(router.parseKind('  MultiStep \n'), IntentKind.multiStep);
      expect(router.parseKind('QUICKANSWER'), IntentKind.quickAnswer);
    });

    test('invalid, ambiguous and empty replies fall back to quickAnswer',
        () {
      final router = IntentRouter(gateway: _ScriptedGateway([]));

      expect(router.parseKind('我不知道这个请求属于哪一类。'), IntentKind.quickAnswer);
      expect(router.parseKind(''), IntentKind.quickAnswer);
      expect(
        router.parseKind('```json\n{"label": "maybe"}\n```'),
        IntentKind.quickAnswer,
      );
    });
  });

  group('IntentRouter.classify', () {
    test('sends one system+user call and returns the model label',
        () async {
      final gateway = _ScriptedGateway([
        ModelReply(content: 'multiStep'),
      ]);
      final router = IntentRouter(gateway: gateway);

      final kind = await router.classify('把整个仓库升级到 Flutter 3.24');

      expect(kind, IntentKind.multiStep);
      expect(gateway.seenMessages, hasLength(1));
      final prompt = gateway.seenMessages.single;
      expect(prompt, hasLength(2));
      expect(prompt.first.role, MessageRole.system);
      expect(prompt.first.content, contains('quickAnswer'));
      expect(prompt.first.content, contains('multiStep'));
      expect(prompt.last.role, MessageRole.user);
      expect(prompt.last.content, '把整个仓库升级到 Flutter 3.24');
    });

    test('an empty request never reaches the model', () async {
      final gateway = _ScriptedGateway([
        ModelReply(content: 'multiStep'),
      ]);
      final router = IntentRouter(gateway: gateway);

      expect(await router.classify('   '), IntentKind.quickAnswer);
      expect(gateway.seenMessages, isEmpty);
    });

    test('a thrown gateway error resolves to quickAnswer', () async {
      final router = IntentRouter(gateway: _ThrowingGateway());

      expect(await router.classify('帮我写个脚本'), IntentKind.quickAnswer);
    });

    test('an unparseable reply resolves to quickAnswer', () async {
      final gateway = _ScriptedGateway([
        ModelReply(content: '这是一个很复杂的请求,我建议好好规划。'),
      ]);
      final router = IntentRouter(gateway: gateway);

      expect(await router.classify('重构全部测试'), IntentKind.quickAnswer);
    });
  });

  group('Planner.parsePlan', () {
    test('reads a numbered list', () {
      final planner = Planner(gateway: _ScriptedGateway([]));

      expect(
        planner.parsePlan(
          '1. 检查现有依赖\n2. 升级 pubspec 版本\n3. 跑测试确认',
        ),
        ['检查现有依赖', '升级 pubspec 版本', '跑测试确认'],
      );
    });

    test('reads a fenced block', () {
      final planner = Planner(gateway: _ScriptedGateway([]));

      expect(
        planner.parsePlan('```text\n1. 备份数据\n2. 迁移数据库\n3. 验证结果\n```'),
        ['备份数据', '迁移数据库', '验证结果'],
      );
    });

    test('reads plain lines without numbering', () {
      final planner = Planner(gateway: _ScriptedGateway([]));

      expect(
        planner.parsePlan('先读代码\n再改实现\n最后补测试'),
        ['先读代码', '再改实现', '最后补测试'],
      );
    });

    test('strips bullet prefixes and tolerates blank lines', () {
      final planner = Planner(gateway: _ScriptedGateway([]));

      expect(
        planner.parsePlan('- 清理分支\n\n* 更新文档\n· 发布'),
        ['清理分支', '更新文档', '发布'],
      );
    });

    test('prose around a fenced plan prefers the fenced lines', () {
      final planner = Planner(gateway: _ScriptedGateway([]));

      // The prose itself is not step-shaped, so the fenced block wins.
      expect(
        planner.parsePlan(
          '好的,以下是计划:\n```text\n1. 定位问题\n2. 修复\n```\n希望有帮助!',
        ),
        ['定位问题', '修复'],
      );
    });

    test('garbage, empty and stepless replies yield an empty list', () {
      final planner = Planner(gateway: _ScriptedGateway([]));

      expect(planner.parsePlan('我觉得这个问题不需要计划,直接回答即可。'), isEmpty);
      expect(planner.parsePlan(''), isEmpty);
      expect(planner.parsePlan('```\n   \n\n```'), isEmpty);
    });

    test('caps at 8 steps and drops overly long ones', () {
      final planner = Planner(gateway: _ScriptedGateway([]));

      expect(
        planner.parsePlan(
          ['1. 一', '2. 二', '3. 三', '4. 四', '5. 五', '6. 六', '7. 七',
            '8. 八', '9. 九'].join('\n'),
        ).length,
        Planner.maxSteps,
      );
      expect(
        planner.parsePlan('1. ${'长' * 201}\n2. 短步骤\n3. 也短'),
        ['短步骤', '也短'],
      );
    });
  });

  group('Planner.planFor', () {
    test('sends one system+user call and returns the model plan',
        () async {
      final gateway = _ScriptedGateway([
        ModelReply(content: '1. 读取配置\n2. 修改端口\n3. 重启服务'),
      ]);
      final planner = Planner(gateway: gateway);

      final steps = await planner.planFor('把后端端口从 8080 改成 9000');

      expect(steps, ['读取配置', '修改端口', '重启服务']);
      expect(gateway.seenMessages, hasLength(1));
      final prompt = gateway.seenMessages.single;
      expect(prompt, hasLength(2));
      expect(prompt.first.role, MessageRole.system);
      expect(prompt.first.content, contains('3 到 8'));
      expect(prompt.last.content, '把后端端口从 8080 改成 9000');
    });

    test('an empty request never reaches the model', () async {
      final gateway = _ScriptedGateway([
        ModelReply(content: '1. 不该被问到'),
      ]);
      final planner = Planner(gateway: gateway);

      expect(await planner.planFor('  '), isEmpty);
      expect(gateway.seenMessages, isEmpty);
    });

    test('a thrown gateway error resolves to an empty plan', () async {
      final planner = Planner(gateway: _ThrowingGateway());

      expect(await planner.planFor('部署整个集群'), isEmpty);
    });

    test('an unparseable reply resolves to an empty plan', () async {
      final gateway = _ScriptedGateway([
        ModelReply(content: '这个问题没必要规划。'),
      ]);
      final planner = Planner(gateway: gateway);

      expect(await planner.planFor('今天天气怎么样'), isEmpty);
    });
  });

  group('Brain facade', () {
    test('quickAnswer intents skip the planner entirely (one call)',
        () async {
      final gateway = _ScriptedGateway([
        ModelReply(content: 'quickAnswer'),
      ]);
      final brain = Brain(gateway: gateway);

      final decision = await brain.decide('这句话是什么意思?');

      expect(decision.kind, IntentKind.quickAnswer);
      expect(decision.steps, isEmpty);
      expect(gateway.seenMessages, hasLength(1));
    });

    test('multiStep intents add exactly one planning call', () async {
      final gateway = _ScriptedGateway([
        ModelReply(content: 'multiStep'),
        ModelReply(content: '1. 拉取镜像\n2. 更新 compose 文件\n3. 滚动重启'),
      ]);
      final brain = Brain(gateway: gateway);

      final decision = await brain.decide('升级生产环境到新版本');

      expect(decision.kind, IntentKind.multiStep);
      expect(decision.steps, ['拉取镜像', '更新 compose 文件', '滚动重启']);
      expect(gateway.seenMessages, hasLength(2));
    });

    test('fail-open end to end: broken gateway yields a quickAnswer',
        () async {
      final brain = Brain(gateway: _ThrowingGateway());

      final decision = await brain.decide('随便一个请求');

      expect(decision.kind, IntentKind.quickAnswer);
      expect(decision.steps, isEmpty);
    });

    test('fail-open planner: unparseable plan keeps the multiStep kind',
        () async {
      final gateway = _ScriptedGateway([
        ModelReply(content: 'multiStep'),
        ModelReply(content: '这没法规划。'),
      ]);
      final brain = Brain(gateway: gateway);

      final decision = await brain.decide('整理整个项目');

      expect(decision.kind, IntentKind.multiStep);
      expect(decision.steps, isEmpty);
    });

    test('exposes classify and planFor directly', () async {
      final gateway = _ScriptedGateway([
        ModelReply(content: 'multiStep'),
        ModelReply(content: '1. 单步'),
      ]);
      final brain = Brain(gateway: gateway);

      expect(await brain.classify('问一下'), IntentKind.multiStep);
      expect(await brain.planFor('问一下'), ['单步']);
      expect(gateway.seenMessages, hasLength(2));
    });
  });
}
