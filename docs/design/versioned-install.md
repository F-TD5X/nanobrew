# Versioned Install (`nb install pkg@1.2.3`) — design doc

Status: **Phase 1 (Homebrew bottles) implemented.** Phase 2 (deb) not yet started.
Tracks: [#300](https://github.com/justrach/nanobrew/issues/300) — "why is there no docs on
syntax to install a specified version of a package".

Implementation: `src/api/ghcr.zig` (registry resolver), `resolveVersionPin` /
`buildPinnedFormula` / `offerLatest` in `src/main.zig`, and
`DepResolver.addResolved` in `src/resolve/deps.zig`. Decisions taken: highest
rebuild auto-selected; versioned installs are auto-pinned; deps resolved against
the current formula with a warning; offer-latest (not auto-install) on miss.

---

## Goal

Let users install a **specific, older version** of a package, e.g.:

```bash
nb install hexyl@0.17.0
nb install wget@1.21.3
```

Today this fails: `nb` only knows about the *current* version published by the
upstream registry. The part after `@` is allowed by the name validator
(`isPackageNameSafe`, <src/main.zig> ~L331) but is never parsed as a version —
it is passed verbatim to the formula API, which only resolves when a *versioned
formula* of that exact name exists (e.g. `python@3.11`, `node@22`).

This doc scopes the work to do it properly, where it can be done reliably.

---

## Current state (what already exists)

These are the load-bearing pieces we can reuse — versioned install is mostly
**wiring**, not new subsystems:

- **ghcr token auth + blob download + streaming SHA256 verify** already exist in
  `src/net/downloader.zig`:
  - `fetchGhcrTokenUncached()` — anonymous bearer token for
    `repository:homebrew/core/<name>:pull` (L321).
  - `downloadOneWithClient()` — downloads a `ghcr.io/.../blobs/sha256:<digest>`
    URL with the `Authorization: Bearer` header and verifies `expected_sha256`
    (L374+).
- **Platform → bottle-tag mapping** exists in `src/api/formula.zig`:
  `BOTTLE_TAG` (e.g. `arm64_tahoe`, `x86_64_linux`) + `BOTTLE_FALLBACKS`.
- **Formula struct + install pipeline** consume `version`, `bottle_url`,
  `bottle_sha256` (`src/api/formula.zig`, `src/api/client.zig` L757). If we can
  produce a `Formula` with an older version + the right bottle blob, the rest of
  the install flow is unchanged.
- **Version comparison** in `src/version.zig` (`compareVersions`, `isNewer`).

What's **missing**: a way to resolve `name@version` → (bottle URL, sha256) for a
version that is no longer the current one.

---

## Feasibility by source (validated against the live registry)

| Source            | Verdict       | Why |
|-------------------|---------------|-----|
| Homebrew bottles  | **Doable**    | Old bottles persist in GHCR; queryable by tag. |
| Versioned formulae (`python@3.11`) | **Already works** | Distinct formula names. |
| Deb (`--deb`)     | **Easy**      | APT `Packages` index lists every version + sha256. |
| Casks (`--cask`)  | **Out of scope** | Cask API exposes only the current version; no history. |

### Validation evidence (Homebrew / GHCR)

GHCR retains old bottle tags. For `hexyl`:

```
GET https://ghcr.io/v2/homebrew/core/hexyl/tags/list
  → ["0.8.0","0.9.0", ... ,"0.16.0","0.17.0"]
```

Each tag has an OCI image-index manifest listing one entry per platform:

```
GET https://ghcr.io/v2/homebrew/core/hexyl/manifests/0.17.0
    Accept: application/vnd.oci.image.index.v1+json
    Authorization: Bearer <anon-token>

manifests[].platform        → {os, architecture}
manifests[].annotations:
  org.opencontainers.image.ref.name  → "0.17.0.arm64_sequoia"   (== <version>.<BOTTLE_TAG>)
  sh.brew.bottle.digest              → "<bottle blob sha256>"
```

The bottle download URL is then:

```
https://ghcr.io/v2/homebrew/core/<name>/blobs/sha256:<sh.brew.bottle.digest>
```

Critically, `ref.name`'s suffix is exactly our existing `BOTTLE_TAG` /
`BOTTLE_FALLBACKS` value, so platform matching reuses code we already have. And
`sh.brew.bottle.digest` is the blob's sha256, so our existing verified download
path works unchanged.

> The `tags/list` + `manifests/<tag>` calls require the same anonymous bearer
> token we already fetch for blob downloads — no new auth.

---

## Proposed scope (recommended)

**Phase 1 — Homebrew formula bottles.** This is the case in the issue
(`hexyl@0.17.0`). Highest user value.

**Phase 2 — Deb packages.** Low effort; the `Packages` parser already keeps
every version, the index builder just collapses them (`map.put` overwrites,
`src/deb/index.zig` L140). Phase 2 = key the index on `name@version` / keep a
multi-version list, then select the requested version.

**Out of scope:** casks (no version history in the API).

---

## Syntax & disambiguation

`nb install <name>@<spec>` where `<spec>` is either:

1. **A real versioned-formula name suffix** — e.g. `python@3.11`, `node@22`,
   `openssl@3`. Already works; must keep working.
2. **A pinned version** — e.g. `hexyl@0.17.0`, `wget@1.21.3`.

These look identical. Disambiguation rule (cheap, no extra network on the happy
path):

```
1. Try the existing formula lookup for the FULL string "name@spec".
   - If it resolves (200) → it's a versioned formula. Done, unchanged behavior.
2. Else, if "spec" looks like a version (matches /^[0-9][0-9A-Za-z._+-]*$/):
   - Treat it as a version pin: base = "name", target_version = "spec".
   - Run the ghcr version-resolve path (below).
3. Else → formula-not-found (current behavior).
```

This ordering means `python@3.11` keeps hitting the real formula and never
touches the ghcr tag path, while `hexyl@0.17.0` (no such formula) falls through
to version-pin resolution.

> Edge case: Homebrew rebuild/revision suffixes (`0.10.0_1`, `0.10.0_1-1` appear
> in real tag lists). Accept a user `@0.10.0` by matching the newest tag whose
> version component equals the request; allow exact match on the full tag too.

---

## Resolution path for a pinned version (Phase 1)

New helper, e.g. `src/api/ghcr.zig` (or extend `client.zig`):

```
resolveVersionedBottle(alloc, client, name, version) !VersionedBottle
  1. token   = fetchGhcrToken(repo="homebrew/core/<name>")        // reuse downloader logic
  2. manifest = GET manifests/<version>  (Accept: oci.image.index) // 404 → BottleVersionNotFound
  3. for each manifests[] entry:
       ref = annotations["org.opencontainers.image.ref.name"]      // "<ver>.<tag>"
       tag = ref after the first '.'
       if tag == BOTTLE_TAG  → exact match, pick it
       else remember if tag ∈ BOTTLE_FALLBACKS                     // ranked like findBottleTag
  4. digest = annotations["sh.brew.bottle.digest"] of the chosen entry
  5. return {
       url    = "https://ghcr.io/v2/homebrew/core/<name>/blobs/sha256:" ++ digest,
       sha256 = digest,
       version = version,
     }
```

Then build a `Formula` for install:

- `version`, `bottle_url`, `bottle_sha256` ← from `resolveVersionedBottle`.
- **dependencies / caveats / post_install** ← fetched from the *current*
  formula JSON for the base name (see caveat below).

Feed that `Formula` into the existing resolver/install pipeline. The cellar path
(`Cellar/<name>/<version>`) and the blob cache key (the sha256) naturally
namespace by version, so installing `hexyl@0.17.0` alongside a future `hexyl`
just works.

### Known caveat: dependency drift

The Homebrew API only serves the *current* formula's dependency list. For a
pinned older bottle we resolve deps from the current formula, which may differ
from what that old bottle was actually built against. For leaf CLI tools (the
common case — `hexyl`, `ripgrep`, `fd`) this is almost always fine. For packages
with churny dep graphs it can mismatch.

Decision for v1: **resolve deps from current formula, install the pinned bottle,
and print a one-line warning** that deps were resolved against the latest
formula. Document the limitation. (Fetching the historical formula `.rb` from
`homebrew-core` git history is possible but is a much larger follow-up.)

---

## Fallback behavior (when the version can't be found)

Per the product decision on #300: **offer latest, don't silently install it.**

- If `manifests/<version>` 404s, or no manifest entry matches the platform:

  ```
  nb: hexyl 0.17.0 is not available as a bottle for this platform.
      Available versions: 0.13.1, 0.14.0, 0.15.0, 0.16.0, 0.17.0   (from tags/list)
      The latest version is 0.16.1. Install it with:  nb install hexyl
  ```

  Exit non-zero; install nothing. (We do **not** auto-install latest — we surface
  it as the suggested next command.)
- "Available versions" comes from the `tags/list` call (filter out non-version
  tags / dedupe rebuild suffixes for readability).

---

## Security

- The bottle blob is still verified against `sh.brew.bottle.digest` via the
  existing `expected_sha256` path — same guarantee as current installs.
- Version string is validated by the regex above before being interpolated into
  a URL path (defense-in-depth on top of `isPackageNameSafe`).
- No new endpoints/credentials: same GHCR host, same anonymous pull token.

---

## Integration points (file/line references)

- Arg parsing / name validation: `src/main.zig` `runInstall` (L448),
  `isPackageNameSafe` (~L331) — split `name@version`, route version pins.
- Dependency resolution entry: `nb.deps.DepResolver.resolve` (called L548).
- Formula fetch: `src/api/client.zig` `fetchFormula` (L76) — add a sibling that
  builds a `Formula` from a resolved versioned bottle.
- New: `src/api/ghcr.zig` — `tags/list` + `manifests/<tag>` fetch & parse,
  reusing token logic currently private to `src/net/downloader.zig` (factor
  `fetchGhcrToken*` into a shared spot).
- Bottle download: unchanged — `src/net/downloader.zig` `downloadOne`.
- Deb (Phase 2): `src/deb/index.zig` `buildIndex` (L140) — stop collapsing
  versions; `src/deb/resolver.zig` — select requested version.

---

## Testing

- Unit: `name@version` disambiguation (versioned-formula vs version-pin vs junk).
- Unit: OCI image-index JSON parse → pick correct platform entry via
  `BOTTLE_TAG`/`BOTTLE_FALLBACKS`; extract blob digest.
- Unit: version-spec validation regex (accept `0.17.0`, `1.21.3`, `0.10.0_1`;
  reject `../x`, `@`, empty).
- Integration (network-gated, like existing GHCR tests): resolve a known old
  bottle (e.g. `hexyl@0.16.0`) and verify URL + sha256 shape; assert 404 path
  produces the "offer latest" message.
- Regression: `nb install python@3.11` still routes to the real versioned
  formula and never hits the tag path.

---

## Open questions

1. Rebuild/revision suffixes: when a user asks `@0.10.0` and only `0.10.0_1`
   exists, auto-pick the highest rebuild, or require exact? (Proposed:
   auto-pick highest rebuild.)
2. Should pinned installs auto-`nb pin` the result so a later `nb upgrade`
   doesn't clobber the chosen version? (Leaning yes — surprising otherwise.)
3. Deb Phase 2: full Debian version-constraint operators (`>=`, `<<`) or exact
   `=` only for v1? (Proposed: exact only.)
4. Dependency drift (above): acceptable to ship v1 with current-formula deps +
   warning, or block on historical dep resolution? (Proposed: ship with
   warning.)
