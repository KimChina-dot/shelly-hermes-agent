# Shelly upstream audit

- Repository: `RYOITABASHI/Shelly`
- Audited commit: `97271092e4d1c5b63556ab5296a9ed03c3c7766f`
- Version: 7.5.5; Expo 54; React Native 0.81.5; pnpm 9.12.0.
- License: GPL-3.0. Keep reusable core independent; distribute a Shelly-derived combined app under compatible GPL obligations.
- Android runtime: arm64 native terminal module bundles bash, Git, Node, Python and JNI PTY.
- Existing host facilities include `TerminalSessionService`, `AgentAlarmScheduler`, `AgentRuntime`, boot receiver and notification infrastructure.
- Risk review: broad storage access, exact alarms, boot, wake lock, overlay, notification and special-use foreground-service permissions require explicit UX and distribution-policy review.
- Current audit verifies source structure, not an APK build or device run.
