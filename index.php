<?php
declare(strict_types=1);

const CURRENT_PORTAL = 'https://tinyrustlm.mirust.com';
const REDIRECT_STYLESHEET_PATH = '/assets/css/redirect.css';
const RETIRED_SOURCE_COPY_PATH = 'docs/workspace.uai';
const RETIRED_SOURCE_COPY_BODY = "Gone\n";
const MAXIMUM_REQUEST_PATH_BYTES = 2048;

/** Return the literal request-target path without URL-parser reinterpretation. */
function raw_request_path(): ?string
{
    $requestTarget = (string) ($_SERVER['REQUEST_URI'] ?? '/');
    if ($requestTarget === '') {
        return null;
    }
    $queryOffset = strpos($requestTarget, '?');
    return $queryOffset === false ? $requestTarget : substr($requestTarget, 0, $queryOffset);
}

if (PHP_SAPI === 'cli-server') {
    $method = strtoupper((string) ($_SERVER['REQUEST_METHOD'] ?? 'GET'));
    $staticPath = raw_request_path();
    if (($method === 'GET' || $method === 'HEAD')
        && $staticPath === REDIRECT_STYLESHEET_PATH
        && is_file(__DIR__ . DIRECTORY_SEPARATOR . 'assets' . DIRECTORY_SEPARATOR . 'css' . DIRECTORY_SEPARATOR . 'redirect.css')) {
        return false;
    }
}

