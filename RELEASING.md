# Releasing AutoFuse

How to publish AutoFuse on GitHub and cut auto-updating releases via Sparkle.

## One-time setup

### 1. Publish the repo
```bash
gh repo create Fasen24-AI/autofuse --public --source=. --remote=origin --push
```
The repo name `Fasen24-AI/autofuse` is already referenced by `appcast.xml`,
the README, and the CI workflows — keep it consistent or update those URLs.

### 2. GitHub Pages (serves the Sparkle appcast)
The app's `SUFeedURL` is `https://fasen24-ai.github.io/autofuse/appcast.xml`.
Enable Pages (Settings → Pages → deploy from `main`, root) so `appcast.xml` at the
repo root is served at that URL.

### 3. Sparkle EdDSA signing keys (REQUIRED for auto-update to verify)
Auto-update is currently wired but **not yet verifiable**: `build.sh`'s Info.plist
has `SUFeedURL` but **no `SUPublicEDKey`**. Until that's added, Sparkle will reject
every update. To fix, once:
```bash
brew install --cask sparkle    # or download Sparkle's tools
# Generates a private key in the login keychain and prints the PUBLIC key:
./bin/generate_keys              # from the Sparkle distribution
```
Take the printed public key and add it to the Info.plist block in `build.sh`:
```xml
<key>SUPublicEDKey</key>
<string>PASTE_PUBLIC_KEY_HERE</string>
```
The **private** key stays in your keychain — never commit it.

## Cutting a release

1. **Bump the version** in `build.sh` (`CFBundleVersion` / `CFBundleShortVersionString`)
   and add a `## [X.Y.Z]` section to `CHANGELOG.md`.
2. **Tag and push** — this triggers `.github/workflows/release.yml`:
   ```bash
   git tag vX.Y.Z && git push origin vX.Y.Z
   ```
   The workflow compiles, runs `test.sh`, builds the bundle, and creates a GitHub
   Release with notes extracted from `CHANGELOG.md`.
3. **Distributable archive.** `build.sh` already produces it: after installing the
   `.app` it runs `ditto -c -k --keepParent` to emit `AutoFuse-X.Y.Z.zip` in the
   repo root, and `release.yml` (which runs `build.sh`) uploads `AutoFuse-*.zip`
   to the GitHub Release. Nothing manual needed here — just make sure `VERSION`
   in `build.sh` matches the tag.
4. **Sign for Sparkle and update the appcast:**
   ```bash
   ./bin/sign_update AutoFuse-X.Y.Z.zip   # prints sparkle:edSignature + length
   ```
   Add an `<item>` to `appcast.xml` using the template in that file, filling the
   real `sparkle:edSignature`, `length`, and the release download URL. Commit and
   push `appcast.xml` (GitHub Pages then serves it; running apps pick up the update).

## Pre-publication checklist
- [ ] `SUPublicEDKey` added to `build.sh` Info.plist (step 3) — else auto-update fails.
- [ ] `release.yml` / `build.sh` agree on the artifact name (both `AutoFuse-*.zip`).
- [ ] `bash test.sh` green locally (CI also runs it).
- [ ] No secrets committed: private SSH keys, Sparkle private key, real `~/.config/autofuse/config.json`.
- [ ] `LICENSE` (PolyForm Shield 1.0.0) and per-package `license` fields consistent.
