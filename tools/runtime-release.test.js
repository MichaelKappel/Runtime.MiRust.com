"use strict";

const assert = require("node:assert/strict");
const fs = require("node:fs");
const http = require("node:http");
const net = require("node:net");
const os = require("node:os");
const path = require("node:path");
const { spawn, spawnSync } = require("node:child_process");
const test = require("node:test");

const repositoryRoot = path.resolve(__dirname, "..");
const generatorPath = path.join(__dirname, "build-runtime-manifests.js");
const generator = require(generatorPath);

function read(relativePath) {
  return fs.readFileSync(path.join(repositoryRoot, ...relativePath.split("/")));
}

function readText(relativePath) {
  return read(relativePath).toString("utf8");
}

function run(command, args, options = {}) {
  return spawnSync(command, args, {
    cwd: options.cwd || repositoryRoot,
    encoding: "utf8",
    env: options.env || process.env,
    windowsHide: true,
    maxBuffer: 16 * 1024 * 1024
  });
}

function commandAvailable(command, versionArgument = "--version") {
  const result = run(command, [versionArgument]);
  return result.status === 0;
}

function assertCommandPassed(result, label) {
  assert.equal(result.status, 0,
    `${label} failed\nstdout:\n${result.stdout || ""}\nstderr:\n${result.stderr || ""}`);
}

function git(cwd, args, env) {
  const result = run("git", args, { cwd, env });
  assertCommandPassed(result, `git ${args.join(" ")}`);
  return result.stdout;
}

function writeFixture(relativeRoot, relativePath, bytes) {
  const destination = path.join(relativeRoot, ...relativePath.split("/"));
  fs.mkdirSync(path.dirname(destination), { recursive: true });
  fs.writeFileSync(destination, bytes);
}

function makeTreeWritable(directory) {
  if (!fs.existsSync(directory)) return;
  const stat = fs.lstatSync(directory);
  if (!stat.isDirectory() || stat.isSymbolicLink()) return;
  fs.chmodSync(directory, 0o700);
  for (const entry of fs.readdirSync(directory, { withFileTypes: true })) {
    const child = path.join(directory, entry.name);
    if (entry.isDirectory() && !entry.isSymbolicLink()) {
      makeTreeWritable(child);
    } else if (!entry.isSymbolicLink()) {
      fs.chmodSync(child, 0o600);
    }
  }
}

function fixtureVersion() {
  return Buffer.from(`${JSON.stringify({
    site: "Runtime.MiRust.com",
    status: "retired-redirect",
    updated_utc: "2030-01-02T03:04:05Z",
    package_version: "7.6.5-fixture.1"
  }, null, 2)}\n`, "utf8");
}

function rawHeaderValues(rawHeaders, wantedName) {
  const values = [];
  for (let index = 0; index < rawHeaders.length; index += 2) {
    if (rawHeaders[index].toLowerCase() === wantedName.toLowerCase()) {
      values.push(rawHeaders[index + 1]);
    }
  }
  return values;
}

function assertTerminalResponse(response, method, expectedStatus, expectedBody) {
  assert.equal(response.statusCode, expectedStatus);
  assert.deepEqual(rawHeaderValues(response.rawHeaders, "location"), []);
  assert.deepEqual(rawHeaderValues(response.rawHeaders, "cache-control"), ["no-store"]);
  assert.deepEqual(rawHeaderValues(response.rawHeaders, "x-robots-tag"), ["noindex, nofollow"]);
  assert.deepEqual(rawHeaderValues(response.rawHeaders, "x-content-type-options"), ["nosniff"]);
  assert.deepEqual(rawHeaderValues(response.rawHeaders, "content-length"),
    [String(expectedBody.length)]);
  const contentTypes = rawHeaderValues(response.rawHeaders, "content-type");
  assert.equal(contentTypes.length, 1);
  assert.equal(contentTypes[0].replaceAll(/\s/g, "").toLowerCase(), "text/plain;charset=utf-8");
  assert.deepEqual(response.body, method === "HEAD" ? Buffer.alloc(0) : expectedBody);
}

function assertRetiredResponse(response, method) {
  assertTerminalResponse(response, method, 410, Buffer.from("Gone\n"));
}

function assertBadRequestResponse(response, method) {
  assertTerminalResponse(response, method, 400, Buffer.from("Bad Request\n"));
}

function assertServerBoundaryRejection(response, method, expectedStatus = 404) {
  if (expectedStatus === null) {
    assert.ok([400, 404].includes(response.statusCode));
  } else {
    assert.equal(response.statusCode, expectedStatus);
  }
  assert.deepEqual(rawHeaderValues(response.rawHeaders, "location"), []);
  assert.ok(response.body.length <= 65536, "server-boundary rejection body is unbounded");
  if (method === "HEAD") assert.equal(response.body.length, 0);
  assert.equal(response.body.includes(Buffer.from("stale:")), false);
}

function assertRedirectResponse(response, expectedLocation) {
  assert.equal(response.statusCode, 301);
  assert.deepEqual(rawHeaderValues(response.rawHeaders, "location"), [expectedLocation]);
}

function request(port, requestPath, method = "GET") {
  return new Promise((resolve, reject) => {
    const outgoing = http.request({
      host: "127.0.0.1",
      port,
      path: requestPath,
      method,
      headers: { Host: "runtime.mirust.com" }
    }, (incoming) => {
      const chunks = [];
      incoming.on("data", (chunk) => chunks.push(chunk));
      incoming.on("end", () => resolve({
        statusCode: incoming.statusCode,
        rawHeaders: incoming.rawHeaders,
        body: Buffer.concat(chunks)
      }));
    });
    outgoing.on("error", reject);
    outgoing.end();
  });
}

