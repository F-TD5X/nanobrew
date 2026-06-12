# Package architecture — what we ship, how we vet it, how we keep it

How nanobrew's package supply works end to end: where bottles come from,
which packages we add next, how we make sure what we ship doesn't carry
known vulnerabilities, and the guarantee that every artifact we have ever
served stays stored and addressable.

Companion docs: `manage.md` (nb-bottles operating guide),
`docs/upstream-registry.md` (registry record format), `SECURITY.md`.

---

## 1. Current inventory

`src/upstream/registry_default.json` — 396 records:

| Upstream type | Count | What it is |
|---|---|---|
| `homebrew_bottle` | 268 | Pinned Homebrew core bottles (sha256 per platform). Tier-1 mirrored to `ghcr.io/justrach/nb-bottles/*`. |
| `github_release` | 68 | Upstream release binaries (24 formulas — ripgrep, gh, uv, … — plus casks). Tier-2 repackage candidates. |
| `vendor_url` | 60 | Direct vendor downloads (mostly casks). |

Two distribution tiers (details in `manage.md`):

- **Tier 1 — mirror:** byte-identical Homebrew bottles under our GHCR
  namespace. Same digests, so the registry's sha256 pins verify unchanged.
- **Tier 2 — repackage:** upstream release binaries re-laid-out into bottle
  form under our namespace, with **new** digests recorded in the registry.

Every artifact is content-addressed: the sha256 in the registry record is
both the download path and the integrity check. nb refuses a blob whose
digest doesn't match the pin.

## 2. Expansion candidates

Rule of thumb: Tier 2 for self-contained static binaries with permissive
licenses; Tier 1 for anything with a dep closure or copyleft duties.

### Tier 2 (repackage from upstream releases)

Already shipping: ripgrep, fd, bat, gh, uv, ruff, mise, just, atuin,
zoxide, starship, lazygit, git-delta, chezmoi, fastfetch, actionlint,
golangci-lint, k9s, git-lfs, podman.

Next wave, by category (all MIT/Apache/BSD unless noted):

- **Shell & files:** eza, dust, duf, dua-cli, broot, sd, choose, yazi,
  zellij, nushell, gum, glow
- **Search & data:** fzf, jq*, yq, gron, jless, fx, dasel, hexyl, tokei
- **Network & HTTP:** xh, curlie, doggo, websocat, grpcurl, oha, hey,
  vegeta, croc, rclone
- **Monitoring:** bottom, btop*, procs, bandwhich, hyperfine, ctop, dive
- **Kubernetes & cloud:** kubectl, helm, kind, minikube, flyctl, doctl,
  skopeo, crane, oras, lazydocker
- **Security tooling:** age, sops, cosign, mkcert, step, gitleaks, trivy,
  grype, syft, osv-scanner (we run several of these in our own pipeline —
  §3 — so shipping them is free dogfooding)
- **Dev runtimes & build:** deno, bun, shfmt, shellcheck*, watchexec,
  task, caddy, restic, kopia, opentofu (MPL-2.0 — fine; note **not**
  terraform/vault/nomad/consul: BSL, do not redistribute)

\* jq/btop/shellcheck publish static release binaries despite being
C/C++/Haskell — verify per-platform coverage before promoting; otherwise
leave them Tier 1.

### Tier 1 (mirror-only — dep closures or copyleft)

Runtimes and the C ecosystem: python, node, go, openjdk, ruby, openssl,
gettext, curl, wget, git, cmake, ffmpeg, postgresql, redis/valkey, sqlite,
neovim, tmux, fish. GPL/LGPL packages stay Tier 1 permanently: mirroring
Homebrew's public bottles byte-identically is the same act Homebrew
performs, and source-offer duties are satisfied upstream.

### Hard exclusions

- BSL/SSPL-licensed (terraform, vault, mongodb tools) — no redistribution.
- Anything without a stable upstream release checksum or tag — no pin, no
  ship.

