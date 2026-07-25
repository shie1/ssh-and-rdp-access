# syntax=docker.io/docker/dockerfile:1

# --- STAGE 1: Install All Dependencies & Build ---
FROM node:24-alpine3.23 AS builder
WORKDIR /app

COPY package.json yarn.lock* package-lock.json* pnpm-lock.yaml* .npmrc* ./
RUN \
  if [ -f yarn.lock ]; then yarn --frozen-lockfile --network-timeout 240000; \
  elif [ -f package-lock.json ]; then npm ci; \
  elif [ -f pnpm-lock.yaml ]; then corepack enable pnpm && pnpm i --frozen-lockfile; \
  else echo "Lockfile not found." && exit 1; \
  fi

COPY . .

# Build step (TypeScript compilation, bundling, etc.)
RUN \
  if [ -f yarn.lock ]; then yarn run build; \
  elif [ -f package-lock.json ]; then npm run build; \
  elif [ -f pnpm-lock.yaml ]; then corepack enable pnpm && pnpm run build; \
  else echo "Lockfile not found." && exit 1; \
  fi

# Prune devDependencies to keep node_modules minimal for runtime
ENV NODE_ENV=production
RUN \
  if [ -f yarn.lock ]; then yarn install --production --ignore-scripts --prefer-offline; \
  elif [ -f package-lock.json ]; then npm prune --production; \
  elif [ -f pnpm-lock.yaml ]; then corepack enable pnpm && pnpm prune --prod; \
  fi

# --- STAGE 2: Lightweight Production Runner ---
FROM node:24-alpine3.23 AS runner
WORKDIR /app

ENV NODE_ENV=production
ENV PORT=3000

# Install runtime system dependencies in a single layer
RUN apk add --no-cache wget libc6-compat openssh-keygen

# Copy production node_modules, compiled dist/build, and package metadata
COPY --from=builder /app/package.json ./package.json
COPY --from=builder /app/node_modules ./node_modules
# Adjust 'dist' below if your build output folder is named 'build' or 'lib'
COPY --from=builder /app/dist ./dist

# Create non-root user for security
RUN addgroup --system --gid 1001 nodejs && \
    adduser --system --uid 1001 expressjs && \
    chown -R expressjs:nodejs /app
USER expressjs

EXPOSE 3000

HEALTHCHECK --interval=30s --timeout=10s --start-period=30s --retries=5 \
    CMD wget --no-verbose --tries=1 --spider http://localhost:${PORT}/health || exit 1

# Runs your compiled Express app directly (e.g., node dist/index.js)
CMD ["node", "dist/index.js"]