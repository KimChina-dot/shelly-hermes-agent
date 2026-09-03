import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shelly_hermes/core/agent_profile.dart';
import 'package:shelly_hermes/state/settings_store.dart';

void main() {
  test('profile presets are valid with unique ids', () {
    final ids = agentProfilePresets.map((p) => p.id).toSet();
    expect(ids.length, agentProfilePresets.length);
    expect(agentProfilePresets.every((p) => p.isValid), isTrue);
    expect(profileById('careful')?.maxRounds, greaterThan(16));
    expect(profileById('lean')?.autoCapture, isFalse);
    expect(profileById('nope'), isNull);
  });

  test('profile json round trip and copyWith', () {
    const profile = AgentProfile(
      id: 'p1',
      name: '测试档案',
      systemPrompt: '保持简洁',
      autoCapture: false,
      maxRounds: 9,
      maxToolCalls: 11,
      providerId: 'deepseek',
    );
    final restored = AgentProfile.decode(profile.encode());
    expect(restored.id, 'p1');
    expect(restored.name, '测试档案');
    expect(restored.systemPrompt, '保持简洁');
    expect(restored.autoCapture, isFalse);
    expect(restored.maxRounds, 9);
    expect(restored.maxToolCalls, 11);
    expect(restored.providerId, 'deepseek');
    expect(restored.copyWith(name: '改名').name, '改名');
    expect(restored.copyWith(name: '改名').id, 'p1');
  });

  test('settings store persists profiles and the active id', () async {
    SharedPreferences.setMockInitialValues({});
    final store = SettingsStore(await SharedPreferences.getInstance());

    // Empty store resolves to the built-in presets.
    expect(store.loadProfiles().map((p) => p.id),
        containsAll(['balanced', 'careful', 'lean']));
    expect(store.activeProfile().id, 'balanced');

    final custom = const AgentProfile(id: 'mine', name: '我的档案')
        .copyWith(providerId: 'ollama');
    await store.saveProfiles([...agentProfilePresets, custom]);
    await store.saveActiveProfileId('mine');
    expect(store.activeProfile().id, 'mine');
    expect(store.activeProfile().providerId, 'ollama');
    expect(store.loadProfiles(), hasLength(4));

    // Clearing the active id falls back to the first stored profile.
    await store.saveActiveProfileId(null);
    expect(store.activeProfile().id, 'balanced');

    // Corrupt JSON degrades to presets instead of crashing.
    await store.saveProfiles([custom]);
    final corrupt = SettingsStore(await SharedPreferences.getInstance());
    await corrupt.saveActiveProfileId('mine');
    await (await SharedPreferences.getInstance())
        .setString('shelly.agent.profiles', '{not json');
    expect(corrupt.loadProfiles().first.id, 'balanced');
    expect(corrupt.activeProfile().id, 'balanced');
  });

  test('asEditableCopy produces a user-owned duplicate', () {
    const preset = AgentProfile(
      id: 'careful',
      name: '谨慎工程师',
      systemPrompt: '先计划再动手',
      maxRounds: 24,
      maxToolCalls: 48,
      autoCapture: true,
    );

    final copy = preset.asEditableCopy(newId: 'profile-123');

    expect(copy.id, 'profile-123');
    expect(copy.name, '谨慎工程师(自定义)');
    expect(copy.systemPrompt, '先计划再动手');
    expect(copy.maxRounds, 24);
    expect(copy.maxToolCalls, 48);
    expect(copy.autoCapture, isTrue);
    expect(copy.isPreset, isFalse, reason: 'the copy is user-owned');
    expect(preset.isPreset, isTrue);
  });

  test('isValid enforces the raised caps', () {
    expect(
      const AgentProfile(id: 'x', name: 'X', maxRounds: 200).isValid,
      isTrue,
    );
    expect(
      const AgentProfile(id: 'x', name: 'X', maxRounds: 201).isValid,
      isFalse,
    );
    expect(
      const AgentProfile(id: 'x', name: 'X', maxToolCalls: 500).isValid,
      isTrue,
    );
    expect(
      const AgentProfile(id: 'x', name: 'X', maxToolCalls: 501).isValid,
      isFalse,
    );
  });

}
