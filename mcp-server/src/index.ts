#!/usr/bin/env node

import {
  Server,
} from '@modelcontextprotocol/sdk/server/index.js';
import {
  StdioServerTransport,
} from '@modelcontextprotocol/sdk/server/stdio.js';
import {
  CallToolRequestSchema,
  ListToolsRequestSchema,
} from '@modelcontextprotocol/sdk/types.js';
import { tools, annotationsFor } from './tools.js';

// Known engine error codes → next-step guidance for the calling agent.
// Applied at the wire chokepoint so every tool benefits without per-tool code.
const ERROR_HINTS: Array<[string, string]> = [
  ['host_key_mismatch', "The endpoint's SSH host key doesn't match the pinned fingerprint (or no endpoint could be verified). If this machine was reinstalled or this is first contact, run learn_host_key; otherwise treat the network as untrusted and investigate before retrying."],
  ['sshfs_not_found', 'sshfs is not installed. Run check_dependencies for the full picture, then install: brew install fuse-t fuse-t-sshfs (or macFUSE + sshfs).'],
  ['host_unreachable', 'Host did not respond. Check ping_workstation; if it may be asleep use wake_and_wait; if its IP changed use scan_network to find it.'],
  ['volume not accessible', 'The mount exists but first access timed out — often transient on slow links. Re-check with get_mount_status in a few seconds before forcing anything.'],
  ['python3_not_found', 'python3 is required by the engine for config parsing. Install the Xcode Command Line Tools: xcode-select --install.'],
  ['stale:', 'A mount is stale (server stopped answering). Run heal_stale_mount for that disk, or fix_it to repair everything broken.'],
];

function hintFor(text: string): string | null {
  for (const [code, hint] of ERROR_HINTS) {
    if (text.includes(code)) return hint;
  }
  return null;
}

class AutoFuseMCPServer {
  private server: Server;

  constructor() {
    this.server = new Server(
      {
        name: 'autofuse-mcp',
        version: '1.0.0',
      },
      {
        capabilities: {
          tools: {},
        },
      }
    );

    this.setupHandlers();
  }

  private setupHandlers(): void {
    this.server.setRequestHandler(ListToolsRequestSchema, async () => {
      return {
        tools: tools.map((tool) => ({
          name: tool.name,
          description: tool.description,
          inputSchema: tool.inputSchema,
          annotations: annotationsFor(tool.name),
        })),
      };
    });

    this.server.setRequestHandler(CallToolRequestSchema, async (request: any) => {
      const toolName = request.params.name;
      const toolArgs = request.params.arguments || {};
      
      const tool = tools.find((t) => t.name === toolName);

      if (!tool) {
        throw new Error(`Unknown tool: ${toolName}`);
      }

      try {
        const result = await tool.execute(toolArgs as Record<string, unknown>);
        let text = JSON.stringify(result, null, 2);
        const hint = hintFor(text);
        if (hint) text += `\n\nhint: ${hint}`;
        return {
          content: [
            {
              type: 'text',
              text,
            },
          ],
        };
      } catch (error) {
        const message = error instanceof Error ? error.message : String(error);
        const hint = hintFor(message);
        return {
          content: [
            {
              type: 'text',
              text: `Error: ${message}${hint ? `\n\nhint: ${hint}` : ''}`,
            },
          ],
          isError: true,
        };
      }
    });
  }

  async run(): Promise<void> {
    const transport = new StdioServerTransport();
    await this.server.connect(transport);
  }
}

const server = new AutoFuseMCPServer();
server.run().catch((error) => {
  console.error('Server error:', error);
  process.exit(1);
});
