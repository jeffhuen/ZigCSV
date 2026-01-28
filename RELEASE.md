# Release Process for ZigCSV

## Prerequisites

- All tests passing: `mix test`
- Version updated in `mix.exs`
- `CHANGELOG.md` updated

## Steps

1. Update version in `mix.exs`
2. Update `CHANGELOG.md`
3. Commit: `git commit -am "Bump version to x.y.z"`
4. Create and push tag:
   ```bash
   git tag vx.y.z
   git push origin main --tags
   ```
5. Publish to Hex:
   ```bash
   mix hex.publish
   ```

## Notes

### No Precompiled Binaries

Unlike Rust NIFs with `rustler_precompiled`, ZigCSV compiles on-demand:

- **No 30-build CI matrix** - Users compile for their platform
- **No checksum management** - No precompiled binaries to verify
- **Simpler releases** - Just tag and publish to Hex

### What Users Need

When users `mix deps.get && mix compile`:
1. Zigler auto-downloads Zig compiler (~40MB, cached)
2. NIF compiles in ~5 seconds
3. Ready to use

See [docs/BUILD.md](docs/BUILD.md) for deployment details (Docker, CI/CD, etc.).

## Useful Commands

```bash
# Run tests
mix test

# Check code quality
mix credo --strict
mix dialyzer

# Build docs
mix docs

# Dry run hex publish
mix hex.publish --dry-run
```
