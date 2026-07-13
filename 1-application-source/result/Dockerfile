FROM node:18-slim

# add curl for healthcheck and CA certificates for TLS/RDS connections
RUN apt-get update && \
    apt-get install -y --no-install-recommends curl tini ca-certificates && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /usr/local/app

# have nodemon available for local dev use (file watching)
RUN npm install -g nodemon

COPY package*.json ./

RUN npm ci && \
    npm cache clean --force && \
    mv /usr/local/app/node_modules /node_modules

COPY . .

# Set default environment variables for both the application and PostgreSQL connection
# Note: Secrets like PG_PASSWORD should NOT be hardcoded; use runtime env vars or secrets management
ENV PORT=80 \
    PG_HOST=db \
    PG_PORT=5432 \
    PG_USER=postgres \
    PG_DATABASE=postgres

# Create non-root user for security
RUN useradd -m -u 1001 appuser
RUN chown -R appuser:appuser /usr/local/app /node_modules

# Switch to non-root user
USER appuser

EXPOSE 80

# Add HEALTHCHECK for container monitoring
HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
    CMD curl -f http://localhost:80/ || exit 1

ENTRYPOINT ["/usr/bin/tini", "--"]
CMD ["node", "server.js"]
