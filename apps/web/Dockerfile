# syntax=docker/dockerfile:1.7

FROM node:20-bookworm-slim AS base
ENV PNPM_HOME=/pnpm
ENV PATH="${PNPM_HOME}:${PATH}"
WORKDIR /app
RUN corepack enable

FROM base AS deps
COPY pnpm-lock.yaml pnpm-workspace.yaml package.json turbo.json ./
COPY apps/web/package.json ./apps/web/package.json
RUN pnpm fetch --filter @ai-dev-platform/web...

FROM base AS builder
ENV NODE_ENV=production
COPY --from=deps /pnpm /pnpm
COPY . .
RUN pnpm install --frozen-lockfile --filter @ai-dev-platform/web... --prod=false   && pnpm --filter @ai-dev-platform/web build

FROM gcr.io/distroless/nodejs20-debian12:nonroot AS runner
ENV NODE_ENV=production
WORKDIR /app
COPY --from=builder /app/apps/web/.next/standalone ./
COPY --from=builder /app/apps/web/.next/static ./apps/web/.next/static
COPY --from=builder /app/apps/web/public ./apps/web/public
USER nonroot
EXPOSE 3000
ENV PORT=3000
CMD ["apps/web/server.js"]
