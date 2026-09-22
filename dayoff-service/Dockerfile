FROM node:22-alpine
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci --omit=dev --ignore-scripts && npm cache clean --force
COPY src ./src
COPY apns.js ./apns.js
RUN mkdir /data && chown node:node /data
USER node
ENV NODE_ENV=production HOST=0.0.0.0 PORT=8081 DATA_DIR=/data
EXPOSE 8081
HEALTHCHECK --interval=30s --timeout=3s --start-period=30s --retries=3 CMD node -e "fetch('http://127.0.0.1:8081/health').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))"
CMD ["node", "src/server.js"]
