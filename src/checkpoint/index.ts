import type { TextStorePort } from "../core/ports.js";

export interface VersionedCheckpoint<T> {
  schemaVersion: number;
  value: T;
}

export class CheckpointSchemaError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "CheckpointSchemaError";
  }
}

/** JSON checkpoint persistence whose only platform dependency is an injected text store. */
export class CheckpointStore<T> {
  constructor(
    private readonly textStore: TextStorePort,
    readonly schemaVersion: number,
  ) {
    if (!Number.isInteger(schemaVersion) || schemaVersion < 1) {
      throw new CheckpointSchemaError("schemaVersion must be a positive integer");
    }
  }

  async load(key: string): Promise<T | null> {
    const text = await this.textStore.read(key);
    if (text === undefined) return null;

    let decoded: unknown;
    try {
      decoded = JSON.parse(text);
    } catch (error) {
      throw new CheckpointSchemaError(`Invalid checkpoint JSON: ${String(error)}`);
    }
    if (!isRecord(decoded) || decoded.schemaVersion !== this.schemaVersion || !("value" in decoded)) {
      const actual = isRecord(decoded) ? String(decoded.schemaVersion) : "missing";
      throw new CheckpointSchemaError(
        `Unsupported checkpoint schemaVersion ${actual}; expected ${this.schemaVersion}`,
      );
    }
    return decoded.value as T;
  }

  async save(key: string, value: T): Promise<void> {
    
    const envelope: VersionedCheckpoint<T> = { schemaVersion: this.schemaVersion, value };
    // The port operation is deliberately atomic: this layer never exposes a partial JSON write.
    await this.textStore.writeAtomic(key, JSON.stringify(envelope));
  }
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}
