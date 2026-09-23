import { tool } from "@opencode-ai/plugin"
import type { Plugin } from "@opencode-ai/plugin"
import { execFile } from "node:child_process"
import { promisify } from "node:util"
import { readFileSync } from "node:fs"
import { homedir } from "node:os"
import { join } from "node:path"

// mem0 plugin: gives the agent persistent long-term memory through the mem0
// CLI (https://github.com/mem0ai/mem0). The CLI is already authenticated
// (~/.mem0/config.json). These tools read/write facts scoped to the user.
//
//   mem0_search — query memory, returns top matching facts with metadata
//   mem0_add    — store a new fact from a single message/string
//
// To use in a different account, pass user_id explicitly to either tool.

const z = tool.schema
const execFileP = promisify(execFile)
const MEM0_BIN = "mem0"
const CONFIG_PATH = join(homedir(), ".mem0", "config.json")

function defaultUserId(): string {
  try {
    const cfg = JSON.parse(readFileSync(CONFIG_PATH, "utf8"))
    return cfg?.defaults?.user_id || cfg?.platform?.default_user_id || ""
  } catch {
    return ""
  }
}

function extractJson(text: string): string {
  const start = text.indexOf("[")
  const end = text.lastIndexOf("]")
  if (start !== -1 && end > start) return text.slice(start, end + 1)
  const oStart = text.indexOf("{")
  const oEnd = text.lastIndexOf("}")
  if (oStart !== -1 && oEnd > oStart) return text.slice(oStart, oEnd + 1)
  return text
}

async function run(args: string[]): Promise<{ stdout: string; stderr: string }> {
  const { stdout, stderr } = await execFileP(MEM0_BIN, args, {
    timeout: 120_000,
    maxBuffer: 16 * 1024 * 1024,
  })
  return { stdout, stderr }
}

const mem0Search = tool({
  description:
    "Search opencode's long-term memory (mem0) for facts about the user and their projects, preferences, decisions, and history. Returns the top matching memories with their source session metadata. Use this before or during work when you need context that may not be in the current conversation.",
  args: {
    query: z.string().min(1).describe("The fact/question to search for, e.g. 'what does the user prefer' or 'Vairy deployment setup'."),
    top_k: z.number().int().min(1).max(20).optional().describe("How many memories to return (default: 5)."),
    user_id: z.string().optional().describe("Mem0 user id. Defaults to the configured account."),
  },
  async execute({ query, top_k, user_id }) {
    const args = ["search", query, "-o", "json"]
    const uid = user_id || defaultUserId()
    if (uid) args.push("-u", uid)
    if (top_k) args.push("--top-k", String(top_k))
    let out: string
    try {
      const r = await run(args)
      out = r.stdout || r.stderr
    } catch (e: any) {
      return `mem0_search failed: ${e?.message ?? e}`
    }
    let results: any[] = []
    try {
      results = JSON.parse(extractJson(out))
    } catch {
      return `mem0_search: could not parse response:\n${out.slice(0, 2000)}`
    }
    if (!results.length) return "No memories found for this query."
    const lines = results.map((r) => {
      const md = r.metadata ?? {}
      const src = md.session_title ? ` (from session "${md.session_title}", ${md.directory ?? ""})` : ""
      return `- [score ${(r.score ?? 0).toFixed(3)}] ${r.memory}${src}\n  user_id=${r.user_id ?? ""} created=${r.created_at ?? ""}`
    })
    return lines.join("\n")
  },
})

const mem0Add = tool({
  description:
    "Store a new fact / memory in opencode's long-term memory (mem0): something you learned about the user, their project, preferences, or decisions that will be useful in future sessions. The fact is extracted by an LLM and stored persistently.",
  args: {
    content: z.string().min(1).describe("What to remember, as a statement or short message, e.g. 'The user prefers Python over Node for new services'."),
    user_id: z.string().optional().describe("Mem0 user id. Defaults to the configured account."),
    metadata: z.record(z.string(), z.string()).optional().describe("Optional metadata, e.g. {\"source\":\"opencode\",\"project\":\"vairy\"}."),
  },
  async execute({ content, user_id, metadata }) {
    const args = ["add", "-o", "quiet"]
    const uid = user_id || defaultUserId()
    if (uid) args.push("-u", uid)
    if (metadata && Object.keys(metadata).length) {
      args.push("-m", JSON.stringify(metadata))
    }
    args.push("--", content)
    try {
      await run(args)
      const scope = uid ? `user_id=${uid}` : "default user"
      return `Memory stored (${scope}): ${content}`
    } catch (e: any) {
      return `mem0_add failed: ${e?.message ?? e}`
    }
  },
})

const mem0: Plugin = async () => {
  return {
    tool: {
      mem0_search: mem0Search,
      mem0_add: mem0Add,
    },
  }
}

export default mem0