function parseRawHttpResponse(bytes) {
  let offset = 0;
  while (true) {
    const boundary = bytes.indexOf(Buffer.from("\r\n\r\n"), offset);
    assert.notEqual(boundary, -1, "raw HTTP response omitted its header terminator");
    const lines = bytes.subarray(offset, boundary).toString("latin1").split("\r\n");
    const statusMatch = /^HTTP\/1[.][01] ([0-9]{3})(?: |$)/.exec(lines.shift() || "");
    assert.ok(statusMatch, "raw HTTP response has an invalid status line");
    const statusCode = Number(statusMatch[1]);
    const rawHeaders = [];
    for (const line of lines) {
      const colon = line.indexOf(":");
      assert.ok(colon > 0, `raw HTTP response has an invalid header: ${line}`);
      rawHeaders.push(line.slice(0, colon), line.slice(colon + 1).trim());
    }
    offset = boundary + 4;
    if (statusCode >= 100 && statusCode < 200) continue;
    return { statusCode, rawHeaders, body: bytes.subarray(offset) };
  }
}

function rawRequest(port, requestPath, method = "HEAD") {
  assert.match(method, /^(?:GET|HEAD)$/);
  assert.doesNotMatch(requestPath, /[\r\n ]/);
  return new Promise((resolve, reject) => {
    const chunks = [];
    const socket = net.createConnection({ host: "127.0.0.1", port });
    socket.setTimeout(5000, () => socket.destroy(new Error("raw HTTP response timed out")));
    socket.on("connect", () => socket.write([
      `${method} ${requestPath} HTTP/1.1`,
      "Host: runtime.mirust.com",
      "Accept: */*",
      "Accept-Encoding: identity",
      "Connection: close",
      "",
      ""
    ].join("\r\n"), "ascii"));
    socket.on("data", (chunk) => chunks.push(chunk));
    socket.on("end", () => {
      try {
        resolve(parseRawHttpResponse(Buffer.concat(chunks)));
      } catch (error) {
        reject(error);
      }
    });
    socket.on("error", reject);
  });
}

async function reservePort() {
  const server = net.createServer();
  await new Promise((resolve, reject) => {
    server.once("error", reject);
    server.listen(0, "127.0.0.1", resolve);
  });
  const address = server.address();
  await new Promise((resolve) => server.close(resolve));
  return address.port;
}

async function waitForServer(port, child) {
  let lastError;
  for (let attempt = 0; attempt < 80; attempt++) {
    if (child.exitCode !== null) {
      throw new Error(`Test server exited with ${child.exitCode}`);
    }
    try {
      await request(port, "/?preview=1");
      return;
    } catch (error) {
      lastError = error;
      await new Promise((resolve) => setTimeout(resolve, 25));
    }
  }
  throw lastError || new Error("Test server did not become ready");
}

function firstAvailableCommand(candidates, versionArgument = "-v") {
  return candidates.find((command) => commandAvailable(command, versionArgument)) || null;
}

function resolveExecutable(command) {
  const result = process.platform === "win32"
    ? run("where.exe", [command])
    : run("sh", ["-c", "command -v \"$1\"", "runtime-command", command]);
  if (result.status !== 0) return null;
  return result.stdout.split(/\r?\n/).map((line) => line.trim()).find(Boolean) || null;
}

function apacheBuild(command) {
  const result = run(command, ["-V"]);
  assertCommandPassed(result, `${command} -V`);
  const output = `${result.stdout}\n${result.stderr}`;
  const rootMatch = /HTTPD_ROOT="([^"]+)"/.exec(output);
  const configMatch = /SERVER_CONFIG_FILE="([^"]+)"/.exec(output);
  assert.ok(rootMatch && configMatch, "Apache -V omitted HTTPD_ROOT or SERVER_CONFIG_FILE");
  const serverRoot = path.resolve(rootMatch[1]);
  const configFile = path.isAbsolute(configMatch[1])
    ? configMatch[1]
    : path.join(serverRoot, configMatch[1]);
  return { serverRoot, configFile };
}

