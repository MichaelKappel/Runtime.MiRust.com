# Runtime.MiRust.com Redirect Package Manifest

- Status: retired redirect package
- Updated UTC: 2026-09-12T16:13:08Z
- Package version: 1.2.0
- Canonical developer portal: https://tinyrustlm.mirust.com/developer-portal/
- Files excluding this manifest: 4
- Exact payload bytes excluding this manifest: 23750

This manifest describes the complete Runtime web-root redirect payload:
the front controller, its stylesheet, Apache policy, and release metadata.
It intentionally excludes source memory, historical docs, build tools, and
verification receipts from the deployment package.

Every size and digest binds the exact file bytes. No newline, encoding, or
line-ending normalization is permitted. `PACKAGE-MANIFEST.md` is excluded
to avoid self-reference, but the deterministic Git staging command includes
it after proving that its committed blob equals regenerated manifest bytes.
Verification also binds the executing generator to its selected Git blob.
The content-addressed release directory must equal this package exactly;
overlay files and extra directories are forbidden. Staging places one
permission-sealed release in a fresh custody root. Activation must verify a
new inactive destination and atomically replace one release pointer; it must
never copy package files into the currently active web root.

| Path | Bytes | SHA-256 |
| --- | ---: | --- |
| `.htaccess` | 1838 | `36E0E82D66F775F7BD5A3B084EC1C6B8A77876190F570E7B13752A2817E82F21` |
| `assets/css/redirect.css` | 7648 | `DE796599EC71616744327D17C98BEF799C56F523A6797512B51FAE45359D5BC5` |
| `index.php` | 13612 | `EA0D88BDE1C1F48BFAD5C691E77D4706A6162DE404F0472F2C8FD8F9A1DA609A` |
| `version.json` | 652 | `FB3F29FA551AA42DAF811B52438B898275D6F81712D9501A5DDB1B1ECBBDE3F9` |
