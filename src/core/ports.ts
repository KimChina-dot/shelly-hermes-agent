export interface ClockPort {
  now(): Date;
}

export interface TextStorePort {
  read(path: string): Promise<string | undefined>;
  writeAtomic(path: string, content: string): Promise<void>;
  append(path: string, content: string): Promise<void>;
  exists(path: string): Promise<boolean>;
}

export interface ProcessRequest {
  readonly executable: string;
  readonly args: readonly string[];
  readonly cwd: string;
  readonly env?: Readonly<Record<string, string>>;
  readonly timeoutMs: number;
  readonly maxOutputBytes: number;
}

export interface ProcessResult {
  readonly exitCode: number;
  readonly stdout: string;
  readonly stderr: string;
  readonly timedOut: boolean;
}

export interface ProcessPort {
  run(request: ProcessRequest): Promise<ProcessResult>;
}

export interface BackgroundTaskPort {
  schedule(taskId: string, payload: string): Promise<void>;
  cancel(taskId: string): Promise<void>;
}

export interface NotificationPort {
  showProgress(taskId: string, title: string, progress?: number): Promise<void>;
  showCompletion(taskId: string, title: string, summary: string): Promise<void>;
}
