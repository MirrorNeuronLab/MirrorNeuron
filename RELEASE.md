# Release Process

This repository releases from Git tags. The tag is the public source of truth for a release version.

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

## Create a Stable Release

Before creating a release, make sure `main` is clean and tests pass locally.

```bash
git checkout main
git pull
git tag v1.0.1
git push origin v1.0.1
```

Pushing the tag starts the release workflow. The workflow validates the tag, runs tests, builds the project, creates a release ZIP, builds an OTP release tarball, writes SHA256 checksums, creates a GitHub Release, and uploads the assets.

## Create a Prerelease

```bash
git checkout main
git pull
git tag v1.0.1-rc.1
git push origin v1.0.1-rc.1
```

Prerelease tags create GitHub prereleases.

## Elixir OTP Release Assets

The Elixir project version is derived from the Git tag at release time. Stable tags such as `v1.0.1` build project metadata as `1.0.1`, without the leading `v`.

Each tagged release uploads:

- `MirrorNeuron-vX.Y.Z.zip`
- `MirrorNeuron-vX.Y.Z-otp-release.tar.gz`
- `SHA256SUMS.txt`

This repository does not publish to Hex or Docker as part of the release workflow.