/** Escape text for safe HTML output. */
function h(string $value): string
{
    return htmlspecialchars($value, ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8');
}

/** Decode one unambiguous URL-path layer and reject hostile aliases. */
function request_path(): ?string
{
    $rawPath = raw_request_path();
    if (!is_string($rawPath) || $rawPath === '' || strlen($rawPath) > MAXIMUM_REQUEST_PATH_BYTES
        || $rawPath[0] !== '/' || preg_match('/%(?![0-9A-Fa-f]{2})/', $rawPath) === 1) {
        return null;
    }

    $decoded = rawurldecode($rawPath);
    if (strlen($decoded) > MAXIMUM_REQUEST_PATH_BYTES
        || str_contains($decoded, '%')
        || str_contains($decoded, "\0")
        || str_contains($decoded, '\\')
        || preg_match('/[^A-Za-z0-9._~\/-]/', $decoded) === 1
        || str_contains($decoded, '//')) {
        return null;
    }

    if ($decoded === '/') {
        return '';
    }

    $relative = substr($decoded, 1);
    if (str_ends_with($relative, '/')) {
        $relative = substr($relative, 0, -1);
    }
    if ($relative === '') {
        return null;
    }

    $segments = explode('/', $relative);
    foreach ($segments as $segment) {
        if ($segment === '' || $segment === '.' || $segment === '..') {
            return null;
        }
    }
    return implode('/', $segments);
}

/** Emit one bounded terminal text response with no redirect authority. */
function terminal_text_response(int $status, string $body): never
{
    header_remove('Location');
    header_remove('Link');
    http_response_code($status);
    header('Cache-Control: no-store', true);
    header('X-Robots-Tag: noindex, nofollow', true);
    header('X-Content-Type-Options: nosniff', true);
    header('Content-Type: text/plain; charset=UTF-8', true);
    header('Content-Length: ' . strlen($body), true);
    if (strtoupper((string) ($_SERVER['REQUEST_METHOD'] ?? 'GET')) !== 'HEAD') {
        echo $body;
    }
    exit;
}

/** Encode a safe relative path while preserving its separators. */
function encoded_path(string $path): string
{
    return implode('/', array_map('rawurlencode', explode('/', $path)));
}

/** Resolve a retired Runtime route to the closest current authority. */
function migration_target(string $path): array
{
    $topicRoutes = [
        'architecture' => ['/architecture/', 'Architecture'],
        'browser-runtime' => ['/browser-runtime/', 'Browser runtime'],
        'model-format' => ['/slm-format/', '.slm format'],
        'adapters-assembly' => ['/adapters/', 'Adapters'],
        'model-breeding' => ['/model-breeding/', 'Model breeding'],
        'proof-testing' => ['/testing/', 'Testing and proof'],
        'developer-docs' => ['/developer-portal/', 'Developer portal'],
        'memory-reports' => ['/docs/', 'Documentation and memory'],
        'roadmap-boundaries' => ['/roadmap/', 'Roadmap'],
        'research-development' => ['/roadmap/', 'Research roadmap'],
        'agent-readiness' => ['/docs/', 'Agent-readable documentation'],
        'contact-mike-kappel' => ['/contact/', 'Contact'],
        'faq' => ['/glossary/', 'Glossary and reference'],
    ];

    if ($path === '' || $path === 'index.php' || $path === 'home') {
        return [CURRENT_PORTAL . '/developer-portal/', 'Current developer portal', 'portal'];
    }
    if (preg_match('#^docs/(.+)$#', $path, $matches) === 1) {
        return [CURRENT_PORTAL . '/docs/runtime-portal/runtime-docs/' . encoded_path($matches[1]), 'Preserved runtime document', 'archive'];
    }
    if ($path === 'PACKAGE-MANIFEST.md') {
        return [CURRENT_PORTAL . '/docs/runtime-portal/package/PACKAGE-MANIFEST.md', 'Preserved package manifest', 'archive'];
    }
    if (in_array($path, ['DEPLOYMENT.md', 'README.md', 'robots.txt', 'sitemap.xml', 'version.json', 'healthz'], true)) {
        return [CURRENT_PORTAL . '/docs/runtime-portal/package/' . rawurlencode($path), 'Preserved package file', 'archive'];
    }
    if ($path === 'llms.txt' || $path === 'llms-full.txt') {
        return [CURRENT_PORTAL . '/' . $path, 'Current machine-readable index', 'machine'];
    }
    if (str_starts_with($path, '.uai/')) {
        return [CURRENT_PORTAL . '/docs/runtime-portal/runtime-docs/long-term-memory.uai', 'Preserved runtime memory', 'archive'];
    }
    if (str_starts_with($path, 'agent-file-handoff/')) {
        return [CURRENT_PORTAL . '/developer-portal/', 'Current developer portal', 'portal'];
    }
    $slug = trim($path, '/');
    if (isset($topicRoutes[$slug])) {
        return [CURRENT_PORTAL . $topicRoutes[$slug][0], $topicRoutes[$slug][1], 'topic'];
    }
    return [CURRENT_PORTAL . '/developer-portal/', 'Current developer portal', 'portal'];
}

/** Preserve only useful public query parameters on the destination. */
function with_forwarded_query(string $target): string
{
    $forward = [];
    foreach (['format', 'q'] as $key) {
        if (isset($_GET[$key]) && is_scalar($_GET[$key])) {
            $forward[$key] = substr((string) $_GET[$key], 0, 200);
        }
    }
    return $forward === [] ? $target : $target . (str_contains($target, '?') ? '&' : '?') . http_build_query($forward, '', '&', PHP_QUERY_RFC3986);
}

$path = request_path();
if ($path === null) {
    terminal_text_response(400, "Bad Request\n");
}
if (strcasecmp($path, RETIRED_SOURCE_COPY_PATH) === 0) {
    $method = strtoupper((string) ($_SERVER['REQUEST_METHOD'] ?? 'GET'));
    if ($method !== 'GET' && $method !== 'HEAD') {
        header('Allow: GET, HEAD', true);
        terminal_text_response(405, "Method Not Allowed\n");
    }
    terminal_text_response(410, RETIRED_SOURCE_COPY_BODY);
}
[$target, $targetLabel, $targetKind] = migration_target($path);
$target = with_forwarded_query($target);
$preview = isset($_GET['preview']) && (string) $_GET['preview'] === '1';

header('X-Robots-Tag: noindex, follow');
header('X-Content-Type-Options: nosniff');
header('Referrer-Policy: strict-origin-when-cross-origin');
header('Permissions-Policy: camera=(), microphone=(), geolocation=(), payment=(), usb=(), serial=()');
header("Content-Security-Policy: default-src 'self'; base-uri 'none'; form-action 'self'; frame-ancestors 'none'; img-src 'self' data:; style-src 'self'; script-src 'none'; object-src 'none'");
header('Content-Type: text/html; charset=UTF-8');
header('Link: <' . $target . '>; rel="canonical"');
header($preview ? 'Cache-Control: no-store' : 'Cache-Control: public, max-age=3600');

if (!$preview) {
    header('Location: ' . $target, true, 301);
}
?>
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <meta name="robots" content="noindex,follow">
  <?php if (!$preview): ?><meta http-equiv="refresh" content="0;url=<?= h($target) ?>"><?php endif; ?>
  <title>Runtime.MiRust.com Moved | TinyRustLM Developer Portal</title>
  <meta name="description" content="Runtime.MiRust.com has moved into the TinyRustLM developer portal. Legacy documentation remains preserved with route-aware redirects.">
  <link rel="canonical" href="<?= h($target) ?>">
  <link rel="icon" href="data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=">
  <link rel="stylesheet" href="/assets/css/redirect.css">
</head>
<body>
  <a class="skip-link" href="#content">Skip to migration details</a>
  <header class="site-header">
    <div class="shell header-inner">
      <a class="brand" href="/?preview=1" aria-label="Runtime migration status home">
        <span class="brand-mark" aria-hidden="true">MR</span>
        <span><strong>Runtime.MiRust.com</strong><small>Retired compatibility origin</small></span>
      </a>
      <span class="status"><span aria-hidden="true"></span> Routes preserved</span>
    </div>
  </header>

  <main id="content" class="shell" tabindex="-1">
    <section class="intro" aria-labelledby="page-title">
      <p class="eyebrow"><?= $preview ? 'Migration preview' : 'Permanent migration' ?></p>
      <h1 id="page-title">Runtime documentation now lives with TinyRustLM</h1>
      <p class="lede">The standalone Runtime documentation authority was consolidated into one TinyRustLM developer portal. Existing links still resolve to the closest current page or preserved archive document.</p>
      <div class="actions">
        <a class="button primary" href="<?= h($target) ?>">Continue to <?= h($targetLabel) ?></a>
        <a class="button" href="https://tinyrustlm.com/">Open the TinyRustLM app</a>
      </div>
    </section>

    <section class="route-panel" aria-labelledby="route-heading">
      <div class="route-summary">
        <p class="panel-label">Resolved destination</p>
        <h2 id="route-heading"><?= h($targetLabel) ?></h2>
        <p class="route-url"><a href="<?= h($target) ?>"><?= h($target) ?></a></p>
      </div>
      <dl>
        <div><dt>Requested path</dt><dd><code>/<?= h($path) ?></code></dd></div>
        <div><dt>Resolution type</dt><dd><?= h(ucfirst($targetKind)) ?></dd></div>
        <div><dt>Default response</dt><dd>HTTP 301</dd></div>
        <div><dt>Search policy</dt><dd>Noindex, follow</dd></div>
      </dl>
    </section>

    <section class="destinations" aria-labelledby="destinations-heading">
      <div class="section-heading">
        <p class="eyebrow">Current authorities</p>
        <h2 id="destinations-heading">One product, one developer portal, one archive</h2>
      </div>
      <div class="destination-grid">
        <article><p class="card-label">Use the product</p><h3>TinyRustLM.com</h3><p>Run the browser-local Rust/WASM model interface.</p><a href="https://tinyrustlm.com/">Open app <span aria-hidden="true">&rarr;</span></a></article>
        <article><p class="card-label">Build and verify</p><h3>Developer portal</h3><p>Read current architecture, runtime, format, adapter, and proof documentation.</p><a href="https://tinyrustlm.mirust.com/developer-portal/">Open portal <span aria-hidden="true">&rarr;</span></a></article>
        <article><p class="card-label">Audit history</p><h3>Runtime archive</h3><p>Inspect preserved implementation reports and the archive manifest.</p><a href="https://tinyrustlm.mirust.com/docs/runtime-portal/index.md">Open archive <span aria-hidden="true">&rarr;</span></a></article>
      </div>
    </section>

    <section class="mapping" aria-labelledby="mapping-heading">
      <div class="section-heading">
        <p class="eyebrow">Route continuity</p>
        <h2 id="mapping-heading">Legacy topics retain useful destinations</h2>
      </div>
      <div class="table-wrap" role="region" aria-label="Legacy route examples" tabindex="0">
        <table>
          <thead><tr><th scope="col">Legacy route</th><th scope="col">Current destination</th><th scope="col">Purpose</th></tr></thead>
          <tbody>
            <tr><td><code>/architecture/</code></td><td><a href="https://tinyrustlm.mirust.com/architecture/">/architecture/</a></td><td>Current system map</td></tr>
            <tr><td><code>/browser-runtime/</code></td><td><a href="https://tinyrustlm.mirust.com/browser-runtime/">/browser-runtime/</a></td><td>Browser execution surface</td></tr>
            <tr><td><code>/model-format/</code></td><td><a href="https://tinyrustlm.mirust.com/slm-format/">/slm-format/</a></td><td>Current artifact contract</td></tr>
            <tr><td><code>/proof-testing/</code></td><td><a href="https://tinyrustlm.mirust.com/testing/">/testing/</a></td><td>Verification evidence</td></tr>
            <tr><td><code>/docs/&hellip;</code></td><td><a href="https://tinyrustlm.mirust.com/docs/runtime-portal/runtime-docs/">Preserved document path</a></td><td>Legacy report continuity</td></tr>
          </tbody>
        </table>
      </div>
    </section>

    <section class="machine" aria-labelledby="machine-heading">
      <div>
        <p class="eyebrow">Machine readers</p>
        <h2 id="machine-heading">Current indexes remain directly addressable</h2>
        <p>Agents and automation should use the TinyRustLM indexes rather than treating this compatibility origin as an independent documentation source.</p>
      </div>
      <nav aria-label="Machine-readable resources">
        <a href="https://tinyrustlm.mirust.com/llms.txt"><code>llms.txt</code><span>Concise project map</span></a>
        <a href="https://tinyrustlm.mirust.com/llms-full.txt"><code>llms-full.txt</code><span>Expanded project context</span></a>
        <a href="https://tinyrustlm.mirust.com/docs/runtime-portal/MANIFEST.md"><code>MANIFEST.md</code><span>Archive preservation evidence</span></a>
      </nav>
    </section>
  </main>

  <footer class="site-footer">
    <div class="shell footer-inner">
      <p><strong>Runtime.MiRust.com</strong> is retained only for route continuity.</p>
      <p><a href="https://tinyrustlm.mirust.com/contact/">Contact</a> <span aria-hidden="true">&middot;</span> <a href="https://tinyrustlm.mirust.com/docs/runtime-portal/MANIFEST.md">Preservation manifest</a></p>
    </div>
  </footer>
</body>
</html>
