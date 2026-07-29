# Release Process

MirrorNeuron core releases from Git tags. The tag is the public source of truth for the release version.

## Versioning Policy

Use Semantic Versioning tags with a leading `v`:

- `vMAJOR.MINOR.PATCH` for stable releases
- `vMAJOR.MINOR.PATCH-rc.N` for release candidates
- `vMAJOR.MINOR.PATCH-beta.N` or `vMAJOR.MINOR.PATCH-alpha.N` for prereleases

Examples:

- `v1.0.1` = patch release
- `v1.1.0` = minor release
- `v2.0.0` = major release
- `v1.1.0-rc.1` = prerelease

CI build numbers are for internal artifacts only. Public releases use clean SemVer tags, not build-number versions such as `1.0.0-build123`.

## Distribution Policy

MirrorNeuron core publishes GitHub Release OTP tarballs and a public Docker
runtime image. GitHub Actions builds the OTP assets; the multi-platform Docker
image is published from the local release machine by `mn-deploy/release_all.sh`.
Core does not publish runtime releases to Hex, PyPI, npm, or a custom source
ZIP.

OTP releases are OS and architecture specific. A release built for Linux will not run on macOS, and an x64 release will not run on ARM64.

Each tagged release uploads:

- `MirrorNeuron-vX.Y.Z-darwin-arm64-otp-release.tar.gz`
- `MirrorNeuron-vX.Y.Z-linux-x64-otp-release.tar.gz`
- `MirrorNeuron-vX.Y.Z-linux-arm64-otp-release.tar.gz`
- `SHA256SUMS.txt`

After the tag workflow succeeds, the local release orchestrator builds the
tagged source for `linux/amd64` and `linux/arm64` and publishes it to GAR as:

- `us-central1-docker.pkg.dev/mirrorneuron-public-packages/mirrorneuron-runtime/mirror-neuron-core:vX.Y.Z`
- `us-central1-docker.pkg.dev/mirrorneuron-public-packages/mirrorneuron-runtime/mirror-neuron-core:X.Y.Z`
- `us-central1-docker.pkg.dev/mirrorneuron-public-packages/mirrorneuron-runtime/mirror-neuron-core:latest`

Installers use the immutable `vX.Y.Z` tag. The image carries OCI version and
revision labels matching the release tag and commit.

For a release backfill, run
`mn-deploy/publish_public_core_to_google_artifact_registry.sh --apply --version
vX.Y.Z`. On Apple Silicon the publisher registers QEMU amd64 emulation and
uses Erlang's QEMU-compatible single-mapped JIT setting while building.

## Create a Stable Release

Before creating a release, make sure `main` is clean and tests pass locally.

```bash
git checkout main
git pull
mix deps.get
mix format --check-formatted
mix test
MIX_PROJECT_VERSION=1.0.1 MIX_ENV=prod mix release --overwrite
git tag v1.0.1
git push origin v1.0.1
```

Pushing the tag starts the release workflow. The workflow validates the tag,
runs tests, builds platform-specific OTP releases, writes SHA256 checksums,
creates a GitHub Release, and uploads the OTP tarballs plus checksum file.
The workspace-level `mn-deploy/release_all.sh` then publishes and verifies the
multi-platform GAR runtime image from the local release machine.

## Create a Prerelease

```bash
git checkout main
git pull
git tag v1.0.1-rc.1
git push origin v1.0.1-rc.1
```

Prerelease tags create GitHub prereleases with the same OTP tarball assets.

## Install from a Release

Download the tarball that matches the target machine:

- Apple Silicon macOS: `darwin-arm64`
- Linux x64: `linux-x64`
- Linux ARM64: `linux-arm64`

Verify the checksum:

```bash
shasum -a 256 -c SHA256SUMS.txt
```

Extract and start the runtime:

```bash
tar -xzf MirrorNeuron-v1.0.1-linux-x64-otp-release.tar.gz
cd mirror_neuron
bin/mirror_neuron start
```

The Elixir project version is derived from the Git tag at release time through `MIX_PROJECT_VERSION`. Stable tags such as `v1.0.1` build project metadata as `1.0.1`, without the leading `v`.