## 3. Vulnerability assurance

Layered: **provenance in, scanning at publish, continuous rescan of the
stored fleet, revocation out.** Status flags: ✅ implemented, 🔲 planned.

### 3.1 Provenance — trust what we ingest ✅ / 🔲

- ✅ **Digest pinning.** Every asset is pinned by sha256 at registry-build
  time; nb verifies on every download. A tampered mirror or MITM'd
  download fails closed.
- ✅ **Tier-1 transparency.** Mirrored bottles keep Homebrew's digests —
  any third party can compare our blob to `ghcr.io/homebrew/core` byte for
  byte.
- 🔲 **Upstream checksum cross-check (Tier 2).** At `repackage` time,
  verify the downloaded release asset against the upstream-published
  checksum file (`*.sha256`, `checksums.txt`) when one exists, not just
  our own hash of what we received.
- 🔲 **Attestation verification (Tier 2).** Where upstream signs releases,
  verify before repackaging: `gh attestation verify` (GitHub artifact
  attestations — gh, cli ecosystem), cosign/sigstore bundles (uv, ruff,
  many Go tools), minisign (zig). Record the verification method in the
  registry record (`upstream.attestation: "github" | "sigstore" |
  "minisign" | "checksum" | "none"`), so "how much do we trust this" is
  queryable.

### 3.2 Scan at publish — gate the door ✅

`nb_bottles.py scan` (✅ implemented) + a CI step after every `repackage`:

- **SBOM generation:** each bottle tarball is extracted and cataloged
  with syft (`spdx-json`). For Go binaries the embedded buildinfo gives
  exact dependency versions; Rust binaries are opaque unless built with
  `cargo auditable` (uv, ruff do) — for those the GitHub-advisory
  `security_warnings` on the record is the app-level signal.
- **Vulnerability match:** `grype sbom:<sbom>`. (🔲 follow-up:
  osv-scanner as a second database, `govulncheck -mode binary` for
  reachability-aware Go matching.)
- **Gate:** `--gate high` (default) exits non-zero on High/Critical.
  Medium/Low are recorded, not blocking (the alternative — apt — ships
  years-old versions; our baseline is already "latest upstream release").
- **Evidence travels with the bottle:** SBOMs + grype reports land in
  `dist/scan/`, are uploaded as CI artifacts, and `--push-evidence` /
  `push-evidence` attaches them to the bottle's manifest on GHCR as OCI
  referrer artifacts — `oras discover ghcr.io/justrach/nb-bottles/gh:…`
  shows the bottle, its SBOM, and its latest scan verdict in one place,
  anonymously. Evidence is pushed even when the gate fails: a bad
  verdict is the one consumers most need to see. (GHCR's referrers API
  is broken — 303 to an unroutable URL — so we maintain the OCI spec's
  `sha256-<digest>` fallback-tag index, which oras uses transparently;
  re-pushes supersede stale reports of the same artifact type/version.)

First real catch: gh 2.91.0 ships Go 1.26.2 stdlib HIGH CVEs (fixed in
1.26.3) — found on the scan subcommand's first full run.

### 3.3 Continuous rescan — CVEs arrive after you ship ✅

A bottle clean on publish day isn't clean forever. The weekly
`bottles.yml` cron runs `scan --all --gate high` (all four platforms,
Linux included) against fresh grype data:

- A gate hit **fails the job and auto-opens a `security`-labeled issue**
  naming the affected pins, with SBOMs/reports attached as artifacts.
- New Critical/High in the currently-pinned version → the fix is "bump
  the pin" (`nb update-registry` + re-repackage) when upstream has
  patched, or `revoke` (below) when it hasn't.

### 3.4 Revocation + fallback — the recall path ✅

