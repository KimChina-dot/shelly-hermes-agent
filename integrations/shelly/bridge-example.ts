import { AndroidHostBridge, type AndroidHostBindings } from "../../src/adapters/android/index.js";
// Shelly-side GPL adapter. Implement these methods with TerminalEmulatorModule,
// AgentAlarmScheduler/AgentRuntime and notification APIs available in the chosen Shelly revision.
// Keep native names here rather than inside the portable core.
export const createShellyHermesHost=(bindings:AndroidHostBindings)=>new AndroidHostBridge(bindings);
