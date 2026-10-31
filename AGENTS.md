# KubeConfig

macOS 26 kubeconfig editor (Swift package, SwiftUI, no Xcode project).

## Layout

- `Sources/KubeConfigCore`: pure Swift. Document model, import plans, diff, draft changes, YAML highlighting, backups and the configuration store. Tested headless in `Tests/KubeConfigCoreTests`.
- `Sources/KubeConfig`: SwiftUI app layer. `Tests/KubeConfigAppTests` covers `AppModel`.
- Keep logic in Core where possible so it stays testable.

## Commands

```sh
make test                 # swift test
make bundle               # build + sign build/KubeConfig.app
make run CONFIG=debug     # build and open the separate KubeConfig Dev app
make install-production   # copy to /Applications
make dmg                  # build/KubeConfig-<version>.dmg (release build)
make cask                 # build/kubeconfig.rb from packaging/kubeconfig.rb
```

User documentation is in `docs/USAGE.md`; keep it in step with behaviour changes.

## Commits

- Use semantic commit messages: `<type>[optional scope]: <description>` (Conventional Commits).
- Choose the type that describes the change, such as `fix`, `feat`, `refactor`, `perf`, `test`, `docs`, or `chore`. Example: `fix(store): keep symlinks when applying`.

## Releasing

Releases are not notarized (no Developer ID). Build locally; there is no CI.

Use `vX.X.X` for release titles and tags. Release notes contain only concise changelog bullets and a `Full Changelog: [vA...vB](https://github.com/ivalkenburg/kubeconfig/compare/vA...vB)` line comparing the previous and new releases. The first release has no comparison line.

1. `make test`.
2. Bump `CFBundleShortVersionString` (`major.minor.fix`) and increment `CFBundleVersion` in `Resources/Info.plist`. Commit as `chore: bump version to X.X.X`.
3. `make dmg IDENTITY="Apple Development: lolrogii@gmail.com (KSV53B47DT)" SIGN_FLAGS="--options runtime --timestamp"`. Always pass `IDENTITY` explicitly; the default picks the first Apple Development cert in the keychain, which may be the wrong one.
4. Tag `vX.X.X`, push the commit and tag, then `gh release create vX.X.X build/KubeConfig-X.X.X.dmg`.
5. `make cask` writes `build/kubeconfig.rb`; copy it to `Casks/kubeconfig.rb` in `ivalkenburg/homebrew-tap` and commit it there.