- `nb_bottles.py revoke <name> --advisory CVE-... --reason "..."` marks
  the pin: `resolved.revoked = {advisory, reason}` plus
  `resolved.fallback` = the previous known-good resolved block, sourced
  from registry git history first, else the upstream release *before*
  the pin (digests from the GitHub API or downloaded-and-hashed).
- nb's resolver (`src/upstream/github.zig`) installs the fallback with a
  warning naming the advisory; a revoked pin **without** fallback fails
  closed. The live-API freshness override (#308) is disabled for
  fallbacks — the registry is authoritative on revocations — and
  fallback metadata is never written to the formula cache.
- Because the registry ships embedded in the binary **and** via
  `nb update-registry`, a revocation propagates to existing installs
  without a binary release.
- `unrevoke <name>` clears both fields once the pin moves to a patched
  version.
- `nb doctor` flags *already-installed* revoked versions — machines
  that installed before the revocation get the advisory and the exact
  remove/reinstall fix (which lands on the safe fallback).
- Caveat: falling back only helps when the previous version isn't
  equally affected (e.g. toolchain CVEs like the Go stdlib usually hit
  neighboring releases too — there the remedy is a pin bump, not a
  revoke).

### 3.5 Trust summary per record

The end state is that every registry record answers four questions:

| Question | Field |
|---|---|
| Where did the bytes come from? | `upstream` + `resolved.assets[].url` |
| Are they the bytes we vetted? | `resolved.assets[].sha256` (✅ enforced today) |
| Did upstream vouch for them? | `upstream.attestation` (🔲) |
| Are they currently believed safe? | weekly scan + `revoked` absent (✅) |

## 4. Storage: we keep everything

The guarantee: **every blob we have ever pointed a registry record at
remains pulled-able by its digest, forever.**

- **Immutability:** blobs are addressed by sha256; a "changed" artifact is
  a different digest, a different blob. Version tags
  (`<version>.<platform>`) pin blobs against GHCR garbage collection.
- **Never re-tag** a different blob under an existing version tag — a
  version bump is a new tag + a new registry record (already a rule in
  `manage.md`; the publish path should enforce it 🔲 by refusing to
  overwrite an existing tag with a different digest).
- **Append-only ledger:** `registry_default.json` lives in git, so the
  full history of every pin — which digest, when, replaced by what — is
  the repo's commit history. Superseded records leave the *file* but
  never the history, and their blobs stay tagged on GHCR.
- **Rollback depends on this:** `nb rollback` / `nb switch pkg@version`
  only work if old digests stay fetchable. Revocation (§3.4) marks blobs
  unsafe — it never deletes them, so forensics and reproductions remain
  possible.
- **Cost:** public GHCR packages are free (storage + egress); retention
  costs nothing. The only hygiene rule stands: don't mirror what you
  don't pin.

## 5. Implementation order

1. ✅ `nb_bottles.py scan` — syft SBOM + grype match, severity gate,
   reports in `dist/scan/` + CI artifacts (`bottles.yml`).
2. ✅ Weekly rescan job + auto-issue on new Critical/High.
3. ✅ `revoked`/`fallback` registry fields + nb-side enforcement
   (fallback install with warning, fail-closed without fallback,
   freshness-override and formula-cache exemptions).
4. ✅ `nb doctor` flags installed revoked versions with the fix command.
5. ✅ OCI referrer push for SBOMs + scan reports (`push-evidence`,
   `scan --push-evidence`, weekly rescan pushes automatically).
6. ✅ Tag-overwrite guard in `push_manifest` — version tags are
   immutable; a different digest under an existing tag is refused.
7. 🔲 Upstream checksum/attestation verification in `repackage`; add
   `upstream.attestation` to records.
8. 🔲 osv-scanner + govulncheck as second/third scanners.

Propagation nuance (verified live): a *fresh* remote-registry cache
shadows a newer embedded registry for up to the 6h TTL — revocations
reach binaries via the published `registry/upstream.json`, so the
commit landing on main is what starts the clock, not a release.
