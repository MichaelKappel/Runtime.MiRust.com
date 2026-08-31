# Runtime.MiRust.com Retired Host Redirect Package

Runtime.MiRust.com is retired as a separate documentation authority.

The default response remains a permanent route-aware redirect. A human-readable
migration map is available at `/?preview=1` for route inspection, accessibility
review, and deployment verification without weakening the canonical redirect.

The current developer portal is:

- <https://tinyrustlm.mirust.com/developer-portal/>

The preserved legacy runtime archive is:

- <https://tinyrustlm.mirust.com/docs/runtime-portal/index.md>
- <https://tinyrustlm.mirust.com/docs/runtime-portal/MANIFEST.md>

Legacy topic routes such as `/architecture/`, `/browser-runtime/`,
`/model-format/`, and `/proof-testing/` now resolve to their closest current
TinyRustLM pages instead of collapsing every request onto one generic page.

The former `/docs/workspace.uai` source-authority copy is physically absent.
Its canonical, case, trailing-slash, query, and one-layer encoded aliases
terminally return the same bounded HTTP 410 for GET and HEAD. It is never
redirected into another public source copy.

The redirect stylesheet is the sole direct static file. All other requests go
through one bounded parser, so obsolete JavaScript, CSS, memory, source, data,
include, and tool files cannot bypass redirects merely because an overlay left
them on disk. Apache checks the literal request target and GET/HEAD method before
allowing that one file through. Repeated or boundary separators, traversal, backslashes, residual
percent escapes, encoded delimiters, and non-ASCII path bytes fail closed.
Inputs that reach PHP receive its bounded HTTP 400; Apache may reject encoded
separators earlier with HTTP 404 because `AllowEncodedSlashes` is a server-only
directive and cannot be set in `.htaccess`.

Release packages are created only from a verified Git commit with
`tools/build-runtime-manifests.js`. The manifest and fresh custody stage bind
exact blob bytes and the executing generator blob. The sole staged release is
named by its complete package SHA-256 and permission-sealed; destination proof
must pass before one atomic release-pointer replacement. Direct synchronization
into the active web root is forbidden. `docs/workspace.uai` is permanently
forbidden, and release verification rejects every extra file, directory, link,
writable entry, rename, or byte difference. Working-tree line-ending
normalization is not release evidence. Run
`node --test tools/runtime-release.test.js` for the local contract suite and
follow [DEPLOYMENT.md](DEPLOYMENT.md) for immutable staging and readback.

Deploy this package only to the actual `runtime.mirust.com` web root. The FileZilla entry currently labeled `Runtime.MiRust.com` points at the TinyRustLM.MiRust.com FTP root and must not be used to clear or overwrite Runtime.
