<?php
declare(strict_types=1);

const RUNTIME_MIRUST_VERSION = '1.0.6';
const RUNTIME_MIRUST_SITE = 'Runtime.MiRust.com';
const RUNTIME_MIRUST_BASE_URL = 'https://Runtime.MiRust.com';

/**
 * Escape a scalar for safe HTML output.
 */
function e(string $value): string
{
    return htmlspecialchars($value, ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8');
}

/**
 * Load the curated page registry from disk.
 *
 * @return array<int,array<string,string>>
 */
function runtime_pages(): array
{
    static $pages = null;
    if ($pages !== null) {
        return $pages;
    }

    $path = __DIR__ . '/../data/pages.json';
    $json = file_get_contents($path);
    if ($json === false) {
        return [];
    }

    $decoded = json_decode($json, true);
    $pages = is_array($decoded) ? $decoded : [];
    return $pages;
}

/**
 * Return a page by slug, accepting home aliases.
 */
function runtime_page_by_slug(string $slug): ?array
{
    $slug = trim($slug, '/');
    if ($slug === '' || $slug === 'index.php') {
        $slug = 'home';
    }

    foreach (runtime_pages() as $page) {
        if (($page['slug'] ?? '') === $slug) {
            return $page;
        }
    }

    return null;
}

/**
 * Build a route URL for a page slug.
 */
function runtime_url(string $slug): string
{
    $slug = trim($slug, '/');
    return $slug === 'home' ? '/' : '/' . $slug . '/';
}

/**
 * Determine whether the current request prefers Markdown over HTML.
 */
function runtime_prefers_markdown(): bool
{
    $accept = $_SERVER['HTTP_ACCEPT'] ?? '';
    if ($accept === '') {
        return false;
    }

    $best = ['type' => 'text/html', 'q' => 0.0, 'specificity' => 0, 'order' => 999];
    $parts = array_map('trim', explode(',', $accept));
    foreach ($parts as $order => $part) {
        if ($part === '') {
            continue;
        }
        $segments = array_map('trim', explode(';', $part));
        $type = strtolower(array_shift($segments) ?: '');
        $q = 1.0;
        foreach ($segments as $segment) {
            if (str_starts_with($segment, 'q=')) {
                $q = max(0.0, min(1.0, (float) substr($segment, 2)));
            }
        }
        if ($q <= 0.0) {
            continue;
        }
        $specificity = $type === '*/*' ? 0 : (str_ends_with($type, '/*') ? 1 : 2);
        if ($q > $best['q'] || ($q === $best['q'] && $specificity > $best['specificity'])) {
            $best = ['type' => $type, 'q' => $q, 'specificity' => $specificity, 'order' => $order];
        }
    }

    return in_array($best['type'], ['text/markdown', 'text/x-markdown'], true);
}

/**
 * Emit project-level security headers for PHP-rendered routes.
 */
function runtime_send_headers(string $contentType): void
{
    header('Content-Type: ' . $contentType . '; charset=utf-8');
    header('X-Content-Type-Options: nosniff');
    header('Referrer-Policy: strict-origin-when-cross-origin');
    header('Permissions-Policy: camera=(), microphone=(), geolocation=(), payment=(), usb=(), serial=()');
    header("Content-Security-Policy: default-src 'self'; base-uri 'self'; form-action 'self'; frame-ancestors 'self'; img-src 'self' data:; script-src 'self'; style-src 'self'; object-src 'none'");
    header('Vary: Accept');
    header('Cache-Control: public, max-age=300, stale-while-revalidate=600');
    if ((!empty($_SERVER['HTTPS']) && $_SERVER['HTTPS'] !== 'off') || (($_SERVER['HTTP_X_FORWARDED_PROTO'] ?? '') === 'https')) {
        header('Strict-Transport-Security: max-age=31536000; includeSubDomains; preload');
    }
}

/**
 * Render the site header and top navigation.
 */
function runtime_render_header(array $page): void
{
    $title = ($page['slug'] ?? '') === 'home' ? RUNTIME_MIRUST_SITE : ($page['title'] . ' | ' . RUNTIME_MIRUST_SITE);
    $description = $page['description'] ?? 'Plain PHP project site for Runtime.MiRust.com and TinyRustLM.';
    $canonical = RUNTIME_MIRUST_BASE_URL . runtime_url($page['slug'] ?? 'home');
    $mdCanonical = rtrim($canonical, '/') . '.md';
    $current = $page['slug'] ?? 'home';
    ?>
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title><?= e($title) ?></title>
  <meta name="description" content="<?= e($description) ?>">
  <meta name="generator" content="Runtime.MiRust.com plain PHP <?= e(RUNTIME_MIRUST_VERSION) ?>">
  <link rel="canonical" href="<?= e($canonical) ?>">
  <link rel="alternate" type="text/markdown" href="<?= e($mdCanonical) ?>">
  <link rel="stylesheet" href="/assets/css/site.css?v=<?= e(RUNTIME_MIRUST_VERSION) ?>">
  <script src="/assets/js/site.js?v=<?= e(RUNTIME_MIRUST_VERSION) ?>" defer></script>
  <script type="application/ld+json"><?= json_encode([
        '@context' => 'https://schema.org',
        '@type' => 'TechArticle',
        'headline' => $page['title'] ?? RUNTIME_MIRUST_SITE,
        'description' => $description,
        'url' => $canonical,
        'author' => ['@type' => 'Person', 'name' => 'Mike Kappel'],
        'publisher' => ['@type' => 'Organization', 'name' => RUNTIME_MIRUST_SITE],
        'about' => ['TinyRustLM', 'Rust WebAssembly', 'browser-local SLM runtime', 'plain PHP site'],
    ], JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE) ?></script>
</head>
<body class="route-<?= e($current) ?>">
<a class="skip-link" href="#content">Skip to content</a>
<header class="site-header">
  <div class="site-header__inner">
    <a class="brand" href="/" aria-label="Runtime.MiRust.com home">
      <span class="brand__mark" aria-hidden="true">MR</span>
      <span><strong>Runtime.MiRust.com</strong><small>plain PHP · Rust/WASM SLM runtime</small></span>
    </a>
    <nav class="primary-nav" aria-label="Primary navigation">
      <?php runtime_menu_group('Start', ['home','project','source-facts','plain-php-rebuild','faq'], $current); ?>
      <?php runtime_menu_group('Runtime', ['architecture','browser-runtime','model-format','developer-docs'], $current); ?>
      <?php runtime_menu_group('Assembly', ['adapters-assembly','model-breeding','research-development'], $current); ?>
      <?php runtime_menu_group('Evidence', ['proof-testing','memory-reports','roadmap-boundaries'], $current); ?>
      <?php runtime_menu_group('Trust', ['site-audit-response','site-origin-fix','site-infrastructure','deployment-checklist','runtime-health','launch-operations'], $current); ?>
      <?php runtime_menu_group('Agents', ['agent-readiness'], $current, [
          ['label' => 'llms.txt', 'href' => '/llms.txt'],
          ['label' => 'llms-full.txt', 'href' => '/llms-full.txt'],
          ['label' => 'Docs', 'href' => '/docs/index.md'],
          ['label' => '.uai Memory', 'href' => '/.uai/index.uai'],
      ]); ?>
      <a class="nav-direct<?= $current === 'contact-mike-kappel' ? ' is-active' : '' ?>" href="/contact-mike-kappel/">Contact</a>
    </nav>
    <form class="site-search" action="/search/" method="get" role="search">
      <label class="visually-hidden" for="site-search-q">Search Runtime.MiRust.com</label>
      <input id="site-search-q" name="q" type="search" placeholder="Search" value="<?= e($_GET['q'] ?? '') ?>">
      <button type="submit">Search</button>
    </form>
  </div>
</header>
<main id="content" class="content-shell" tabindex="-1">
    <?php
}

/**
 * Render one details-based top menu group.
 */
function runtime_menu_group(string $label, array $slugs, string $current, array $extra = []): void
{
    $isActive = in_array($current, $slugs, true);
    ?>
    <details class="menu-group<?= $isActive ? ' is-active' : '' ?>">
      <summary><?= e($label) ?></summary>
      <div class="menu-panel">
        <?php foreach ($slugs as $slug): $item = runtime_page_by_slug($slug); if (!$item) continue; ?>
          <a href="<?= e(runtime_url($slug)) ?>"<?= $current === $slug ? ' aria-current="page"' : '' ?>><?= e($item['nav'] ?? $item['title']) ?></a>
        <?php endforeach; ?>
        <?php foreach ($extra as $item): ?>
          <a href="<?= e($item['href']) ?>"><?= e($item['label']) ?></a>
        <?php endforeach; ?>
      </div>
    </details>
    <?php
}

/**
 * Render the footer used on every PHP route.
 */
function runtime_render_footer(): void
{
    ?>
</main>
<footer class="site-footer">
  <div class="site-footer__grid">
    <section>
      <h2>Runtime.MiRust.com</h2>
      <p>Plain PHP project site for TinyRustLM, a browser-local Rust/WASM small language model runtime.</p>
      <p class="site-footer__meta">Plain PHP v<?= e(RUNTIME_MIRUST_VERSION) ?>. No WordPress. No database. No Composer. No Bootstrap. No jQuery. No external front-end dependencies.</p>
    </section>
    <nav aria-label="Footer project navigation">
      <h2>Project</h2>
      <a href="/architecture/">Architecture</a>
      <a href="/browser-runtime/">Browser Runtime</a>
      <a href="/model-format/">Model Format</a>
      <a href="/proof-testing/">Proof &amp; Testing</a>
      <a href="/plain-php-rebuild/">Plain PHP Rebuild</a>
      <a href="/site-origin-fix/">Origin Fix</a>
      <a href="/runtime-health/">Runtime Health</a>
    </nav>
    <nav aria-label="Footer agent navigation">
      <h2>Agent Files</h2>
      <a href="/llms.txt">llms.txt</a>
      <a href="/llms-full.txt">llms-full.txt</a>
      <a href="/docs/index.md">/docs</a>
      <a href="/.uai/index.uai">.uai memory</a>
      <a href="/sitemap.xml">sitemap.xml</a>
    </nav>
    <section>
      <h2>Contact</h2>
      <p><a class="footer-contact" href="/contact-mike-kappel/">Contact Mike Kappel</a></p>
      <p>Use the local contact page for project follow-up, engineering review, or source-backed documentation questions.</p>
    </section>
  </div>
</footer>
</body>
</html>
    <?php
}

/**
 * Render a normal page body.
 */
function runtime_render_page(array $page): void
{
    echo '<article class="page-card">';
    echo $page['body_html'] ?? '';
    echo '</article>';
}

/**
 * Render a simple page/document search over the page registry.
 */
function runtime_render_search(): void
{
    $query = trim((string)($_GET['q'] ?? ''));
    echo '<article class="page-card"><h1>Search</h1>';
    echo '<form class="search-main" action="/search/" method="get" role="search"><label for="q-main">Search Runtime.MiRust.com</label><div><input id="q-main" name="q" type="search" value="' . e($query) . '"><button type="submit">Search</button></div></form>';
    if ($query === '') {
        echo '<p>Search the plain PHP page registry. Docs and .uai files remain directly available through their public paths.</p></article>';
        return;
    }
    $terms = preg_split('/\s+/', strtolower($query)) ?: [];
    $results = [];
    foreach (runtime_pages() as $page) {
        $haystack = strtolower(strip_tags(($page['title'] ?? '') . ' ' . ($page['description'] ?? '') . ' ' . ($page['markdown'] ?? '')));
        $score = 0;
        foreach ($terms as $term) {
            if ($term !== '' && str_contains($haystack, $term)) {
                $score++;
            }
        }
        if ($score > 0) {
            $results[] = [$score, $page];
        }
    }
    usort($results, static fn($a, $b) => $b[0] <=> $a[0]);
    echo '<p><strong>' . count($results) . '</strong> page result(s) for <code>' . e($query) . '</code>.</p>';
    echo '<div class="result-list">';
    foreach ($results as [$score, $page]) {
        echo '<a class="result-card" href="' . e(runtime_url($page['slug'])) . '"><strong>' . e($page['title']) . '</strong><span>' . e($page['description'] ?? '') . '</span></a>';
    }
    echo '</div></article>';
}
