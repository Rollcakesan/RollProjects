FROM node:22-alpine AS build

WORKDIR /app

COPY package.json package-lock.json ./
RUN npm ci

COPY client ./client
COPY public ./public
RUN npm run build

FROM node:22-alpine

ENV NODE_ENV=production
WORKDIR /app

COPY --chown=node:node package.json ./
COPY --chown=node:node src ./src
COPY --from=build --chown=node:node /app/public ./public

USER node
EXPOSE 8080

CMD ["node", "src/server.mjs"]
