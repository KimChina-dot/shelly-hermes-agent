import { readdir } from "node:fs/promises";
import { resolve, relative } from "node:path";
import type { AgentTool } from "../agent/types.js";
import type { ProcessPort, TextStorePort } from "../core/ports.js";
import { normalizeLogicalPath } from "./logical-path.js";

export interface WorkspaceToolOptions {
  readonly root: string;
  readonly store: TextStorePort;
  readonly process: ProcessPort;
  readonly maxReadChars?: number;
  readonly maxListEntries?: number;
}

export function createWorkspaceTools(options: WorkspaceToolOptions): readonly AgentTool[] {
  const maxReadChars = options.maxReadChars ?? 80_000;
  const maxListEntries = options.maxListEntries ?? 500;
  const root = resolve(options.root);

  return [
    {
      definition: {
        name: "read_file",
        description: "读取工作区内的 UTF-8 文本文件",
        inputSchema: objectSchema({ path: { type: "string" } }, ["path"]),
      },
      async execute(input) {
        const path = stringField(recordInput(input), "path");
        const content = await options.store.read(workspacePath(path));
        if (content === undefined) throw new Error(`File not found: ${path}`);
        return {
          path,
          content: content.length <= maxReadChars ? content : content.slice(0, maxReadChars),
          truncated: content.length > maxReadChars,
        };
      },
    },
    {
      definition: {
        name: "list_files",
        description: "列出工作区目录。默认不递归，recursive=true 时递归列出",
        inputSchema: objectSchema(
          { path: { type: "string" }, recursive: { type: "boolean" } },
          ["path"],
        ),
      },
      async execute(input) {
        const record = recordInput(input);
        const logical = stringField(record, "path");
        const recursive = record.recursive === true;
        const absolute = resolve(root, workspacePath(logical));
        const entries: string[] = [];
        await walk(absolute, recursive, entries, maxListEntries, root);
        return { path: logical, entries, truncated: entries.length >= maxListEntries };
      },
    },
    {
      definition: {
        name: "write_file",
        description: "覆盖写入工作区内的 UTF-8 文本文件。每次调用都需要用户确认",
        inputSchema: objectSchema(
          { path: { type: "string" }, content: { type: "string" } },
          ["path", "content"],
        ),
      },
      async execute(input, context) {
        const record = recordInput(input);
        const path = stringField(record, "path");
        const content = stringField(record, "content");
        const approved = await context.confirm(`允许覆盖写入文件“${path}”吗？`);
        if (!approved) throw new Error("User denied file write");
        await options.store.writeAtomic(workspacePath(path), content);
        return { path, writtenChars: content.length };
      },
    },
    {
      definition: {
        name: "run_command",
        description: "在工作区内执行非交互命令。禁止 shell 字符串拼接，每次调用都需要用户确认",
        inputSchema: objectSchema(
          {
            executable: { type: "string" },
            args: { type: "array", items: { type: "string" } },
            cwd: { type: "string" },
            timeoutMs: { type: "integer", minimum: 1000, maximum: 120000 },
          },
          ["executable", "args", "cwd"],
        ),
      },
      async execute(input, context) {
        const record = recordInput(input);
        const executable = stringField(record, "executable");
        const args = stringArrayField(record, "args");
        const cwdLogical = stringField(record, "cwd");
        const timeoutMs = numberField(record, "timeoutMs", 30_000);
        const cwd = resolve(root, workspacePath(cwdLogical));
        if (!inside(root, cwd)) throw new Error("Command cwd escapes workspace");
        const approved = await context.confirm(
          `允许在“${cwdLogical || "."}”执行：${[executable, ...args].join(" ")}？`,
        );
        if (!approved) throw new Error("User denied command execution");
        return options.process.run({ executable, args, cwd, timeoutMs, maxOutputBytes: 100_000 });
      },
    },
  ];
}

async function walk(
  directory: string,
  recursive: boolean,
  output: string[],
  limit: number,
  root: string,
): Promise<void> {
  if (!inside(root, directory)) throw new Error("Directory escapes workspace");
  const entries = await readdir(directory, { withFileTypes: true });
  entries.sort((a, b) => a.name.localeCompare(b.name));
  for (const entry of entries) {
    if (output.length >= limit) return;
    if ([".git", "node_modules", ".venv"].includes(entry.name)) continue;
    const absolute = resolve(directory, entry.name);
    const item = relative(root, absolute).replace(/\\/g, "/");
    output.push(entry.isDirectory() ? `${item}/` : item);
    if (recursive && entry.isDirectory()) await walk(absolute, true, output, limit, root);
  }
}

function inside(root: string, target: string): boolean {
  const rel = relative(root, target);
  return rel === "" || (!rel.startsWith("..") && !rel.startsWith("/"));
}

function workspacePath(path: string): string {
  const logical = path === "" ? "." : normalizeLogicalPath(path);
  if (logical.startsWith("/") || /^[A-Za-z]:\//.test(logical)) {
    throw new Error("Absolute paths are not allowed");
  }
  return logical;
}

function recordInput(input: unknown): Record<string, unknown> {
  if (!input || typeof input !== "object" || Array.isArray(input)) throw new TypeError("Tool input must be an object");
  return input as Record<string, unknown>;
}

function fields(input: unknown, names: readonly string[]): Record<string, string> {
  const record = recordInput(input);
  const result: Record<string, string> = {};
  for (const name of names) result[name] = stringField(record, name);
  return result;
}

function stringField(record: Record<string, unknown>, name: string): string {
  const value = record[name];
  if (typeof value !== "string") throw new TypeError(`${name} must be a string`);
  return value;
}

function stringArrayField(record: Record<string, unknown>, name: string): string[] {
  const value = record[name];
  if (!Array.isArray(value) || !value.every((item) => typeof item === "string")) {
    throw new TypeError(`${name} must be an array of strings`);
  }
  return value;
}

function numberField(record: Record<string, unknown>, name: string, fallback: number): number {
  const value = record[name];
  if (value === undefined) return fallback;
  if (!Number.isInteger(value) || (value as number) < 1000 || (value as number) > 120_000) {
    throw new TypeError(`${name} must be an integer between 1000 and 120000`);
  }
  return value as number;
}

function objectSchema(
  properties: Record<string, unknown>,
  required: readonly string[],
): Record<string, unknown> {
  return { type: "object", properties, required, additionalProperties: false };
}
