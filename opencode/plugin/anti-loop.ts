import type { Plugin } from "@opencode-ai/plugin"

// Anti-loop guard plugin.
// Blocks two failure modes that make the model spin in place:
//   1) empty / no-op tool calls (bash without a command, edit with an empty
//      oldString, etc.)
//   2) feedback loops: re-issuing the same tool call with identical args
//      several times in a short window
// When something is blocked, the thrown error tells the model what to do
// instead (single concrete step, or ask the user via the question tool).

const WINDOW = 8
const MAX_DUPES = 3
const DUPE_WINDOW_MS = 60_000
const recent: Array<{ t: number; key: string }> = []

function stableArgs(args: any): string {
  try {
    return JSON.stringify(args ?? {})
  } catch {
    return String(args)
  }
}

function isBlank(v: any): boolean {
  return v == null || String(v).trim().length === 0
}

function reasonFor(tool: string, args: any): string | null {
  switch (tool) {
    case "bash":
      if (typeof args?.command !== "string" || args.command.trim().length === 0)
        return "bash-command is empty"
      return null
    case "edit":
      if (isBlank(args?.filePath)) return "filePath is missing"
      if (isBlank(args?.oldString)) return "oldString is empty"
      if (typeof args?.newString !== "string" || args.newString === args.oldString)
        return "newString is missing or identical to oldString"
      return null
    case "write":
      if (isBlank(args?.filePath)) return "filePath is missing"
      if (isBlank(args?.content)) return "content is empty"
      return null
    case "read":
      if (isBlank(args?.filePath)) return "filePath is missing"
      return null
    case "glob":
    case "grep":
      if (isBlank(args?.pattern)) return "pattern is missing"
      return null
    case "websearch":
      if (isBlank(args?.query)) return "query is empty"
      return null
    default:
      return null
  }
}

const antiLoop: Plugin = async () => {
  return {
    async "tool.execute.before"(input, output) {
      const { tool } = input
      const args = output?.args ?? {}
      const now = Date.now()

      // 1) Empty / no-op guard
      const bad = reasonFor(tool, args)
      if (bad) {
        throw new Error(
          `[anti-loop] Blocked ${tool}: ${bad}. Do NOT repeat this call with empty content. Take a single different, concrete step, or if you are stuck, ask the user via the question tool.`
        )
      }

      // 2) Feedback-loop guard (identical call, repeated in a short window)
      const key = `${tool}:${stableArgs(args)}`
      recent.push({ t: now, key })
      while (recent.length > WINDOW) recent.shift()
      const dupes = recent.filter((r) => r.key === key && now - r.t < DUPE_WINDOW_MS).length
      if (dupes > MAX_DUPES) {
        throw new Error(
          `[anti-loop] Blocked re-running the SAME ${tool} call (${dupes}x in the last ${WINDOW} calls) — this is a loop. Make concrete progress with a NEW call, or ask the user via the question tool.`
        )
      }
    },
  }
}

export default antiLoop