import type { ProcessPort } from "../core/ports.js";
import type { GitCheckpoint, GitCheckpointPort, PatchPreview } from "./execution-framework.js";

/** Git implementation uses argv only (no shell), so quoting is identical on Android and Windows. */
export class PortableGitCheckpoints implements GitCheckpointPort {
  constructor(
    private readonly process: ProcessPort,
    private readonly root: string,
    private readonly timeoutMs = 30_000,
  ) {}

  async create(requestId: string): Promise<GitCheckpoint> {
    const revision = (await this.git(["rev-parse", "HEAD"])).trim();
    // Capture tracked and untracked workspace state in a private stash object without changing the worktree.
    const tree = (await this.git(["stash", "create", `shelly-checkpoint:${requestId}`])).trim();
    return { id: requestId, revision: tree || revision };
  }

  async diff(checkpoint: GitCheckpoint, maxChars: number): Promise<PatchPreview> {
    const patch = await this.git(["diff", "--no-ext-diff", "--binary", checkpoint.revision, "--", "."], Math.max(maxChars * 2, 100_000));
    return { summary: patch ? `Workspace changes since ${checkpoint.id}` : "No workspace changes", patch: patch.length <= maxChars ? patch : patch.slice(0, maxChars), truncated: patch.length > maxChars };
  }

  async rollback(checkpoint: GitCheckpoint): Promise<void> {
    await this.git(["reset", "--hard", checkpoint.revision]);
    await this.git(["clean", "-fd"]);
  }

  private async git(args: readonly string[], maxOutputBytes = 100_000): Promise<string> {
    const result = await this.process.run({ executable: "git", args, cwd: this.root, timeoutMs: this.timeoutMs, maxOutputBytes });
    if (result.timedOut) throw new Error("Git operation timed out");
    if (result.exitCode !== 0) throw new Error(result.stderr || `git exited ${result.exitCode}`);
    return result.stdout;
  }
}
