# The build stage runs on the builder's own CPU. Every dependency is plain JavaScript (pg without
# pg-native), so its output runs on any CPU and multi-arch builds need no emulation.
# The service is an ES module (NestJS 12 is ESM-only), so package.json ships with dist/ for "type": "module".
FROM --platform=$BUILDPLATFORM node:25-alpine AS build
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci
COPY tsconfig.json ./
COPY src ./src
RUN npm run build && find dist -name "*.spec.js" -delete && npm prune --omit=dev

FROM gcr.io/distroless/nodejs24-debian13:nonroot
WORKDIR /app
COPY --from=build /app/package.json ./
COPY --from=build /app/node_modules ./node_modules
COPY --from=build /app/dist ./dist
COPY db ./db
EXPOSE 8080
CMD ["dist/main.js"]
