# syntax=docker.io/docker/dockerfile:1

# --- STAGE 1: Install & Build ---
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

RUN \
  if [ -f yarn.lock ]; then yarn run build; \
  elif [ -f package-lock.json ]; then npm run build; \
  elif [ -f pnpm-lock.yaml ]; then corepack enable pnpm && pnpm run build; \
  else echo "Lockfile not found." && exit 1; \
  fi

# Prune devDependencies so only production packages remain
ENV NODE_ENV=production
RUN \
  if [ -f yarn.lock ]; then yarn install --production --ignore-scripts --prefer-offline; \
  elif [ -f package-lock.json ]; then npm prune --production; \
  elif [ -f pnpm-lock.yaml ]; then corepack enable pnpm && pnpm prune --prod; \
  fi

# --- STAGE 2: Runner ---
FROM node:24-alpine3.23 AS runner
WORKDIR /app

ENV NODE_ENV=production

RUN apk add --no-cache wget libc6-compat openssh-keygen

COPY --from=builder /app/package.json ./package.json
COPY --from=builder /app/node_modules ./node_modules
COPY --from=builder /app/dist ./dist

HEALTHCHECK --interval=30s --timeout=10s --start-period=30s --retries=5 \
    CMD wget --no-verbose --tries=1 --spider http://localhost:${PORT}/health || exit 1

CMD ["yarn", "start"]