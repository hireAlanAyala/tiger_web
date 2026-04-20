# Tiger Web development image.
#
# Contains: Zig 0.14.1, Node 22, sqlite3, build tools.
# No host prerequisites — everything is downloaded during build.
#
# Usage:
#   docker build -t focus .
#   cd examples/ecommerce-ts && docker compose up

FROM node:22-bookworm-slim

# System dependencies.
RUN apt-get update && apt-get install -y --no-install-recommends \
    libsqlite3-dev \
    sqlite3 \
    xz-utils \
    curl \
    ca-certificates \
    make \
    g++ \
    inotify-tools \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /opt/focus

# Download Zig 0.14.1 inside the image (no host prerequisite).
RUN curl -sSfL https://pkg.machengine.org/zig/0.14.1/zig-x86_64-linux-0.14.1.tar.xz -o /tmp/zig.tar.xz \
    && echo "24aeeec8af16c381934a6cd7d95c807a8cb2cf7df9fa40d359aa884195c4716c /tmp/zig.tar.xz" | sha256sum -c \
    && mkdir -p zig \
    && tar -xf /tmp/zig.tar.xz -C /tmp \
    && mv /tmp/zig-x86_64-linux-0.14.1/zig zig/ \
    && mv /tmp/zig-x86_64-linux-0.14.1/lib zig/ \
    && mv /tmp/zig-x86_64-linux-0.14.1/doc zig/ \
    && rm -rf /tmp/zig.tar.xz /tmp/zig-x86_64-linux-0.14.1

# Copy framework source.
COPY . .

# Build the SHM native addon.
WORKDIR /opt/focus/addons/shm
RUN npm install

# Pre-build for both ecommerce (full route table) and new projects (empty).
# The zig cache stores both, so focus-internal dev hits cache either way.
WORKDIR /opt/focus
RUN ./zig/zig build -Dsidecar=true && \
    cp generated/routes.generated.zig /tmp/routes_backup.zig && \
    printf 'const message = @import("../message.zig");\nconst http = @import("../framework/http.zig");\npub const Route = struct { operation: message.Operation, method: http.Method, pattern: []const u8, query_params: []const []const u8, handler: type };\npub const routes = [_]Route{};\npub fn is_sidecar_operation(_: message.Operation) bool { return true; }\n' > generated/routes.generated.zig && \
    ./zig/zig build -Dsidecar=true && \
    cp /tmp/routes_backup.zig generated/routes.generated.zig

# Put internal CLI on PATH so `docker run ... sh -c "focus-internal dev"` works.
ENV PATH="/opt/focus:${PATH}"

EXPOSE 3000