function apacheModuleDirectives(command) {
  const { serverRoot, configFile } = apacheBuild(command);
  const variables = new Map([
    ["SRVROOT", serverRoot],
    ["SERVER_ROOT", serverRoot],
    ["APACHE_CONFDIR", path.dirname(configFile)]
  ]);
  const visited = new Set();
  const modules = new Map();

  function expand(value) {
    const unquoted = value.trim().replace(/^"|"$/g, "");
    return unquoted.replace(/\$\{([^}]+)\}/g, (match, name) =>
      variables.get(name) || process.env[name] || match);
  }

  function expandIncludes(rawPattern) {
    const expanded = expand(rawPattern);
    const absolutePattern = path.isAbsolute(expanded)
      ? expanded
      : path.join(serverRoot, expanded);
    if (!/[?*]/.test(absolutePattern)) return [absolutePattern];
    const directory = path.dirname(absolutePattern);
    if (!fs.existsSync(directory)) return [];
    const expression = new RegExp(`^${path.basename(absolutePattern)
      .replace(/[.+^${}()|[\]\\]/g, "\\$&")
      .replaceAll("*", ".*").replaceAll("?", ".")}$`);
    return fs.readdirSync(directory).filter((name) => expression.test(name))
      .sort().map((name) => path.join(directory, name));
  }

  function visit(file) {
    const absoluteFile = path.resolve(file);
    if (visited.has(absoluteFile) || !fs.existsSync(absoluteFile)) return;
    visited.add(absoluteFile);
    const source = fs.readFileSync(absoluteFile, "utf8").replace(/\\\r?\n/g, " ");
    for (const rawLine of source.split(/\r?\n/)) {
      const line = rawLine.trim();
      if (line === "" || line.startsWith("#")) continue;
      let match = /^Define\s+(\S+)\s+(.+)$/.exec(line);
      if (match) {
        variables.set(match[1], expand(match[2]));
        continue;
      }
      match = /^Include(Optional)?\s+(.+)$/.exec(line);
      if (match) {
        const included = expandIncludes(match[2]);
        if (!match[1] && included.length === 0) {
          throw new Error(`Required Apache include is absent: ${match[2]}`);
        }
        included.forEach(visit);
        continue;
      }
      match = /^LoadModule\s+(\S+)\s+(.+)$/.exec(line);
      if (match) {
        const modulePath = expand(match[2]);
        const absoluteModule = path.isAbsolute(modulePath)
          ? modulePath
          : path.join(serverRoot, modulePath);
        modules.set(match[1], `LoadModule ${match[1]} "${absoluteModule.replaceAll("\\", "/")}"`);
      }
    }
  }

  visit(configFile);
  const compiledResult = run(command, ["-l"]);
  assertCommandPassed(compiledResult, `${command} -l`);
  const compiled = new Set((`${compiledResult.stdout}\n${compiledResult.stderr}`
    .match(/[A-Za-z0-9_]+[.]c/g) || []));
  const sourceNames = new Map([
    ["authz_core_module", "mod_authz_core.c"],
    ["dir_module", "mod_dir.c"],
    ["mime_module", "mod_mime.c"],
    ["rewrite_module", "mod_rewrite.c"],
    ["headers_module", "mod_headers.c"],
    ["actions_module", "mod_actions.c"],
    ["alias_module", "mod_alias.c"],
    ["cgi_module", "mod_cgi.c"],
    ["cgid_module", "mod_cgid.c"],
    ["unixd_module", "mod_unixd.c"],
    ["log_config_module", "mod_log_config.c"]
  ]);
  const available = (name) => modules.has(name) || compiled.has(sourceNames.get(name));
  const required = [
    "authz_core_module", "dir_module", "mime_module", "rewrite_module",
    "headers_module", "actions_module", "alias_module"
  ];
  const mpm = [...modules.keys()].find((name) => name.startsWith("mpm_"));
  if (mpm) required.push(mpm);
  const cgi = available("cgi_module") ? "cgi_module" :
    available("cgid_module") ? "cgid_module" : null;
  assert.ok(cgi, "Apache configuration must load mod_cgi or mod_cgid");
  required.push(cgi);
  for (const optional of ["unixd_module", "log_config_module"]) {
    if (modules.has(optional)) required.push(optional);
  }
  for (const moduleName of required) {
    assert.ok(available(moduleName), `Apache configuration does not provide ${moduleName}`);
  }
  return {
    serverRoot,
    directives: [...new Set(required)].filter((name) => modules.has(name))
      .map((name) => modules.get(name))
  };
}

function apacheQuote(value) {
  return path.resolve(value).replaceAll("\\", "/").replaceAll('"', '\\"');
}

async function startApacheFixture(t, apacheCommand, options = {}) {
  const phpCgiCandidate = process.env.RUNTIME_PHP_CGI ||
    firstAvailableCommand(process.platform === "win32"
      ? ["php-cgi.exe", "php-cgi", "C:\\php\\php-cgi.exe"]
      : ["php-cgi"]);
  const phpCgi = phpCgiCandidate ? resolveExecutable(phpCgiCandidate) || phpCgiCandidate : null;
  assert.ok(phpCgi && fs.existsSync(phpCgi),
    "Apache was found, so a real integration requires an available php-cgi executable");

  const fixtureRoot = fs.mkdtempSync(path.join(os.tmpdir(), "runtime-apache-test-"));
  const documentRoot = path.join(fixtureRoot, "www");
  fs.mkdirSync(documentRoot, { recursive: true });
  for (const relativePath of [".htaccess", "index.php", "assets/css/redirect.css"]) {
    writeFixture(documentRoot, relativePath, read(relativePath));
  }
  for (const relativePath of [
    "workspace.uai", ".uai/taboo.uai", "assets/js/site.js", "assets/css/site.css",
    "data/pages.json", "inc/site.php", "tools/build-runtime-manifests.js",
    "tools/verify-runtime-mirust.sh"
  ]) {
    writeFixture(documentRoot, relativePath, Buffer.from(`stale:${relativePath}\n`));
  }

  const port = await reservePort();
  const { serverRoot, directives } = apacheModuleDirectives(apacheCommand);
  const phpDirectory = path.dirname(phpCgi);
  const phpLeaf = path.basename(phpCgi);
  const configPath = path.join(fixtureRoot, "httpd.conf");
  const config = [
    `ServerRoot "${apacheQuote(serverRoot)}"`,
    ...directives,
    `PidFile "${apacheQuote(path.join(fixtureRoot, "httpd.pid"))}"`,
    `Listen 127.0.0.1:${port}`,
    "ServerName 127.0.0.1",
    `ErrorLog "${apacheQuote(path.join(fixtureRoot, "error.log"))}"`,
    "LogLevel warn",
    ...(options.passEncodedSeparatorsToApplication ? [
      "AllowEncodedSlashes NoDecode",
      "MergeSlashes Off"
    ] : []),
    `DocumentRoot "${apacheQuote(documentRoot)}"`,
    "<Directory />",
    "  AllowOverride None",
    "  Require all denied",
    "</Directory>",
    `<Directory "${apacheQuote(documentRoot)}">`,
    "  AllowOverride All",
    "  Options +ExecCGI -Indexes -MultiViews",
    "  Require all granted",
    "</Directory>",
    `ScriptAlias /__runtime_php_cgi__/ "${apacheQuote(phpDirectory)}/"`,
    "Action application/x-httpd-php /__runtime_php_cgi__/" + phpLeaf,
    "AddHandler application/x-httpd-php .php",
    "DirectoryIndex index.php",
    ""
  ].join("\n");
  fs.writeFileSync(configPath, config, "utf8");

  const syntax = run(apacheCommand, ["-t", "-f", configPath]);
  assertCommandPassed(syntax, "isolated Apache configuration check");
  const child = spawn(apacheCommand, ["-f", configPath, "-DFOREGROUND"], {
    cwd: fixtureRoot,
    stdio: ["ignore", "pipe", "pipe"],
    windowsHide: true
  });
  t.after(async () => {
    run(apacheCommand, ["-f", configPath, "-k", "shutdown"]);
    if (child.exitCode === null) child.kill();
    await new Promise((resolve) => setTimeout(resolve, 50));
    fs.rmSync(fixtureRoot, { recursive: true, force: true });
  });
  await waitForServer(port, child);
  return { port };
}

