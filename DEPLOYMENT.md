# Runtime.MiRust.com Redirect Deployment

Runtime.MiRust.com is a redirect-only retired host. It must never be packaged
from a working-tree copy or used to serve runtime/model source.

The owner's September 23, 2026 policy requires local validation, GitHub for
source control only, and website publication through the existing FTP/FTPS
hosting workflow. Coherent source checkpoints may be committed with open
release gates recorded. The activation design below has not been established
on the Runtime host; reconcile it with verified FTP/FTPS capabilities before
publication. The recorded misbound Runtime profile remains prohibited. See
`.uai/long-term-memory.uai` for the current owner policy.

## Required Behavior

Redirect verification requires HTTP 301 and exactly one matching `Location`
value. HTTP 302, 307 and 308 do not satisfy this host's exact status contract.
The PowerShell and shell `SelfTest`/`--self-test` modes exercise the live
predicate without making public requests; local fixture success is not deployment evidence.

- `/` redirects to `https://tinyrustlm.mirust.com/developer-portal/`.
- `/docs/*` redirects to `https://tinyrustlm.mirust.com/docs/`, except the retired source-copy route.
- Old package-status URLs redirect to the current developer portal; `.uai/*` redirects to the current public memory-policy page.
- `/docs/workspace.uai` returns terminal HTTP 410 for GET and HEAD.
- Case, one trailing slash, query, and one-layer encoded aliases of that route return the same 410.
- The 410 has no `Location`, declares `Cache-Control: no-store`, `X-Robots-Tag: noindex, nofollow`, `X-Content-Type-Options: nosniff`, `Content-Type: text/plain; charset=UTF-8`, and `Content-Length: 5`.
- The GET body is exactly the five bytes `Gone\n`; HEAD returns no body bytes while retaining `Content-Length: 5`.
- Repeated literal separators that reach the front controller return its exact bounded HTTP 400 response.
- Encoded separators, malformed encoding, NUL/non-ASCII path bytes, and traversal are server-boundary inputs. They must fail closed with HTTP 400 or 404 and no `Location`; they must never resolve to or expose a file.
- `/llms.txt` and `/llms-full.txt` redirect to their current TinyRustLM indexes.
- `/?preview=1` renders the existing migration page without a front-controller rewrite loop.
- `/assets/css/redirect.css` is the sole direct static response. Every other path crosses the front controller even if an obsolete file remains on disk.
- Apache admits that stylesheet only for literal-case GET/HEAD request targets; encoded, case, separator, trailing-slash, and non-GET aliases cross the bounded PHP parser.
- Known stale source, tool, JavaScript, CSS, data, include, and memory paths return redirects, never their file bytes.

`AllowEncodedSlashes` and `MergeSlashes` are server/virtual-host directives;
they cannot be imposed by this repository's `.htaccess`. With Apache's default
`AllowEncodedSlashes Off`, an encoded `/` is rejected as 404 before PHP. A
server configured with `AllowEncodedSlashes NoDecode` can pass it to the
front controller, which rejects it as the exact bounded 400. Both outcomes are
fail-closed. The real-Apache tests exercise the default boundary and, separately,
the application path under an isolated server configuration.

## Exact-Byte Package Gate

`version.json` is the authority for package version and release update time.
The generator hashes raw bytes; it performs no BOM, newline, or CRLF-to-LF
normalization. `PACKAGE-MANIFEST.md` describes the complete redirect payload.
The manifest excludes itself to avoid a circular digest. The historical docs
corpus and its package writer have been retired; history remains in Git.
`docs/workspace.uai` is a permanently forbidden path. Its presence under any
ASCII case spelling rejects Git verification and materialized-root admission.
A commit that restores the retired `docs/` corpus cannot become a release.

Prepare and test the source change before committing:

```powershell
node .\tools\build-runtime-manifests.js --write
node .\tools\build-runtime-manifests.js --check
node --test .\tools\runtime-release.test.js .\tools\build-runtime-manifests_test.js
git diff --check
```

After committing, prove the immutable commit and create a new, absent custody
root directly from its Git blobs. The command also requires the executing
generator bytes to equal the generator blob in that commit:

