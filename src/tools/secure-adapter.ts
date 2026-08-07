import type { AgentTool } from "../agent/types.js";
import type { ExecutionTool, ToolMetadata } from "./execution-framework.js";

export interface AgentToolSecurity extends ToolMetadata {}

/** Adapts legacy AgentTool implementations to the unified policy/audit pipeline. */
export function secureAgentTool(tool: AgentTool, security: AgentToolSecurity): ExecutionTool {
  return {
    definition: tool.definition,
    metadata: security,
    execute(input, context) {
      return tool.execute(input, {
        ...(context.signal ? { signal: context.signal } : {}),
        // The execution framework has already completed policy and approval.
        confirm: async () => true,
      });
    },
  };
}

export function secureWorkspaceTools(tools: readonly AgentTool[]): readonly ExecutionTool[] {
  return tools.map((tool) => secureAgentTool(tool, workspaceSecurity(tool.definition.name)));
}

function workspaceSecurity(name: string): AgentToolSecurity {
  switch (name) {
    case "read_file":
    case "list_files":
      return { capabilities: ["fs.read"], risk: "read", checkpoint: "none" };
    case "write_file":
      return {
        capabilities: ["fs.write"],
        risk: "review",
        mutatesWorkspace: true,
        // Git rollback may delete unrelated untracked files. Keep disabled until a content-addressed backup exists.
        checkpoint: "none",
      };
    case "run_command":
      return {
        capabilities: ["process.dangerous"],
        risk: "dangerous",
        mutatesWorkspace: true,
        checkpoint: "none",
      };
    default:
      throw new Error(`Missing security metadata for workspace tool '${name}'`);
  }
}