test("raw-byte identities distinguish LF from CRLF", () => {
  const lf = Buffer.from("alpha\nbeta\n", "utf8");
  const crlf = Buffer.from("alpha\r\nbeta\r\n", "utf8");
  assert.notEqual(generator.sha256(lf), generator.sha256(crlf));
  assert.notEqual(generator.identity("sample.txt", lf).bytes,
    generator.identity("sample.txt", crlf).bytes);
});

test("release metadata comes only from strict current version.json bytes", () => {
  const authoritative = JSON.parse(readText("version.json"));
  const metadata = generator.parseReleaseMetadata(read("version.json"));
  assert.deepEqual(metadata, {
    packageVersion: authoritative.package_version,
    updatedUtc: authoritative.updated_utc
  });
  const synthetic = { ...authoritative,
    package_version: "9.8.7-test.1",
    updated_utc: "2031-04-05T06:07:08Z"
  };
  assert.deepEqual(generator.parseReleaseMetadata(
    Buffer.from(`${JSON.stringify(synthetic)}\n`, "utf8")), {
    packageVersion: synthetic.package_version,
    updatedUtc: synthetic.updated_utc
  });
  assert.throws(() => generator.parseReleaseMetadata(
    Buffer.from('{"site":"Runtime.MiRust.com","status":"retired-redirect","updated_utc":"2026-02-30T00:00:00Z","package_version":"0.0.0-test"}\n')),
  /real canonical instant/);
});

