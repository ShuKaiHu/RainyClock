FROM node:22-alpine

WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci --omit=dev --ignore-scripts && npm cache clean --force
# Copy the directory rather than naming each file — .gcloudignore and
# .dockerignore already keep the tests out, and an explicit list silently ships
# a broken image the moment a new module is added.
COPY . .

USER node
ENV NODE_ENV=production
EXPOSE 8080
CMD ["node", "server.js"]