```powershell
node .\tools\build-runtime-manifests.js --verify-git HEAD
node .\tools\build-runtime-manifests.js --stage-git redirect HEAD <new-custody-root>
node .\tools\build-runtime-manifests.js --verify-custody redirect HEAD <new-custody-root>
node .\tools\build-runtime-manifests.js --verify-release redirect HEAD <content-addressed-release-directory>
```

The staging command first regenerates the package manifest from the selected commit,
requires the committed manifest blobs to match, materializes only exact Git
blob bytes, rejects an existing custody root, and computes one release directory
name from the complete package SHA-256. The custody root contains exactly that
one release directory. Package files and directories are permission-sealed
against ordinary writes, and the emitted proof binds commit, tree, generator,
package identity, seal policy, and activation policy without recording a local
path. The seal is an invalidation detector, not a claim that an administrator
cannot change permissions; reverify custody immediately before transfer.

`--verify-custody` requires the one-child custody layout, content-addressed
name, exact files/directories/bytes, and read-only seal. `--verify-release`
applies the same package/name/seal proof to an inactive destination release.
Both reject links, extra files, empty extra directories, missing files,
normalized bytes, renamed releases, and writable package entries.

## Atomic Activation Contract

The active Runtime document root must resolve through one deployment-owned
release pointer. Activation is permitted only under all of these invariants:

1. Transfer the sealed package into a wholly new inactive directory on the
   destination filesystem. Never copy, synchronize, or delete files inside the
   currently active release directory.
2. The destination leaf name must equal the emitted content-addressed release
   name. The destination must contain only `.htaccess`,
   `PACKAGE-MANIFEST.md`, `assets/css/redirect.css`, `index.php`, and
   `version.json`, with only `assets` and `assets/css` as child directories.
3. Run `--verify-release` against the inactive destination using the exact
   committed source identity. A failed or ambiguous proof forbids activation.
4. Create a new pointer beside the current pointer, bind it to the verified
   inactive release, and replace the current pointer with one same-filesystem
   atomic rename. Retain the predecessor only until the new release passes
   its required readback and becomes the verified replacement.
5. If the hosting platform cannot prove an atomic pointer or equivalent
   document-root switch, stop. A direct `rsync`, FTP upload, overlay copy, or
   file-by-file replacement of the live root is not an activation transaction.
6. Perform HTTPS readback after the switch. Once replacement is verified,
   remove superseded release bytes and operation-owned failed stages using
   exact ownership and path checks; retain compact receipts and Git history.

The repository intentionally records no production credential, host identity,
document-root path, release-parent path, or activation command. Those values
and the platform-specific atomic primitive require separate deployment
authority. The known incorrect FileZilla profile remains prohibited.

The release-scoped `.gitattributes` policy requests LF checkout bytes for text
files, but that convenience is not release evidence. The committed blob, sealed
custody proof, destination release proof, and atomic activation observation are
the release authorities.

## Post-Deployment Verification

Run one of these equivalent verifiers after an authorized redirect deployment:

```powershell
& .\tools\verify-runtime-mirust.ps1
```

```bash
./tools/verify-runtime-mirust.sh
```

Both verifiers require exact 410 and application-level 400 status, headers,
length, and body bytes for routes that reach the front controller. Server-
boundary encodings may be rejected before `.htaccess`; those observations are
separately typed and accept only bounded HTTP 400/404 responses with no
`Location`. The shell verifier uses a custom HTTP/1.1 HEAD request that retains
unexpected wire bytes, and the PowerShell verifier reads bounded HTTP/1.1 bytes
through a certificate-validated TLS socket. Local controlled-socket tests prove
that both the good response and a deliberately illegal HEAD body are
distinguished. No client-side abstraction is counted as raw-body proof.

The verifiers also probe known stale JavaScript, CSS, memory, data, include,
source, and tool paths and require redirects rather than bytes. Every ordinary
Runtime route must return its exact canonical destination, and each unique
destination must return HTTP 200. A correct redirect to a missing destination
is a failed deployment.

Do not deploy through a credential profile until its host and document root
have been independently verified as `runtime.mirust.com`. Package generation,
local tests, and stage creation are not deployment or public readback evidence.
