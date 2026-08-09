# Runtime.MiRust.com Redirect Deployment

Runtime.MiRust.com should be a redirect-only host.

Required behavior:

- `/` redirects to `https://tinyrustlm.mirust.com/developer-portal/`
- `/docs/*` redirects to the preserved archive under `https://tinyrustlm.mirust.com/docs/runtime-portal/runtime-docs/*`
- `/llms.txt` redirects to `https://tinyrustlm.mirust.com/llms.txt`
- `/llms-full.txt` redirects to `https://tinyrustlm.mirust.com/llms-full.txt`

Do not deploy this package through the FileZilla profile currently named `Runtime.MiRust.com`; that profile logs into the TinyRustLM.MiRust.com web root. Use only a verified credential or document root for `runtime.mirust.com`.

## Verification Gate

Run one of these equivalent verifiers after any redirect deployment:

```powershell
& .\tools\verify-runtime-mirust.ps1
```

```bash
./tools/verify-runtime-mirust.sh
```

The gate requires every Runtime route to return an allowed redirect status,
requires each `Location` header to match the canonical destination exactly,
and requires every unique destination to return HTTP 200. A correct redirect
to a missing documentation page is a failed deployment.
