export class PathSecurityError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "PathSecurityError";
  }
}

function parts(path: string): { prefix: string; segments: string[]; absolute: boolean } {
  if (path.includes("\0")) throw new PathSecurityError("NUL is not valid in a path");
  const value = path.replace(/\\/g, "/");
  const drive = /^([A-Za-z]):(?:\/|$)/.exec(value);
  const unc = value.startsWith("//");
  const absolute = value.startsWith("/") || drive !== null;
  const prefix = drive ? `${drive[1]!.toUpperCase()}:` : unc ? "//" : absolute ? "/" : "";
  const body = drive ? value.slice(drive[0].length) : unc ? value.slice(2) : absolute ? value.slice(1) : value;
  const segments: string[] = [];
  for (const segment of body.split("/")) {
    if (!segment || segment === ".") continue;
    if (segment === "..") {
      if (segments.length === 0) throw new PathSecurityError(`Path escapes its logical root: ${path}`);
      segments.pop();
    } else {
      segments.push(segment);
    }
  }
  return { prefix, segments, absolute };
}

/** Normalize POSIX and Windows syntax without importing a platform path API. */
export function normalizeLogicalPath(path: string): string {
  if (typeof path !== "string" || path.length === 0) throw new PathSecurityError("Path must not be empty");
  const parsed = parts(path);
  if (parsed.prefix === "/" || parsed.prefix === "//") return parsed.prefix + parsed.segments.join("/");
  if (parsed.prefix.endsWith(":")) return `${parsed.prefix}/${parsed.segments.join("/")}`;
  return parsed.segments.join("/") || ".";
}

function isAbsolute(path: string): boolean {
  return path.startsWith("/") || /^[A-Za-z]:\//.test(path);
}

function windowsPath(path: string): boolean { return /^[A-Za-z]:\//.test(path); }

/** Resolve a path and prove, segment-wise, that it remains below sandboxRoot. */
export function resolveSandboxPath(sandboxRoot: string, requestedPath: string): string {
  const root = normalizeLogicalPath(sandboxRoot);
  if (!isAbsolute(root)) throw new PathSecurityError("Sandbox root must be absolute");
  let candidate: string;
  const request = normalizeLogicalPath(requestedPath);
  if (isAbsolute(request)) candidate = request;
  else candidate = normalizeLogicalPath(`${root}/${request}`);
  if (windowsPath(root) !== windowsPath(candidate)) throw new PathSecurityError("Path uses a different root kind");
  const fold = windowsPath(root) ? (s: string) => s.toLowerCase() : (s: string) => s;
  const r = fold(root).replace(/\/$/, "");
  const c = fold(candidate);
  if (c !== r && !c.startsWith(`${r}/`)) throw new PathSecurityError(`Path is outside sandbox: ${requestedPath}`);
  return candidate;
}

export const normalizePath = normalizeLogicalPath;
export const resolveInSandbox = resolveSandboxPath;
