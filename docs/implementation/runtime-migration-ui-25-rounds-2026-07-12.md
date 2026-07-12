# Runtime.MiRust.com Migration UX Improvement Record

Date: 2026-07-12

Scope: 25 concrete experience passes over the retired Runtime compatibility
origin. The default product behavior remains a permanent redirect. These passes
improve route continuity, inspectability, accessibility, security, and fallback
presentation without restoring Runtime.MiRust.com as a competing documentation
authority.

## Completed Passes

1. Preserved the default HTTP 301 migration behavior.
2. Added closest-topic redirects for architecture, browser runtime, model
   format, adapters, breeding, testing, roadmap, docs, glossary, and contact.
3. Kept deep `/docs/...` links mapped to the preserved runtime archive.
4. Kept package files mapped to the preserved package snapshot.
5. Kept `llms.txt` and `llms-full.txt` mapped to current TinyRustLM indexes.
6. Kept old `.uai` requests mapped to preserved runtime memory.
7. Added safe dot-segment rejection to the PHP fallback resolver.
8. Added segment-wise URL encoding for preserved document paths.
9. Restricted forwarded query parameters to bounded `format` and `q` values.
10. Added `/?preview=1` as an inspectable migration surface while leaving
    default requests permanent redirects.
11. Exempted local migration CSS from the Apache catch-all redirect.
12. Added canonical `Link` and HTML canonical destinations for every route.
13. Added noindex/follow behavior so the retired host does not compete in search.
14. Added CSP, nosniff, referrer, permissions, and frame-ancestor protections.
15. Added explicit cache behavior for redirects and no-store behavior for
    previews.
16. Replaced the bare fallback sentence with a clear migration status header.
17. Added a route-specific primary continuation action.
18. Added direct access to the current TinyRustLM browser app.
19. Added a requested-path and resolution-type evidence panel.
20. Added distinct product, developer portal, and archive destination cards.
21. Added a scannable route-continuity table for representative legacy URLs.
22. Added direct machine-reader links to current indexes and archive evidence.
23. Added skip navigation, focus indicators, semantic landmarks, and scoped
    table headers.
24. Added responsive, no-horizontal-overflow layouts plus reduced-motion and
    increased-contrast accommodations.
25. Updated package metadata and README guidance to make the redirect and
    preview contracts durable.

## Acceptance Targets

- A normal root request returns a permanent redirect to the TinyRustLM developer
  portal.
- A known topic request resolves to the closest current topic.
- A deep documentation request preserves its relative archive path.
- `/?preview=1` renders a complete migration map without client JavaScript.
- Preview output has no horizontal document overflow at 390 CSS pixels.
- The compatibility origin remains explicitly noncanonical and noindex.

## Verification Evidence

- PHP 8.5 syntax validation passed for `index.php`.
- Root, architecture, model-format, deep-doc, and `llms.txt` requests returned
  HTTP 301 with their expected route-specific destinations.
- `/architecture/?preview=1` returned HTTP 200 with no-store caching, canonical
  link evidence, noindex/follow, CSP, permissions, referrer, and nosniff headers.
- Chrome/CDP document width matched viewport width at 390, 768, and 1280 CSS
  pixels.
- Automated DOM checks found one `h1`, one `main`, no duplicate IDs, no empty
  links, and the expected route-specific canonical URL.
- Desktop and emulated-mobile screenshots were visually inspected.
- A self-contained favicon removed the compatibility-origin favicon redirect
  and left a clean browser console with no failed resources.
- `git diff --check` passed.
