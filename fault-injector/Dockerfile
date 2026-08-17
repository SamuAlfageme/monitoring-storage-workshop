# syntax=docker/dockerfile:1
# Cross-build friendly: compile on BUILDPLATFORM (native on Mac), copy into TARGETPLATFORM image.
# Final stage has no RUN - avoids QEMU/emulation failures when pushing linux/amd64 from arm64.
ARG BUILDPLATFORM
ARG TARGETPLATFORM

FROM --platform=$BUILDPLATFORM node:20-alpine AS builder
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci
COPY tsconfig.json ./
COPY src ./src
RUN npm run build

FROM --platform=$BUILDPLATFORM node:20-alpine AS deps
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci --omit=dev

FROM --platform=$TARGETPLATFORM node:20-alpine
WORKDIR /app
COPY --from=deps /app/node_modules ./node_modules
COPY --from=builder /app/dist ./dist
COPY package.json ./
COPY src/ui ./dist/ui
EXPOSE 8080
CMD ["node", "dist/server.js"]
