# Runtime.MiRust.com Compatibility Redirect Package

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

Deploy this package only to the actual `runtime.mirust.com` web root. The FileZilla entry currently labeled `Runtime.MiRust.com` points at the TinyRustLM.MiRust.com FTP root and must not be used to clear or overwrite Runtime.
