# Stage 1: Build
FROM mcr.microsoft.com/dotnet/sdk:8.0 AS build
WORKDIR /src

# Copy the project file and restore dependencies
COPY Worker.csproj .
RUN dotnet restore

# Copy the rest of the source code and build
COPY . .
RUN dotnet publish -c Release -o /app/publish

# Stage 2: Runtime
FROM mcr.microsoft.com/dotnet/runtime:8.0 AS runtime
WORKDIR /app

# Copy the published output from the build stage
COPY --from=build /app/publish ./

# Set environment variables (can be overridden at runtime)
# Note: Secrets like DB_PASSWORD should NOT be hardcoded; use runtime env vars or secrets management
ENV DB_HOST=db
ENV DB_USERNAME=postgres
ENV DB_NAME=postgres
ENV REDIS_HOST=redis

# Create non-root user for security
RUN useradd -m -u 1000 appuser
RUN chown -R appuser:appuser /app

# Switch to non-root user
USER appuser

# Add HEALTHCHECK for container monitoring
HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
    CMD dotnet Worker.dll --health || exit 1

# Define the entry point
ENTRYPOINT ["dotnet", "Worker.dll"]
