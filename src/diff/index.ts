export type FileChangeKind = "create" | "modify" | "delete" | "rename";
export type DiffLineKind = "context" | "addition" | "deletion";

export interface DiffLine { readonly kind: DiffLineKind; readonly text: string; }
export interface DiffHunk {
  readonly id: string;
  readonly oldStart: number;
  readonly oldLines: number;
  readonly newStart: number;
  readonly newLines: number;
  readonly lines: readonly DiffLine[];
}
export interface FileModificationDiff {
  readonly id: string;
  readonly kind: FileChangeKind;
  readonly oldPath?: string;
  readonly newPath?: string;
  readonly hunks: readonly DiffHunk[];
}
export interface DiffApprovalRequest {
  readonly taskId: string;
  readonly diffId: string;
  readonly hunk: DiffHunk;
  readonly ordinal: number;
  readonly total: number;
}
export type DiffApprovalDecision = "approve" | "reject" | "abort";
export interface DiffApprovalPort { decide(request: DiffApprovalRequest): Promise<DiffApprovalDecision>; }
export interface DiffApprovalResult {
  readonly approvedHunkIds: readonly string[];
  readonly rejectedHunkIds: readonly string[];
  readonly aborted: boolean;
}

/** Requests approval one hunk at a time in stable input order and stops immediately on abort. */
export async function approveDiffByHunk(taskId: string, diff: FileModificationDiff, port: DiffApprovalPort): Promise<DiffApprovalResult> {
  const approved: string[] = [], rejected: string[] = [];
  for (let ordinal = 0; ordinal < diff.hunks.length; ordinal += 1) {
    const hunk = diff.hunks[ordinal]!;
    const decision = await port.decide({ taskId, diffId: diff.id, hunk, ordinal, total: diff.hunks.length });
    if (decision === "abort") return { approvedHunkIds: approved, rejectedHunkIds: rejected, aborted: true };
    (decision === "approve" ? approved : rejected).push(hunk.id);
  }
  return { approvedHunkIds: approved, rejectedHunkIds: rejected, aborted: false };
}
