# AutoFuse MCP server.
#
# The server starts over stdio and answers introspection (initialize,
# tools/list) without any host dependencies — this is what registries like
# Glama exercise. Mount/heal/wake tool *execution* shells out to the bash
# engine and requires a macOS host with FUSE-T or macFUSE, so those calls are
# no-ops in a plain Linux container; the container is for discovery/CI only.
FROM node:22-slim

WORKDIR /app

COPY package.json package-lock.json ./
RUN npm ci

COPY tsconfig.json ./
COPY src ./src
RUN npm run build

CMD ["node", "dist/index.js"]
