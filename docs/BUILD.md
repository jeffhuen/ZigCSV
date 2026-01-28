# ZigCSV Build Requirements

ZigCSV uses [Zigler](https://github.com/ityonemo/zigler) to compile Zig code into a NIF (Natively Implemented Function). Unlike Rust-based NIFs that often use precompiled binaries, ZigCSV compiles on-demand during `mix compile`.

## How It Works

When you run `mix compile`, Zigler automatically:
1. Downloads the Zig compiler (~40MB) to `~/.cache/zig/` (one-time)
2. Compiles the NIF for your platform (~5 seconds)
3. Links it into your application

No manual Zig installation required for development.

## Comparison: Zig vs Rust NIF Ecosystem

| Aspect | ZigCSV (Zigler) | Rust NIFs (rustler_precompiled) |
|--------|-----------------|--------------------------------|
| **Build model** | Compile on-demand | Download precompiled binary |
| **First compile** | ~5 seconds + Zig download | Instant (binary download) |
| **Zig/Rust required** | Yes (auto-downloaded) | No (precompiled) |
| **Cross-platform** | Zig cross-compiles natively | 30+ prebuilt binaries |
| **OTP compatibility** | Automatic (uses local headers) | NIF versions 2.15/2.16/2.17 |
| **CI/CD complexity** | Simple (just compile) | Complex (build matrix) |
| **Package size on Hex** | Small (source only) | Large (checksums for all platforms) |

### Why Compile On-Demand?

Zigler's precompiled support is experimental. The Rust ecosystem has mature tooling (`rustler_precompiled`, GitHub Actions) that doesn't exist for Zig yet. The tradeoffs favor compile-on-demand:

- **Simpler**: No 30-build CI matrix, no checksum management
- **Always compatible**: Uses your local OTP headers, works with any Erlang version
- **Fast enough**: Zig compiles in ~5 seconds (vs minutes for Rust)
- **Small package**: No precompiled binaries bloating the Hex package

## Production Deployment

### Docker

Your Dockerfile needs Zig available during the build stage:

```dockerfile
# Build stage
FROM elixir:1.17-otp-27 AS builder

# Install Zig
RUN apt-get update && apt-get install -y wget xz-utils \
    && wget https://ziglang.org/download/0.13.0/zig-linux-x86_64-0.13.0.tar.xz \
    && tar -xf zig-linux-x86_64-0.13.0.tar.xz \
    && mv zig-linux-x86_64-0.13.0 /usr/local/zig \
    && ln -s /usr/local/zig/zig /usr/local/bin/zig

# Or let Zigler download it automatically (requires internet during build)
# Zigler caches to ~/.cache/zig/

WORKDIR /app
COPY mix.exs mix.lock ./
RUN mix deps.get --only prod

COPY . .
RUN MIX_ENV=prod mix compile
RUN MIX_ENV=prod mix release

# Runtime stage - Zig NOT needed
FROM debian:bookworm-slim AS runner
# ... copy release, no Zig required at runtime
```

**Key point**: Zig is only needed at compile time, not runtime. Your final Docker image doesn't need Zig.

### Fly.io

For Fly.io with Elixir buildpacks, Zigler will auto-download Zig during build:

```elixir
# No special configuration needed
# Zigler downloads Zig to build cache automatically
```

### Gigalixir

Gigalixir's Elixir buildpack supports Zigler. Zig is downloaded during slug compilation:

```bash
# In your app directory
git push gigalixir main
# Zigler handles Zig installation automatically
```

### Heroku

Add a custom buildpack or use multi-stage Docker:

```bash
# Option 1: Docker deploy (recommended)
heroku stack:set container

# Option 2: Custom buildpack for Zig
# See: https://github.com/heroku/heroku-buildpack-apt
```

## CI/CD Configuration

### GitHub Actions

```yaml
name: CI
on: [push, pull_request]

jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - uses: erlef/setup-beam@v1
        with:
          elixir-version: '1.17'
          otp-version: '27'

      # Zig is auto-downloaded by Zigler, but you can cache it:
      - name: Cache Zig
        uses: actions/cache@v4
        with:
          path: ~/.cache/zig
          key: zig-${{ runner.os }}-0.13.0

      - run: mix deps.get
      - run: mix compile
      - run: mix test
```

### GitLab CI

```yaml
test:
  image: elixir:1.17-otp-27
  cache:
    paths:
      - ~/.cache/zig/
  script:
    - mix deps.get
    - mix compile
    - mix test
```

## Troubleshooting

### "Zig not found" errors

Zigler auto-downloads Zig, but if it fails:

```bash
# Manual install (Linux)
wget https://ziglang.org/download/0.13.0/zig-linux-x86_64-0.13.0.tar.xz
tar -xf zig-linux-x86_64-0.13.0.tar.xz
export PATH=$PATH:$(pwd)/zig-linux-x86_64-0.13.0

# Manual install (macOS with Homebrew)
brew install zig

# Verify
zig version
```

### Compilation fails on Alpine Linux

Alpine uses musl libc. Add the musl development package:

```dockerfile
FROM elixir:1.17-alpine
RUN apk add --no-cache build-base
```

### Slow compilation in CI

Cache the Zig download and build artifacts:

```yaml
- uses: actions/cache@v4
  with:
    path: |
      ~/.cache/zig
      _build
      deps
    key: ${{ runner.os }}-mix-${{ hashFiles('mix.lock') }}
```

### Memory issues during compilation

Zig compilation is memory-efficient, but if you hit limits:

```bash
# Increase swap (Docker)
--memory-swap=-1

# Or limit parallel compilation
export ZIG_BUILD_PARALLEL=1
```

## Environment Variables

| Variable | Description |
|----------|-------------|
| `ZIG_EXECUTABLE_PATH` | Use a specific Zig binary |
| `ZIG_ARCHIVE_PATH` | Use a specific Zig archive |
| `ZIGLER_STAGING_ROOT` | Custom staging directory |

## Version Compatibility

| ZigCSV | Zigler | Zig | Elixir | OTP |
|--------|--------|-----|--------|-----|
| 0.2.x | 0.15.x | 0.13+ | 1.14+ | 24+ |

## Future: Precompiled NIFs

Zigler has experimental precompiled support, but lacks the mature tooling of `rustler_precompiled`. If the ecosystem matures, ZigCSV may offer precompiled binaries in the future. For now, compile-on-demand provides the best balance of simplicity and compatibility.

See the [Zigler precompiled docs](https://hexdocs.pm/zigler/11-precompiled.html) for experimental usage.
