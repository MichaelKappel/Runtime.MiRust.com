<?php
declare(strict_types=1);

$path = trim((string) (parse_url($_SERVER['REQUEST_URI'] ?? '/', PHP_URL_PATH) ?: '/'), '/');

$target = 'https://tinyrustlm.mirust.com/developer-portal/';

if (preg_match('#^docs/(.+)$#', $path, $matches)) {
    $target = 'https://tinyrustlm.mirust.com/docs/runtime-portal/runtime-docs/' . $matches[1];
} elseif ($path === 'PACKAGE-MANIFEST.md') {
    $target = 'https://tinyrustlm.mirust.com/docs/runtime-portal/package/PACKAGE-MANIFEST.md';
} elseif (in_array($path, ['DEPLOYMENT.md', 'README.md', 'robots.txt', 'sitemap.xml', 'version.json', 'healthz'], true)) {
    $target = 'https://tinyrustlm.mirust.com/docs/runtime-portal/package/' . $path;
} elseif ($path === 'llms.txt') {
    $target = 'https://tinyrustlm.mirust.com/llms.txt';
} elseif ($path === 'llms-full.txt') {
    $target = 'https://tinyrustlm.mirust.com/llms-full.txt';
} elseif (str_starts_with($path, '.uai/')) {
    $target = 'https://tinyrustlm.mirust.com/docs/runtime-portal/runtime-docs/long-term-memory.uai';
}

header('Location: ' . $target, true, 301);
header('X-Robots-Tag: noindex, follow');
header('Content-Type: text/html; charset=UTF-8');
?>
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="robots" content="noindex,follow">
  <meta http-equiv="refresh" content="0;url=<?= htmlspecialchars($target, ENT_QUOTES, 'UTF-8') ?>">
  <title>Runtime.MiRust.com Retired</title>
</head>
<body>
  <p>Runtime.MiRust.com is retired. Continue at <a href="<?= htmlspecialchars($target, ENT_QUOTES, 'UTF-8') ?>">TinyRustLM.MiRust.com</a>.</p>
</body>
</html>
