# Focus — production deployment image.
#
# For development, use the native focus binary: focus dev src/
# This Dockerfile is for building container images for deployment only.
#
# Usage:
#   docker build -t myapp .
#   docker run -p 3000:3000 myapp

FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    libsqlite3-0 \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY . .

# The focus binary must be pre-built for the target platform.
# Build with: zig build focus -Doptimize=ReleaseSafe -Dtarget=x86_64-linux
# Then copy zig-out/bin/focus into the project before docker build.

EXPOSE 3000
CMD ["./zig-out/bin/focus", "start", "src/"]
