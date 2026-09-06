FROM node:22-alpine AS build
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci
COPY tsconfig.json tsconfig.build.json eslint.config.js ./
COPY src ./src
RUN npm run build

FROM node:22-alpine AS runtime
RUN apk add --no-cache ffmpeg
WORKDIR /app
ENV NODE_ENV=production PORT=8090
COPY package.json package-lock.json ./
RUN npm ci --omit=dev && npm cache clean --force
COPY --from=build /app/dist ./dist
USER node
EXPOSE 8090
HEALTHCHECK --interval=15s --timeout=3s --start-period=10s --retries=3 CMD wget -qO- http://127.0.0.1:8090/readyz >/dev/null || exit 1
CMD ["node", "dist/src/index.js"]
