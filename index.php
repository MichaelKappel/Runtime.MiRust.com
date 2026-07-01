<?php
declare(strict_types=1);
require __DIR__ . '/inc/site.php';

$uriPath = parse_url($_SERVER['REQUEST_URI'] ?? '/', PHP_URL_PATH) ?: '/';
$path = trim($uriPath, '/');


if ($path === 'healthz') {
    runtime_send_headers('text/plain');
    echo "ok Runtime.MiRust.com plain PHP " . RUNTIME_MIRUST_VERSION . "\n";
    exit;
}

if ($path === 'version.json') {
    runtime_send_headers('application/json');
    echo json_encode([
        'site' => RUNTIME_MIRUST_SITE,
        'version' => RUNTIME_MIRUST_VERSION,
        'package' => 'runtime-mirust-plain-php-root',
        'deployment' => 'root-extract plain PHP',
        'current_claim_boundary' => 'TinyRustLM .slm runtime, browser-local Rust/WASM, no broad GGUF import claim',
        'required_public_routes' => [
            '/', '/healthz', '/version.json', '/llms.txt', '/llms-full.txt', '/sitemap.xml', '/robots.txt', '/docs/index.md', '/.uai/index.uai'
        ],
    ], JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE | JSON_PRETTY_PRINT) . "\n";
    exit;
}

if ($path === 'cgi-sys/defaultwebpage.cgi') {
    header('Location: /site-origin-fix/', true, 302);
    exit;
}

if ($path === 'wp-login.php' || str_starts_with($path, 'wp-admin') || str_starts_with($path, 'wp-content') || str_starts_with($path, 'wp-includes')) {
    header('Location: /plain-php-rebuild/', true, 302);
    exit;
}

if ($path === 'search') {
    runtime_send_headers('text/html');
    runtime_render_header(['slug' => 'search', 'title' => 'Search', 'description' => 'Search Runtime.MiRust.com plain PHP page registry.']);
    runtime_render_search();
    runtime_render_footer();
    exit;
}

$wantsMarkdown = false;
if (str_ends_with($path, '.md')) {
    $wantsMarkdown = true;
    $path = substr($path, 0, -3);
}

$page = runtime_page_by_slug($path);
if (!$page) {
    http_response_code(404);
    runtime_send_headers(runtime_prefers_markdown() ? 'text/markdown' : 'text/html');
    if (runtime_prefers_markdown()) {
        echo "# Page not found\n\nThe requested Runtime.MiRust.com route was not found.\n";
        exit;
    }
    runtime_render_header(['slug' => '404', 'title' => 'Page not found', 'description' => 'The requested Runtime.MiRust.com page was not found.']);
    echo '<article class="page-card"><h1>Page not found</h1><p>The requested Runtime.MiRust.com route was not found.</p><p><a href="/">Return home</a></p></article>';
    runtime_render_footer();
    exit;
}

if ($wantsMarkdown || runtime_prefers_markdown()) {
    runtime_send_headers('text/markdown');
    echo rtrim($page['markdown'] ?? '# ' . ($page['title'] ?? 'Runtime.MiRust.com')) . "\n";
    exit;
}

runtime_send_headers('text/html');
runtime_render_header($page);
runtime_render_page($page);
runtime_render_footer();
