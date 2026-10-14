FROM node:22-alpine
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci --omit=dev --ignore-scripts && npm cache clean --force
COPY src ./src
COPY apns.js ./apns.js
USER node
# One image for both Cloud Run workloads: the service runs the CMD below and
# the Job overrides it with `node src/job.js`. Cloud Run injects PORT itself;
# 8080 is only the fallback for running the image by hand.
ENV NODE_ENV=production HOST=0.0.0.0 PORT=8080
CMD ["node", "src/server.js"]
