import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:shelly_hermes/core/gateway/openai_gateway.dart';
import 'package:shelly_hermes/state/scheduled_tasks.dart';
import 'package:shelly_hermes/state/settings_store.dart';

/// Scripted transport: records outgoing requests and answers with a
/// canned chat/completions payload — the fake gateway for scheduler tests.
class _ScriptedTransport implements ChatTransport {
  _ScriptedTransport(this._handler);

  final Future<ChatResponse> Function(ChatRequest request) _handler;
  final List<ChatRequest> requests = [];

  @override
  Future<ChatResponse> post(ChatRequest request) async {
    requests.add(request);
    return _handler(request);
  }

  @override
  Future<ChatStreamResponse> postStreaming(ChatRequest request) async {
    throw UnimplementedError('the scheduler never streams');
  }
}

ChatResponse _ok(String content) => ChatResponse(
      statusCode: 200,
      body: jsonEncode({
        'choices': [
          {
            'message': {'role': 'assistant', 'content': content},
          },
        ],
      }),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late SharedPreferences prefs;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
  });

  ScheduledTaskStore makeStore({DateTime Function()? clock}) =>
      ScheduledTaskStore(prefs, clock: clock);

  group('ScheduledTaskStore persistence', () {
    test('addTask round-trips through SharedPreferences with epoch-ms at',
        () async {
      final store = makeStore();
      final at = DateTime(2026, 9, 7, 9, 30);
      final task = await store.addTask(prompt: '整理今日待办', at: at);

      final raw = prefs.getString('shelly.sched.tasks');
      expect(raw, isNotNull);
      final decoded = jsonDecode(raw!) as List<dynamic>;
      expect(decoded, hasLength(1));
      final record = decoded.single as Map<String, dynamic>;
      expect(record['at'], at.millisecondsSinceEpoch);
      expect(record['prompt'], '整理今日待办');
      expect(record['repeat'], 'once');
      expect(record['status'], 'pending');

      // A fresh store over the same prefs reads the identical record.
      final reloaded = makeStore().loadTasks();
      expect(reloaded, hasLength(1));
      expect(reloaded.single.id, task.id);
      expect(reloaded.single.at, at);
      expect(reloaded.single.enabled, isTrue);
      expect(reloaded.single.lastRunAt, isNull);
      expect(reloaded.single.result, isNull);
    });

    test('daily and weekly metadata round-trips', () async {
      final store = makeStore();
      await store.addTask(
        prompt: '日报',
        at: DateTime(2026, 9, 7, 8),
        repeat: TaskRepeatMode.daily,
      );
      await store.addTask(
        prompt: '周报',
        at: DateTime(2026, 9, 8, 8),
        repeat: TaskRepeatMode.weekly,
        enabled: false,
      );

      final tasks = store.loadTasks();
      expect(tasks.map((t) => t.repeat),
          [TaskRepeatMode.daily, TaskRepeatMode.weekly]);
      expect(tasks.last.enabled, isFalse);
    });

    test('saveTask upserts and removeTask deletes', () async {
      final store = makeStore();
      final task = await store.addTask(
        prompt: '旧提示词',
        at: DateTime(2026, 9, 7, 9),
      );

      await store.saveTask(ScheduledTask(
        id: task.id,
        prompt: '新提示词',
        at: DateTime(2026, 9, 7, 10),
        repeat: TaskRepeatMode.daily,
      ));
      var reloaded = store.loadTasks();
      expect(reloaded, hasLength(1));
      expect(reloaded.single.prompt, '新提示词');
      expect(reloaded.single.repeat, TaskRepeatMode.daily);

      await store.saveTask(
        await store.addTask(prompt: '第二条', at: DateTime(2026, 9, 8, 9)),
      );
      expect(store.loadTasks(), hasLength(2));

      await store.removeTask(task.id);
      reloaded = store.loadTasks();
      expect(reloaded, hasLength(1));
      expect(reloaded.single.prompt, '第二条');
    });

    test('setEnabled toggles persistence and hasEnabledTasks', () async {
      final store = makeStore();
      final task = await store.addTask(
        prompt: '暂停我',
        at: DateTime(2026, 9, 7, 9),
      );
      expect(store.hasEnabledTasks(), isTrue);

      await store.setEnabled(task.id, false);
      expect(store.loadTasks().single.enabled, isFalse);
      expect(store.hasEnabledTasks(), isFalse);

      await store.setEnabled(task.id, true);
      expect(store.hasEnabledTasks(), isTrue);
    });

    test('a corrupt record reads as empty instead of throwing', () async {
      await prefs.setString('shelly.sched.tasks', '{not json');
      expect(makeStore().loadTasks(), isEmpty);
    });
  });

  group('due query', () {
    test('returns enabled tasks at or past their schedule', () async {
      final now = DateTime(2026, 9, 6, 12);
      final store = makeStore(clock: () => now);
      await store.addTask(
          prompt: '已到期', at: now.subtract(const Duration(minutes: 1)));
      await store.addTask(
          prompt: '还没到', at: now.add(const Duration(minutes: 5)));
      await store.addTask(prompt: '恰好此刻', at: now);

      expect(store.dueTasks(now).map((t) => t.prompt), ['已到期', '恰好此刻']);
    });

    test('disabled and already-run one-shot tasks are never due', () async {
      final now = DateTime(2026, 9, 6, 12);
      final store = makeStore(clock: () => now);
      await store.addTask(
        prompt: '停用',
        at: now.subtract(const Duration(hours: 2)),
        enabled: false,
      );
      final done = await store.addTask(
          prompt: '完成', at: now.subtract(const Duration(hours: 1)));
      await store.recordRun(done.id, result: 'ok', success: true);
      final failed = await store.addTask(
          prompt: '失败', at: now.subtract(const Duration(minutes: 30)));
      await store.recordRun(failed.id, result: 'boom', success: false);

      expect(store.dueTasks(now), isEmpty);
    });
  });

  group('post-run reschedule', () {
    test('one-shot tasks become done and keep their schedule', () async {
      final store = makeStore();
      final at = DateTime(2026, 9, 6, 9);
      final task = await store.addTask(prompt: '单次', at: at);
      final ranAt = DateTime(2026, 9, 6, 9, 1);

      final updated = await store.recordRun(
        task.id,
        result: '结果文本',
        success: true,
        ranAt: ranAt,
      );

      expect(updated!.status, ScheduledTaskStatus.done);
      expect(updated.at, at);
      expect(updated.lastRunAt, ranAt);
      expect(updated.result, '结果文本');
    });

    test('daily tasks move to the next occurrence after the run', () async {
      final store = makeStore();
      final task = await store.addTask(
        prompt: '每日简报',
        at: DateTime(2026, 9, 6, 9),
        repeat: TaskRepeatMode.daily,
      );

      final updated = await store.recordRun(
        task.id,
        result: '完成',
        success: true,
        ranAt: DateTime(2026, 9, 6, 9, 5),
      );

      expect(updated!.at, DateTime(2026, 9, 7, 9));
      expect(updated.result, '完成');
      // Not due in the rest of today; due again tomorrow at the same time.
      expect(store.dueTasks(DateTime(2026, 9, 6, 23)), isEmpty);
      expect(
          store.dueTasks(DateTime(2026, 9, 7, 9)).single.id, task.id);
    });

    test('weekly tasks keep the weekday and time-of-day', () async {
      final store = makeStore();
      final task = await store.addTask(
        prompt: '每周清理',
        at: DateTime(2026, 9, 1, 8, 30), // a Tuesday
        repeat: TaskRepeatMode.weekly,
      );

      final updated = await store.recordRun(
        task.id,
        result: '完成',
        success: true,
        ranAt: DateTime(2026, 9, 1, 9),
      );

      expect(updated!.at, DateTime(2026, 9, 8, 8, 30)); // next Tuesday
    });

    test('a repeating task that missed several windows skips past them',
        () async {
      final store = makeStore();
      final task = await store.addTask(
        prompt: '三日未开的每日',
        at: DateTime(2026, 9, 3, 9),
        repeat: TaskRepeatMode.daily,
      );

      final updated = await store.recordRun(
        task.id,
        result: '补跑完成',
        success: true,
        ranAt: DateTime(2026, 9, 6, 10),
      );

      // Strictly after the catch-up run — none of the missed 9:00 slots.
      expect(updated!.at, DateTime(2026, 9, 7, 9));
    });

    test('recording a run for a deleted task returns null', () async {
      final store = makeStore();
      expect(
        await store.recordRun('missing', result: 'x', success: true),
        isNull,
      );
    });
  });

  group('SchedulerService', () {
    test('tick executes a due task via the injected runner and stores it',
        () async {
      final now = DateTime(2026, 9, 6, 12);
      final store = makeStore(clock: () => now);
      final task = await store.addTask(
        prompt: '给团队写周报初稿',
        at: now.subtract(const Duration(minutes: 1)),
      );
      final seen = <ScheduledTask>[];
      final service = SchedulerService(
        store: store,
        clock: () => now,
        runner: (task) {
          seen.add(task);
          return Future.value('周报初稿已经写好');
        },
      );

      final ran = await service.tick();

      expect(seen, hasLength(1));
      expect(seen.single.id, task.id);
      expect(seen.single.prompt, '给团队写周报初稿');
      expect(ran.single.id, task.id);

      final stored = store.taskById(task.id)!;
      expect(stored.result, '周报初稿已经写好');
      expect(stored.status, ScheduledTaskStatus.done);
      expect(stored.lastRunAt, now);

      // One-shot: the second tick is a no-op.
      expect(await service.tick(), isEmpty);
      expect(seen, hasLength(1));
    });

    test('a runner failure is stored as failed and never throws', () async {
      final now = DateTime(2026, 9, 6, 12);
      final store = makeStore(clock: () => now);
      final once = await store.addTask(
        prompt: '会失败的单次',
        at: now.subtract(const Duration(minutes: 1)),
      );
      final daily = await store.addTask(
        prompt: '会失败的每日',
        at: DateTime(2026, 9, 6, 11, 59),
        repeat: TaskRepeatMode.daily,
      );
      final service = SchedulerService(
        store: store,
        clock: () => now,
        runner: (task) async => throw StateError('网关不可用'),
      );

      final ran = await service.tick();

      expect(ran, hasLength(2));
      final storedOnce = store.taskById(once.id)!;
      expect(storedOnce.status, ScheduledTaskStatus.failed);
      expect(storedOnce.result, contains('网关不可用'));
      // One-shot failure is terminal.
      expect(await service.tick(), isEmpty);

      // The daily failure still reschedules so it retries on time tomorrow.
      final storedDaily = store.taskById(daily.id)!;
      expect(storedDaily.status, ScheduledTaskStatus.failed);
      expect(storedDaily.at, DateTime(2026, 9, 7, 11, 59));
      expect(
        store.dueTasks(DateTime(2026, 9, 7, 11, 59)).single.id,
        daily.id,
      );
    });

    test('disabled tasks are skipped entirely', () async {
      final now = DateTime(2026, 9, 6, 12);
      final store = makeStore(clock: () => now);
      await store.addTask(
        prompt: '停用任务',
        at: now.subtract(const Duration(hours: 1)),
        enabled: false,
      );
      var calls = 0;
      final service = SchedulerService(
        store: store,
        clock: () => now,
        runner: (task) async {
          calls += 1;
          return '不该被调用';
        },
      );

      expect(await service.tick(), isEmpty);
      expect(calls, 0);

      final stored = store.loadTasks().single;
      expect(stored.status, ScheduledTaskStatus.pending);
      expect(stored.result, isNull);
      expect(stored.lastRunAt, isNull);
    });

    test('without a runner due tasks stay pending', () async {
      final now = DateTime(2026, 9, 6, 12);
      final store = makeStore(clock: () => now);
      final task = await store.addTask(
        prompt: '没人执行',
        at: now.subtract(const Duration(minutes: 1)),
      );
      final service = SchedulerService(store: store, clock: () => now);

      expect(await service.tick(), isEmpty);
      expect(store.taskById(task.id)!.status, ScheduledTaskStatus.pending);
    });

    test('catch-up: an overdue repeating task runs once on the next tick',
        () async {
      final store = makeStore();
      final task = await store.addTask(
        prompt: '三天没开 App 的每日',
        at: DateTime(2026, 9, 3, 9),
        repeat: TaskRepeatMode.daily,
      );
      var calls = 0;
      final reopenedAt = DateTime(2026, 9, 6, 10);
      final service = SchedulerService(
        store: store,
        clock: () => reopenedAt,
        runner: (task) async {
          calls += 1;
          return '补跑结果';
        },
      );

      final ran = await service.tick();

      expect(calls, 1);
      expect(ran.single.result, '补跑结果');
      final stored = store.taskById(task.id)!;
      expect(stored.at, DateTime(2026, 9, 7, 9));

      // Ticking again the same day does not re-run the catch-up.
      await service.tick();
      expect(calls, 1);
    });

    test('tick is cheap when nothing is due: the runner is never consulted',
        () async {
      final now = DateTime(2026, 9, 6, 12);
      final store = makeStore(clock: () => now);
      await store.addTask(
          prompt: '未来任务', at: now.add(const Duration(days: 1)));
      var calls = 0;
      final service = SchedulerService(
        store: store,
        clock: () => now,
        runner: (task) async {
          calls += 1;
          return '';
        },
      );

      expect(await service.tick(), isEmpty);
      expect(calls, 0);
    });

    test('a task deleted while it runs is skipped, not resurrected',
        () async {
      final now = DateTime(2026, 9, 6, 12);
      final store = makeStore(clock: () => now);
      final task = await store.addTask(
        prompt: '中途删除',
        at: now.subtract(const Duration(minutes: 1)),
      );
      final service = SchedulerService(
        store: store,
        clock: () => now,
        runner: (task) async {
          await store.removeTask(task.id);
          return '迟到的结果';
        },
      );

      expect(await service.tick(), isEmpty);
      expect(store.taskById(task.id), isNull);
    });
  });

  group('SchedulerTicker', () {
    test('the tick loop only runs while enabled tasks exist', () async {
      final now = DateTime(2026, 9, 6, 12);
      final store = makeStore(clock: () => now);
      final service = SchedulerService(
        store: store,
        clock: () => now,
        runner: (task) async => '',
      );
      final ticker = SchedulerTicker(service);

      ticker.ensureRunning();
      expect(ticker.isRunning, isFalse,
          reason: '没有任务时不应持有任何定时器');

      final task = await store.addTask(
        prompt: '唤醒 ticker',
        at: now.add(const Duration(minutes: 5)),
      );
      ticker.onStoreChanged();
      expect(ticker.isRunning, isTrue);

      // A tick re-evaluates: once the last task goes away the loop stops.
      await store.removeTask(task.id);
      await ticker.tick();
      expect(ticker.isRunning, isFalse);

      ticker.dispose();
    });

    test('onResume re-arms and runs an immediate catch-up tick', () async {
      final now = DateTime(2026, 9, 6, 12);
      final store = makeStore(clock: () => now);
      final task = await store.addTask(
        prompt: '回来就补跑',
        at: now.subtract(const Duration(minutes: 1)),
      );
      final service = SchedulerService(
        store: store,
        clock: () => now,
        runner: (task) async => '已补跑',
      );
      final ticker = SchedulerTicker(service);

      await ticker.onResume();

      expect(store.taskById(task.id)!.result, '已补跑');
      // One-shot finished; the loop stops itself again.
      expect(ticker.isRunning, isFalse);
    });
  });

  group('settingsBackedRunner', () {
    test('sends persona + prompt through the OpenAI-compatible gateway',
        () async {
      SharedPreferences.setMockInitialValues({
        'shelly.model.config': jsonEncode({
          'baseUrl': 'https://api.example.com/v1',
          'apiKey': 'sk-test',
          'model': 'test-model',
        }),
      });
      final settings = SettingsStore(await SharedPreferences.getInstance());
      final transport = _ScriptedTransport((request) async => _ok('定时结果:OK'));
      final runner = settingsBackedRunner(settings, transport: transport);

      final reply = await runner(ScheduledTask(
        id: 't1',
        prompt: '写一首关于秋天的小诗',
        at: DateTime(2026, 9, 7, 9),
      ));

      expect(reply, '定时结果:OK');
      final request = transport.requests.single;
      expect(request.url, 'https://api.example.com/v1/chat/completions');
      expect(request.headers['Authorization'], 'Bearer sk-test');

      final body = jsonDecode(request.body) as Map<String, dynamic>;
      expect(body['stream'], isFalse);
      final messages = (body['messages'] as List<dynamic>)
          .cast<Map<String, dynamic>>();
      final persona = settings.activeProfile().systemPrompt.trim();
      if (persona.isEmpty) {
        expect(messages, hasLength(1));
      } else {
        expect(messages, hasLength(2));
        expect(messages.first['role'], 'system');
        expect(messages.first['content'], persona);
      }
      expect(messages.last['role'], 'user');
      expect(messages.last['content'], '写一首关于秋天的小诗');
    });

    test('an unconfigured endpoint fails the run with a clear message',
        () async {
      final settings = SettingsStore(prefs);
      final runner = settingsBackedRunner(settings);

      await expectLater(
        runner(ScheduledTask(
          id: 't',
          prompt: '随便什么',
          at: DateTime(2026, 9, 7),
        )),
        throwsA(isA<ScheduledTaskException>()),
      );
    });
  });
}