test("checked manifests equal generated raw bytes and exclude retired source", () => {
  for (const [relativePath, expectedBytes] of generator.generatedWorktreeDocuments()) {
    assert.deepEqual(read(relativePath), expectedBytes, `${relativePath} is stale`);
    assert.equal(expectedBytes.includes(Buffer.from("\r\n")), false,
      `${relativePath} must be emitted with LF bytes`);
  }
  const packageManifest = readText("PACKAGE-MANIFEST.md");
  const docsManifest = readText("docs/MANIFEST.md");
  const metadata = generator.parseReleaseMetadata(read("version.json"));
  assert.ok(packageManifest.includes(`Updated UTC: ${metadata.updatedUtc}`));
  assert.ok(packageManifest.includes(`Package version: ${metadata.packageVersion}`));
  assert.doesNotMatch(packageManifest, /\.uai\//);
  assert.doesNotMatch(packageManifest, /tools\//);
  assert.match(docsManifest,
    /The retired `docs\/workspace\.uai` path is permanently forbidden/);
  assert.doesNotMatch(docsManifest, /^- \[docs\/workspace\.uai\]/m);
});

test("Git closure stages exact blobs and rejects unmanifested CRLF drift", (t) => {
  const fixtureRoot = fs.mkdtempSync(path.join(os.tmpdir(), "runtime-manifest-test-"));
  t.after(() => {
    makeTreeWritable(fixtureRoot);
    fs.rmSync(fixtureRoot, { recursive: true, force: true });
  });
  const generatorBytes = read("tools/build-runtime-manifests.js");
  writeFixture(fixtureRoot, "tools/build-runtime-manifests.js", generatorBytes);
  writeFixture(fixtureRoot, ".gitattributes", Buffer.from("* text=auto eol=lf\n"));
  writeFixture(fixtureRoot, ".htaccess", Buffer.from("RewriteEngine On\nRewriteRule ^ index.php [END]\n"));
  writeFixture(fixtureRoot, "assets/css/redirect.css", Buffer.from("body { color: black; }\n"));
  writeFixture(fixtureRoot, "index.php", Buffer.from("<?php echo 'retired';\n"));
  writeFixture(fixtureRoot, "version.json", fixtureVersion());
  writeFixture(fixtureRoot, "docs/index.md", Buffer.from("# Archive\n"));

  const gitEnvironment = {
    ...process.env,
    GIT_AUTHOR_NAME: "Runtime Manifest Test",
    GIT_AUTHOR_EMAIL: "runtime-manifest@example.invalid",
    GIT_COMMITTER_NAME: "Runtime Manifest Test",
    GIT_COMMITTER_EMAIL: "runtime-manifest@example.invalid"
  };
  git(fixtureRoot, ["init", "--quiet"], gitEnvironment);
  git(fixtureRoot, ["config", "core.autocrlf", "false"], gitEnvironment);
  let result = run(process.execPath, ["tools/build-runtime-manifests.js", "--write"], {
    cwd: fixtureRoot,
    env: gitEnvironment
  });
  assertCommandPassed(result, "fixture manifest generation");
  git(fixtureRoot, ["add", "--all"], gitEnvironment);
  git(fixtureRoot, ["commit", "--quiet", "-m", "fixture closure"], gitEnvironment);

  result = run(process.execPath, ["tools/build-runtime-manifests.js", "--verify-git", "HEAD"], {
    cwd: fixtureRoot,
    env: gitEnvironment
  });
  assertCommandPassed(result, "fixture Git closure verification");
  const verification = JSON.parse(result.stdout);
  assert.equal(verification.status, "pass");
  assert.equal(verification.generator.path, "tools/build-runtime-manifests.js");
  assert.equal(verification.generator.bytes, generatorBytes.length);
  assert.match(verification.generator.gitBlobOid, /^[0-9a-f]{40,64}$/);
  assert.equal(verification.policies.custody, generator.custodyPolicy);
  assert.equal(verification.policies.seal, generator.sealPolicy);
  assert.equal(verification.policies.activation, generator.activationPolicy);

  const custodyRoot = path.join(fixtureRoot, "redirect-custody");
  result = run(process.execPath, [
    "tools/build-runtime-manifests.js", "--stage-git", "redirect", "HEAD", custodyRoot
  ], { cwd: fixtureRoot, env: gitEnvironment });
  assertCommandPassed(result, "fixture Git blob staging");
  const proof = JSON.parse(result.stdout);
  assert.equal(proof.schema, "runtime.mirust.git_blob_custody_stage.v3");
  assert.equal(proof.status, "sealed");
  assert.equal(proof.kind, "redirect");
  assert.equal(proof.rootPolicy, generator.exactRootPolicy);
  assert.equal(proof.custodyPolicy, generator.custodyPolicy);
  assert.equal(proof.sealPolicy, generator.sealPolicy);
  assert.equal(proof.activationPolicy, generator.activationPolicy);
  assert.equal(proof.sealed, true);
  assert.match(proof.releaseDirectoryName,
    new RegExp(`^runtime-mirust-redirect-sha256-${proof.sha256.toLowerCase()}$`));
  assert.equal(proof.directoryCount, 2);
  assert.equal(proof.fileCount, generator.redirectPayloadPaths.length + 1);
  const stageRoot = path.join(custodyRoot, proof.releaseDirectoryName);
  assert.equal((fs.statSync(custodyRoot).mode & 0o222), 0);
  assert.equal((fs.statSync(stageRoot).mode & 0o222), 0);
  for (const relativePath of [...generator.redirectPayloadPaths, "PACKAGE-MANIFEST.md"]) {
    const committed = git(fixtureRoot, ["show", `HEAD:${relativePath}`], gitEnvironment);
    assert.deepEqual(
      fs.readFileSync(path.join(stageRoot, ...relativePath.split("/"))),
      Buffer.from(committed, "utf8"),
      `${relativePath} stage bytes differ from Git`
    );
    assert.equal(fs.statSync(path.join(stageRoot, ...relativePath.split("/"))).mode & 0o222,
      0, `${relativePath} was not sealed against ordinary writes`);
  }

  result = run(process.execPath, [
    "tools/build-runtime-manifests.js", "--verify-custody", "redirect", "HEAD", custodyRoot
  ], { cwd: fixtureRoot, env: gitEnvironment });
  assertCommandPassed(result, "fixture custody verification");
  assert.equal(JSON.parse(result.stdout).rootPolicy, generator.exactRootPolicy);
  result = run(process.execPath, [
    "tools/build-runtime-manifests.js", "--verify-release", "redirect", "HEAD", stageRoot
  ], { cwd: fixtureRoot, env: gitEnvironment });
  assertCommandPassed(result, "fixture content-addressed release verification");

  result = run(process.execPath, [
    "tools/build-runtime-manifests.js", "--stage-git", "redirect", "HEAD", custodyRoot
  ], { cwd: fixtureRoot, env: gitEnvironment });
  assert.notEqual(result.status, 0);
  assert.match(result.stderr, /Custody root must not already exist/);

  fs.chmodSync(custodyRoot, 0o700);
  makeTreeWritable(stageRoot);

  const staleOverlayPaths = [
    "workspace.uai", ".uai/taboo.uai", "assets/js/site.js", "assets/css/site.css",
    "data/pages.json", "inc/site.php", "tools/build-runtime-manifests.js",
    "tools/verify-runtime-mirust.sh"
  ];
  for (const relativePath of staleOverlayPaths) {
    writeFixture(stageRoot, relativePath, Buffer.from(`stale:${relativePath}\n`));
  }
  result = run(process.execPath, [
    "tools/build-runtime-manifests.js", "--verify-release", "redirect", "HEAD", stageRoot
  ], { cwd: fixtureRoot, env: gitEnvironment });
  assert.notEqual(result.status, 0);
  assert.match(result.stderr, /file inventory does not equal/);
  for (const relativePath of staleOverlayPaths) {
    fs.rmSync(path.join(stageRoot, ...relativePath.split("/")), { force: true });
  }
  for (const relativeDirectory of [".uai", "assets/js", "data", "inc", "tools"]) {
    fs.rmSync(path.join(stageRoot, ...relativeDirectory.split("/")),
      { recursive: true, force: true });
  }

  fs.mkdirSync(path.join(stageRoot, "stale-empty-directory"));
  result = run(process.execPath, [
    "tools/build-runtime-manifests.js", "--verify-release", "redirect", "HEAD", stageRoot
  ], { cwd: fixtureRoot, env: gitEnvironment });
  assert.notEqual(result.status, 0);
  assert.match(result.stderr, /directory inventory does not equal/);
  fs.rmSync(path.join(stageRoot, "stale-empty-directory"), { recursive: true, force: true });

  result = run(process.execPath, [
    "tools/build-runtime-manifests.js", "--verify-release", "redirect", "HEAD", stageRoot
  ], { cwd: fixtureRoot, env: gitEnvironment });
  assert.notEqual(result.status, 0);
  assert.match(result.stderr, /not permission-sealed/);

  fs.appendFileSync(path.join(fixtureRoot, "tools", "build-runtime-manifests.js"),
    "\n// uncommitted generator drift\n");
  result = run(process.execPath, ["tools/build-runtime-manifests.js", "--verify-git", "HEAD"], {
    cwd: fixtureRoot,
    env: gitEnvironment
  });
  assert.notEqual(result.status, 0);
  assert.match(result.stderr, /Executing manifest generator differs/);
  writeFixture(fixtureRoot, "tools/build-runtime-manifests.js", generatorBytes);

  writeFixture(fixtureRoot, ".htaccess",
    Buffer.from("RewriteEngine On\r\nRewriteRule ^ index.php [END]\r\n"));
  const rawBlob = git(fixtureRoot,
    ["hash-object", "--no-filters", "-w", ".htaccess"], gitEnvironment).trim();
  assert.match(rawBlob, /^[0-9a-f]{40,64}$/);
  git(fixtureRoot,
    ["update-index", "--cacheinfo", "100644", rawBlob, ".htaccess"], gitEnvironment);
  git(fixtureRoot, ["commit", "--quiet", "-m", "unmanifested CRLF drift"], gitEnvironment);
  result = run(process.execPath, ["tools/build-runtime-manifests.js", "--verify-git", "HEAD"], {
    cwd: fixtureRoot,
    env: gitEnvironment
  });
  assert.notEqual(result.status, 0);
  assert.match(result.stderr, /Manifest input must already use LF bytes/);

  writeFixture(fixtureRoot, "docs/workspace.uai", Buffer.from("forbidden source copy\n"));
  result = run(process.execPath, ["tools/build-runtime-manifests.js", "--check"], {
    cwd: fixtureRoot,
    env: gitEnvironment
  });
  assert.notEqual(result.status, 0);
  assert.match(result.stderr, /Permanently forbidden repository path: docs\/workspace\.uai/);
  git(fixtureRoot, ["add", "docs/workspace.uai"], gitEnvironment);
  git(fixtureRoot, ["commit", "--quiet", "-m", "forbidden source reintroduction"], gitEnvironment);
  result = run(process.execPath, ["tools/build-runtime-manifests.js", "--verify-git", "HEAD"], {
    cwd: fixtureRoot,
    env: gitEnvironment
  });
  assert.notEqual(result.status, 0);
  assert.match(result.stderr, /Permanently forbidden repository path: docs\/workspace\.uai/);
});

test("Apache sends every non-stylesheet path through one terminating front controller", () => {
  const htaccess = readText(".htaccess");
  const rewriteRules = htaccess.split(/\r?\n/).filter((line) => /^\s*RewriteRule\b/.test(line));
  assert.equal(rewriteRules.length, 2);
  for (const line of rewriteRules) {
    const flags = /\[([^\]]+)\]/.exec(line);
    assert.ok(flags, `RewriteRule lacks explicit flags: ${line}`);
    assert.equal(flags[1].split(",").includes("L"), false,
      `per-directory RewriteRule must not use L: ${line}`);
  }
  assert.match(htaccess, /^Options -Indexes -MultiViews$/m);
  assert.ok(htaccess.includes("RewriteCond %{REQUEST_METHOD} =GET [OR]"));
  assert.ok(htaccess.includes("RewriteCond %{REQUEST_METHOD} =HEAD"));
  assert.ok(htaccess.includes(
    'RewriteCond %{THE_REQUEST} "\\s/assets/css/redirect\\.css(?:\\?|[[:space:]])"'));
  assert.match(htaccess, /^RewriteRule \^assets\/css\/redirect\\\.css\$ - \[END\]$/m);
  assert.match(htaccess, /^RewriteRule \^ index\.php \[END,QSA\]$/m);
  assert.ok(htaccess.indexOf("^assets/css/redirect\\.css$") <
    htaccess.indexOf("RewriteRule ^ index.php"));
  assert.doesNotMatch(htaccess, /RewriteRule \^assets\/ -/);
  assert.doesNotMatch(htaccess, /\[R=/);
  assert.doesNotMatch(htaccess, /<IfModule mod_rewrite\.c>/);
  assert.doesNotMatch(htaccess, /AllowEncodedSlashes|MergeSlashes/);
  assert.doesNotMatch(htaccess, /SOURCE_COPY_RETIRED/);
  assert.match(htaccess, /X-Robots-Tag "noindex, nofollow" .*REQUEST_STATUS.*>= 400/);
  assert.match(htaccess, /Header always set Cache-Control "no-store" .*REQUEST_STATUS.*>= 400/);
});

test("deployment contract seals custody and atomically activates one release", () => {
  const deployment = readText("DEPLOYMENT.md");
  assert.match(deployment, /--verify-custody redirect HEAD/);
  assert.match(deployment, /--verify-release redirect HEAD/);
  assert.match(deployment, /content-addressed release/);
  assert.match(deployment, /same-filesystem\s+atomic rename/);
  assert.match(deployment, /Never copy, synchronize, or delete files inside the\s+currently active release directory/);
  assert.match(deployment, /`AllowEncodedSlashes` and `MergeSlashes` are server\/virtual-host directives/);
  assert.match(deployment, /default\s+`AllowEncodedSlashes Off`/);
  assert.doesNotMatch(deployment, /--verify-root/);
  assert.doesNotMatch(deployment, /\brsync\b[^\n]*--delete/);
  assert.doesNotMatch(deployment, /RUNTIME_DEPLOY_ROOT/);
});

test("PHP front controller declares bounded terminal routing before migration", () => {
  const source = readText("index.php");
  assert.match(source, /const REDIRECT_STYLESHEET_PATH = '\/assets\/css\/redirect\.css';/);
  assert.doesNotMatch(source, /redirect\.css\?v=/);
  assert.match(source, /function raw_request_path\(\): \?string/);
  assert.match(source, /strpos\(\$requestTarget, '\?'\)/);
  assert.doesNotMatch(source, /parse_url\(/);
  assert.match(source, /\$staticPath === REDIRECT_STYLESHEET_PATH/);
  assert.doesNotMatch(source, /is_file\(\$staticFile\)/);
  assert.match(source, /const RETIRED_SOURCE_COPY_BODY = "Gone\\n";/);
  assert.match(source, /header_remove\('Location'\)/);
  assert.match(source, /header\('Content-Length: ' \. strlen\(\$body\), true\)/);
  assert.match(source, /REQUEST_METHOD.*HEAD/);
  assert.match(source, /str_contains\(\$decoded, '%'\)/);
  assert.match(source, /str_contains\(\$decoded, '\/\/'\)/);
  assert.doesNotMatch(source, /trim\(\$decoded, '\/'\)/);
  assert.ok(source.indexOf("strcasecmp($path, RETIRED_SOURCE_COPY_PATH)") <
    source.indexOf("migration_target($path)"));
});

test("PowerShell verifier parser accepts only the exact response contract", () => {
  const result = run("powershell", [
    "-NoProfile", "-File", "tools/verify-runtime-mirust.ps1", "-SelfTest"
  ]);
  assertCommandPassed(result, "PowerShell verifier self-test");
  assert.match(result.stdout,
    /PASS PowerShell retired-route verifier fixtures \(12 plus raw-wire fixtures\)/);
  const source = readText("tools/verify-runtime-mirust.ps1");
  assert.match(source, /TcpClient/);
  assert.match(source, /SslStream/);
  assert.match(source, /raw-tls-http1\.1-until-close/);
});

test("shell verifier parser accepts only the exact response contract", () => {
  const result = run("bash", ["tools/verify-runtime-mirust.sh", "--self-test"]);
  assertCommandPassed(result, "shell verifier self-test");
  assert.match(result.stdout, /PASS shell retired-route verifier fixtures \(12\)/);
  const source = readText("tools/verify-runtime-mirust.sh");
  assert.doesNotMatch(source, /"\$\{curl_command\}"[^\n]*--head\b/);
  assert.match(source,
    /--http1\.1 --request HEAD --ignore-content-length --raw[\s\S]+--output "\$\{body_file\}"/);
});

test("shell HEAD fetch separates protocol headers from response-body bytes", () => {
  const result = run("bash", [
    "tools/verify-runtime-mirust.sh", "--self-test-head-transfer"
  ]);
  assertCommandPassed(result, "shell HEAD transfer self-test");
  assert.match(result.stdout, /PASS shell HEAD transfer verifier/);
});

test("raw HEAD socket probe detects forbidden payload bytes", async (t) => {
  const server = net.createServer((socket) => {
    socket.once("data", () => socket.end(Buffer.from([
      "HTTP/1.1 410 Gone",
      "Cache-Control: no-store",
      "X-Robots-Tag: noindex, nofollow",
      "X-Content-Type-Options: nosniff",
      "Content-Type: text/plain; charset=UTF-8",
      "Content-Length: 5",
      "Connection: close",
      "",
      "Gone\n"
    ].join("\r\n"), "utf8")));
  });
  await new Promise((resolve, reject) => {
    server.once("error", reject);
    server.listen(0, "127.0.0.1", resolve);
  });
  t.after(() => server.close());
  const response = await rawRequest(server.address().port, "/docs/workspace.uai", "HEAD");
  assert.deepEqual(response.body, Buffer.from("Gone\n"));
  assert.throws(() => assertRetiredResponse(response, "HEAD"));
});

test("line-ending policy makes Git blobs and checkouts LF-stable", () => {
  const attributes = readText(".gitattributes");
  for (const pattern of [
    "/.htaccess",
    "/assets/css/redirect.css",
    "/docs/MANIFEST.md",
    "/index.php",
    "/tools/build-runtime-manifests.js",
    "/tools/runtime-release.test.js",
    "/tools/verify-runtime-mirust.ps1",
    "/tools/verify-runtime-mirust.sh",
    "/version.json"
  ]) {
    assert.match(attributes, new RegExp(`^${pattern.replaceAll("/", "\\/").replace("**", "\\*\\*")} text eol=lf$`, "m"));
  }
  assert.doesNotMatch(attributes, /^\* text=/m);
});

const phpCommand = process.env.RUNTIME_PHP || firstAvailableCommand(
  process.platform === "win32" ? ["php", "C:\\php\\php.exe"] : ["php"], "-v");
test("real PHP GET/HEAD aliases and hostile paths", {
  skip: phpCommand ? false : "PHP executable unavailable; real PHP portion skipped visibly"
}, async (t) => {
  const port = await reservePort();
  const child = spawn(phpCommand, ["-S", `127.0.0.1:${port}`, "index.php"], {
    cwd: repositoryRoot,
    stdio: ["ignore", "pipe", "pipe"],
    windowsHide: true
  });
  t.after(() => {
    if (child.exitCode === null) child.kill();
  });
  await waitForServer(port, child);
  const aliases = [
    "/docs/workspace.uai",
    "/DOCS/WORKSPACE.UAI",
    "/docs/workspace.uai/",
    "/docs/workspace.uai?retired=1",
    "/docs/%77orkspace.uai",
    "/docs/workspace%2Euai"
  ];
  for (const alias of aliases) {
    assertRetiredResponse(await request(port, alias, "GET"), "GET");
    assertRetiredResponse(await rawRequest(port, alias, "HEAD"), "HEAD");
  }
  for (const hostilePath of [
    "//docs/workspace.uai",
    "/docs/%2577orkspace.uai",
    "/docs/%2e%2e/workspace.uai",
    "/docs/../workspace.uai",
    "/docs//workspace.uai",
    "/docs/workspace.uai//",
    "/docs/workspace.uai%2F%2F",
    "/%2Fdocs/workspace.uai",
    "/docs/foo%5C..%5Cworkspace.uai",
    "/docs/workspace.uai%3Fignored",
    "/docs/%ZZworkspace.uai",
    "/docs/%00workspace.uai",
    "/docs/%FFworkspace.uai"
  ]) {
    assertBadRequestResponse(await request(port, hostilePath, "GET"), "GET");
    assertBadRequestResponse(await rawRequest(port, hostilePath, "HEAD"), "HEAD");
  }

  const portal = "https://tinyrustlm.mirust.com/developer-portal/";
  for (const stalePath of [
    "/workspace.uai",
    "/assets/js/site.js",
    "/assets/css/site.css",
    "/data/pages.json",
    "/inc/site.php",
    "/tools/build-runtime-manifests.js",
    "/tools/verify-runtime-mirust.sh"
  ]) {
    assertRedirectResponse(await request(port, stalePath), portal);
  }
  assertRedirectResponse(await request(port, "/.uai/taboo.uai"),
    "https://tinyrustlm.mirust.com/docs/runtime-portal/runtime-docs/long-term-memory.uai");

  const stylesheet = await request(port, "/assets/css/redirect.css");
  assert.equal(stylesheet.statusCode, 200);
  assert.deepEqual(stylesheet.body, read("assets/css/redirect.css"));
  const stylesheetWithQuery = await request(port, "/assets/css/redirect.css?probe=literal");
  assert.equal(stylesheetWithQuery.statusCode, 200);
  assert.deepEqual(stylesheetWithQuery.body, read("assets/css/redirect.css"));
  for (const staticAlias of [
    "/ASSETS/CSS/REDIRECT.CSS", "/%61ssets/css/redirect.css",
    "/assets/css/redirect.css/"
  ]) {
    assertRedirectResponse(await request(port, staticAlias), portal);
  }
});

const apacheCommand = process.env.RUNTIME_APACHE ||
  firstAvailableCommand(process.platform === "win32" ? [
    "httpd", "apache2", "C:\\Apache24\\bin\\httpd.exe",
    "C:\\xampp\\apache\\bin\\httpd.exe",
    "C:\\Program Files\\Apache Software Foundation\\Apache24\\bin\\httpd.exe"
  ] : ["httpd", "apache2"], "-v");
test("real Apache per-directory rewrite and header integration", {
  skip: apacheCommand ? false : "Apache executable unavailable; real Apache portion skipped visibly"
}, async (t) => {
  const { port } = await startApacheFixture(t, apacheCommand, {
    passEncodedSeparatorsToApplication: true
  });
  const preview = await request(port, "/?preview=1");
  assert.equal(preview.statusCode, 200);
  assert.match(preview.body.toString("utf8"), /Migration preview/);

  for (const alias of [
    "/docs/workspace.uai", "/DOCS/WORKSPACE.UAI", "/docs/workspace.uai/",
    "/docs/workspace.uai?retired=1", "/docs/%77orkspace.uai", "/docs/workspace%2Euai"
  ]) {
    assertRetiredResponse(await request(port, alias, "GET"), "GET");
    assertRetiredResponse(await rawRequest(port, alias, "HEAD"), "HEAD");
  }
  for (const hostilePath of [
    "//docs/workspace.uai",
    "/docs//workspace.uai", "/docs/workspace.uai//",
    "/docs/workspace.uai%2F%2F", "/%2Fdocs/workspace.uai"
  ]) {
    assertBadRequestResponse(await request(port, hostilePath, "GET"), "GET");
    assertBadRequestResponse(await rawRequest(port, hostilePath, "HEAD"), "HEAD");
  }

  const portal = "https://tinyrustlm.mirust.com/developer-portal/";
  for (const stalePath of [
    "/workspace.uai", "/assets/js/site.js", "/assets/css/site.css",
    "/data/pages.json", "/inc/site.php", "/tools/build-runtime-manifests.js",
    "/tools/verify-runtime-mirust.sh"
  ]) {
    assertRedirectResponse(await request(port, stalePath), portal);
  }
  assertRedirectResponse(await request(port, "/.uai/taboo.uai"),
    "https://tinyrustlm.mirust.com/docs/runtime-portal/runtime-docs/long-term-memory.uai");

  const stylesheet = await request(port, "/assets/css/redirect.css");
  assert.equal(stylesheet.statusCode, 200);
  assert.deepEqual(stylesheet.body, read("assets/css/redirect.css"));
  const stylesheetWithQuery = await request(port, "/assets/css/redirect.css?probe=literal");
  assert.equal(stylesheetWithQuery.statusCode, 200);
  assert.deepEqual(stylesheetWithQuery.body, read("assets/css/redirect.css"));
  for (const staticAlias of [
    "/ASSETS/CSS/REDIRECT.CSS", "/%61ssets/css/redirect.css",
    "/assets/css/redirect.css/"
  ]) {
    assertRedirectResponse(await request(port, staticAlias), portal);
  }
});

test("default Apache rejects encoded separators before the application", {
  skip: apacheCommand ? false : "Apache executable unavailable; real Apache portion skipped visibly"
}, async (t) => {
  const { port } = await startApacheFixture(t, apacheCommand);
  const encodedSeparator = "/docs/workspace.uai%2F%2F";
  assertServerBoundaryRejection(await rawRequest(port, encodedSeparator, "GET"), "GET");
  assertServerBoundaryRejection(await rawRequest(port, encodedSeparator, "HEAD"), "HEAD");
  for (const boundaryPath of [
    "/docs/%2577orkspace.uai", "/docs/%2e%2e/workspace.uai",
    "/docs/../workspace.uai", "/docs/foo%5C..%5Cworkspace.uai",
    "/docs/workspace.uai%3Fignored", "/docs/%ZZworkspace.uai",
    "/docs/%00workspace.uai", "/docs/%FFworkspace.uai"
  ]) {
    assertServerBoundaryRejection(await rawRequest(port, boundaryPath, "GET"), "GET", null);
    assertServerBoundaryRejection(await rawRequest(port, boundaryPath, "HEAD"), "HEAD", null);
  }
});
