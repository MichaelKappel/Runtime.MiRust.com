#!/usr/bin/env node
"use strict";

const crypto = require("node:crypto");
const fs = require("node:fs");
const path = require("node:path");
const { spawnSync } = require("node:child_process");
const { TextDecoder } = require("node:util");

const repositoryRoot = path.resolve(__dirname, "..");
const generatorRelativePath = "tools/build-runtime-manifests.js";
const packageManifestRelativePath = "PACKAGE-MANIFEST.md";
const versionRelativePath = "version.json";
const decoder = new TextDecoder("utf-8", { fatal: true });
const maximumGitOutputBytes = 64 * 1024 * 1024;
const exactRootPolicy = "exact-root-replacement-no-extra-entries-v1";
const custodyPolicy = "fresh-owner-custody-single-content-addressed-release-v1";
const sealPolicy = "read-only-permission-seal-and-reverify-v1";
const activationPolicy = "verify-inactive-release-then-atomic-pointer-swap-v1";
const forbiddenRepositoryPaths = Object.freeze([
  "docs/workspace.uai"
]);

const redirectPayloadPaths = Object.freeze([
  ".htaccess",
  "assets/css/redirect.css",
  "index.php",
  versionRelativePath
]);

function compareOrdinal(left, right) {
  return left < right ? -1 : left > right ? 1 : 0;
}

function assertRelativePath(relativePath) {
  if (typeof relativePath !== "string" || relativePath === "" ||
      relativePath.includes("\\") || path.posix.isAbsolute(relativePath)) {
    throw new Error(`Invalid repository-relative path: ${relativePath}`);
  }
  const normalized = path.posix.normalize(relativePath);
  if (normalized !== relativePath || normalized === ".." || normalized.startsWith("../")) {
    throw new Error(`Non-canonical repository-relative path: ${relativePath}`);
  }
  const foldedPath = relativePath.toLowerCase();
  if (forbiddenRepositoryPaths.some((forbiddenPath) =>
    forbiddenPath.toLowerCase() === foldedPath)) {
    throw new Error(`Permanently forbidden repository path: ${relativePath}`);
  }
  return relativePath;
}

function sha256(bytes) {
  return crypto.createHash("sha256").update(bytes).digest("hex").toUpperCase();
}

function identity(relativePath, bytes) {
  return Object.freeze({
    bytes: bytes.length,
    path: assertRelativePath(relativePath),
    sha256: sha256(bytes)
  });
}

function decodeUtf8(bytes, label) {
  try {
    if (bytes.length >= 3 && bytes[0] === 0xEF && bytes[1] === 0xBB && bytes[2] === 0xBF) {
      throw new Error("UTF-8 BOM is forbidden");
    }
    const text = decoder.decode(bytes);
    if (text.charCodeAt(0) === 0xFEFF || text.includes("\0")) {
      throw new Error("BOM and NUL are forbidden");
    }
    return text;
  } catch (error) {
    throw new Error(`${label} is not strict BOM-free UTF-8: ${error.message}`);
  }
}

function manifestIdentity(relativePath, bytes) {
  const text = decodeUtf8(bytes, relativePath);
  if (text.includes("\r")) {
    throw new Error(`Manifest input must already use LF bytes: ${relativePath}`);
  }
  return identity(relativePath, bytes);
}

function parseReleaseMetadata(bytes) {
  const text = decodeUtf8(bytes, versionRelativePath);
  let value;
  try {
    value = JSON.parse(text);
  } catch (error) {
    throw new Error(`${versionRelativePath} is not valid JSON: ${error.message}`);
  }
  if (value === null || Array.isArray(value) || typeof value !== "object") {
    throw new Error(`${versionRelativePath} must contain one JSON object`);
  }
  if (value.site !== "Runtime.MiRust.com" || value.status !== "retired-redirect") {
    throw new Error(`${versionRelativePath} does not describe the retired Runtime host`);
  }
  if (typeof value.package_version !== "string" ||
      !/^[0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z.-]+)?$/.test(value.package_version)) {
    throw new Error(`${versionRelativePath} package_version is invalid`);
  }
  if (typeof value.updated_utc !== "string" ||
      !/^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$/.test(value.updated_utc)) {
    throw new Error(`${versionRelativePath} updated_utc must be second-precision UTC`);
  }
  const instant = new Date(value.updated_utc);
  if (!Number.isFinite(instant.getTime()) ||
      instant.toISOString().replace(".000Z", "Z") !== value.updated_utc) {
    throw new Error(`${versionRelativePath} updated_utc is not a real canonical instant`);
  }
  return Object.freeze({
    packageVersion: value.package_version,
    updatedUtc: value.updated_utc
  });
}

function worktreeBytes(relativePath) {
  assertRelativePath(relativePath);
  const absolutePath = path.join(repositoryRoot, ...relativePath.split("/"));
  const stat = fs.lstatSync(absolutePath);
  if (!stat.isFile() || stat.isSymbolicLink()) {
    throw new Error(`Manifest input must be a regular file: ${relativePath}`);
  }
  return fs.readFileSync(absolutePath);
}


function buildPackageManifest(readBytes) {
  const metadata = parseReleaseMetadata(readBytes(versionRelativePath));
  const files = redirectPayloadPaths.map((relativePath) =>
    manifestIdentity(relativePath, readBytes(relativePath)));
  const totalBytes = files.reduce((sum, file) => sum + file.bytes, 0);
  const rows = files.map((file) =>
    `| \`${file.path}\` | ${file.bytes} | \`${file.sha256}\` |`);
  return Buffer.from([
    "# Runtime.MiRust.com Redirect Package Manifest",
    "",
    "- Status: retired redirect package",
    `- Updated UTC: ${metadata.updatedUtc}`,
    `- Package version: ${metadata.packageVersion}`,
    "- Canonical developer portal: https://tinyrustlm.mirust.com/developer-portal/",
    `- Files excluding this manifest: ${files.length}`,
    `- Exact payload bytes excluding this manifest: ${totalBytes}`,
    "",
    "This manifest describes the complete Runtime web-root redirect payload:",
    "the front controller, its stylesheet, Apache policy, and release metadata.",
    "It intentionally excludes source memory, historical docs, build tools, and",
    "verification receipts from the deployment package.",
    "",
    "Every size and digest binds the exact file bytes. No newline, encoding, or",
    "line-ending normalization is permitted. `PACKAGE-MANIFEST.md` is excluded",
    "to avoid self-reference, but the deterministic Git staging command includes",
    "it after proving that its committed blob equals regenerated manifest bytes.",
    "Verification also binds the executing generator to its selected Git blob.",
    "The content-addressed release directory must equal this package exactly;",
    "overlay files and extra directories are forbidden. Staging places one",
    "permission-sealed release in a fresh custody root. Activation must verify a",
    "new inactive destination and atomically replace one release pointer; it must",
    "never copy package files into the currently active web root.",
    "",
    "| Path | Bytes | SHA-256 |",
    "| --- | ---: | --- |",
    ...rows,
    ""
  ].join("\n"), "utf8");
}

function generatedWorktreeDocuments() {
  return new Map([
    [packageManifestRelativePath, buildPackageManifest(worktreeBytes)]
  ]);
}

function applyDocument(relativePath, expectedBytes, mode) {
  const absolutePath = path.join(repositoryRoot, ...relativePath.split("/"));
  if (mode === "--print") {
    process.stdout.write(`===== ${relativePath} =====\n`);
    process.stdout.write(expectedBytes);
    return;
  }
  if (mode === "--write") {
    fs.writeFileSync(absolutePath, expectedBytes);
    process.stdout.write(`WROTE ${relativePath}\n`);
    return;
  }
  const actualBytes = fs.readFileSync(absolutePath);
  if (!actualBytes.equals(expectedBytes)) {
    throw new Error(`Manifest bytes are stale or normalized: ${relativePath}`);
  }
  process.stdout.write(`VALID ${relativePath}\n`);
}

function runGit(argumentsList) {
  const result = spawnSync("git", ["-C", repositoryRoot, ...argumentsList], {
    encoding: null,
    maxBuffer: maximumGitOutputBytes,
    windowsHide: true
  });
  if (result.error) {
    throw result.error;
  }
  if (result.status !== 0) {
    const diagnostic = Buffer.isBuffer(result.stderr)
      ? result.stderr.toString("utf8").trim()
      : "";
    throw new Error(`git ${argumentsList[0]} failed${diagnostic ? `: ${diagnostic}` : ""}`);
  }
  return result.stdout;
}

function resolveGitClosure(reference) {
  if (typeof reference !== "string" || reference === "" || reference.includes("\0")) {
    throw new Error("Git reference is required");
  }
  const commit = runGit(["rev-parse", "--verify", `${reference}^{commit}`])
    .toString("ascii").trim();
  const tree = runGit(["rev-parse", "--verify", `${commit}^{tree}`])
    .toString("ascii").trim();
  if (!/^[0-9a-f]{40,64}$/.test(commit) || !/^[0-9a-f]{40,64}$/.test(tree)) {
    throw new Error("Git returned an invalid commit or tree identity");
  }
  return Object.freeze({ commit, tree });
}

function readGitInventory(commit) {
  const raw = runGit(["ls-tree", "-r", "-z", commit]);
  const inventory = new Map();
  for (const record of raw.toString("utf8").split("\0")) {
    if (record === "") continue;
    const match = /^(100644|100755) blob ([0-9a-f]{40,64})\t(.+)$/.exec(record);
    if (match === null) {
      throw new Error(`Unsupported Git tree entry: ${record}`);
    }
    const relativePath = assertRelativePath(match[3]);
    if (inventory.has(relativePath)) {
      throw new Error(`Duplicate Git tree path: ${relativePath}`);
    }
    inventory.set(relativePath, Object.freeze({ mode: match[1], oid: match[2] }));
  }
  return inventory;
}

function createGitReader(inventory) {
  return (relativePath) => {
    assertRelativePath(relativePath);
    const entry = inventory.get(relativePath);
    if (entry === undefined) {
      throw new Error(`Git commit omits required path: ${relativePath}`);
    }
    return runGit(["cat-file", "blob", entry.oid]);
  };
}

function verifyExecutingGenerator(inventory, readBytes) {
  const entry = inventory.get(generatorRelativePath);
  if (entry === undefined) {
    throw new Error(`Git commit omits required generator: ${generatorRelativePath}`);
  }
  const stat = fs.lstatSync(__filename);
  if (!stat.isFile() || stat.isSymbolicLink()) {
    throw new Error("Executing manifest generator must be one regular file");
  }
  const executingBytes = fs.readFileSync(__filename);
  const committedBytes = readBytes(generatorRelativePath);
  if (!executingBytes.equals(committedBytes)) {
    throw new Error("Executing manifest generator differs from the selected Git blob");
  }
  return Object.freeze({
    ...identity(generatorRelativePath, executingBytes),
    gitBlobOid: entry.oid
  });
}

function expectedGitDocuments(inventory, readBytes) {
  if ([...inventory.keys()].some((relativePath) => relativePath.startsWith("docs/"))) {
    throw new Error("Retired Runtime documentation belongs only in Git history");
  }
  return new Map([
    [packageManifestRelativePath, buildPackageManifest(readBytes)]
  ]);
}

function verifyGitClosure(reference) {
  const closure = resolveGitClosure(reference);
  const inventory = readGitInventory(closure.commit);
  const readBytes = createGitReader(inventory);
  const generator = verifyExecutingGenerator(inventory, readBytes);
  const documents = expectedGitDocuments(inventory, readBytes);
  for (const [relativePath, expectedBytes] of documents) {
    const actualBytes = readBytes(relativePath);
    if (!actualBytes.equals(expectedBytes)) {
      throw new Error(`Committed manifest does not bind its Git blobs: ${relativePath}`);
    }
  }
  return Object.freeze({ ...closure, generator, inventory, readBytes, documents });
}

function aggregateIdentity(entries) {
  const hash = crypto.createHash("sha256");
  let totalBytes = 0;
  const orderedEntries = [...entries].sort((left, right) => compareOrdinal(left.path, right.path));
  for (let index = 1; index < orderedEntries.length; index++) {
    if (orderedEntries[index - 1].path === orderedEntries[index].path) {
      throw new Error(`Duplicate aggregate path: ${orderedEntries[index].path}`);
    }
  }
  for (const entry of orderedEntries) {
    const pathBytes = Buffer.from(entry.path, "utf8");
    const lengthBytes = Buffer.alloc(8);
    lengthBytes.writeBigUInt64BE(BigInt(entry.bytes.length));
    hash.update(pathBytes);
    hash.update(Buffer.from([0]));
    hash.update(lengthBytes);
    hash.update(entry.bytes);
    totalBytes += entry.bytes.length;
  }
  return Object.freeze({
    fileCount: entries.length,
    totalBytes,
    sha256: hash.digest("hex").toUpperCase()
  });
}

function packageRelativePaths(kind, verified) {
  if (kind === "redirect") {
    return [...redirectPayloadPaths, packageManifestRelativePath].sort(compareOrdinal);
  }
  throw new Error("Package kind must be redirect; the retired docs package is unsupported");
}

function packageEntries(kind, verified) {
  return packageRelativePaths(kind, verified).map((relativePath) =>
    Object.freeze({ path: relativePath, bytes: verified.readBytes(relativePath) }));
}

function packageDescriptor(kind, verified) {
  const aggregate = aggregateIdentity(packageEntries(kind, verified));
  return Object.freeze({
    kind,
    ...aggregate,
    releaseDirectoryName:
      `runtime-mirust-${kind}-sha256-${aggregate.sha256.toLowerCase()}`
  });
}

function expectedDirectoryPaths(relativePaths) {
  const directories = new Set();
  for (const relativePath of relativePaths) {
    let directory = path.posix.dirname(relativePath);
    while (directory !== ".") {
      directories.add(directory);
      directory = path.posix.dirname(directory);
    }
  }
  return [...directories].sort(compareOrdinal);
}

function inspectMaterializedRoot(directory) {
  const rootStat = fs.lstatSync(directory);
  if (!rootStat.isDirectory() || rootStat.isSymbolicLink()) {
    throw new Error("Materialized root must be one regular directory");
  }
  const files = [];
  const directories = [];
  function walk(currentDirectory) {
    for (const entry of fs.readdirSync(currentDirectory, { withFileTypes: true })
      .sort((left, right) => compareOrdinal(left.name, right.name))) {
      const absolutePath = path.join(currentDirectory, entry.name);
      const relativePath = assertRelativePath(
        path.relative(directory, absolutePath).split(path.sep).join("/"));
      if (entry.isSymbolicLink()) {
        throw new Error(`Materialized root contains a symbolic link: ${relativePath}`);
      }
      if (entry.isDirectory()) {
        directories.push(relativePath);
        walk(absolutePath);
      } else if (entry.isFile()) {
        files.push(relativePath);
      } else {
        throw new Error(`Materialized root contains an unsupported entry: ${relativePath}`);
      }
    }
  }
  walk(directory);
  return Object.freeze({
    directories: directories.sort(compareOrdinal),
    files: files.sort(compareOrdinal)
  });
}

function verifyMaterializedRootAgainstClosure(kind, verified, directory) {
  const outputRoot = path.resolve(directory);
  const relativePaths = packageRelativePaths(kind, verified);
  const expectedDirectories = expectedDirectoryPaths(relativePaths);
  const actual = inspectMaterializedRoot(outputRoot);
  if (JSON.stringify(actual.files) !== JSON.stringify(relativePaths)) {
    throw new Error("Materialized file inventory does not equal the package inventory");
  }
  if (JSON.stringify(actual.directories) !== JSON.stringify(expectedDirectories)) {
    throw new Error("Materialized directory inventory does not equal the package inventory");
  }
  const entries = relativePaths.map((relativePath) => {
    const expectedBytes = verified.readBytes(relativePath);
    const actualBytes = fs.readFileSync(path.join(outputRoot, ...relativePath.split("/")));
    if (!actualBytes.equals(expectedBytes)) {
      throw new Error(`Materialized bytes differ from Git blob: ${relativePath}`);
    }
    return Object.freeze({ path: relativePath, bytes: actualBytes });
  });
  const descriptor = packageDescriptor(kind, verified);
  const actualIdentity = aggregateIdentity(entries);
  if (actualIdentity.fileCount !== descriptor.fileCount ||
      actualIdentity.totalBytes !== descriptor.totalBytes ||
      actualIdentity.sha256 !== descriptor.sha256) {
    throw new Error("Materialized package identity differs from its Git closure");
  }
  return Object.freeze({
    schema: "runtime.mirust.git_blob_root_verification.v3",
    ...descriptor,
    rootPolicy: exactRootPolicy,
    commit: verified.commit,
    tree: verified.tree,
    generator: verified.generator,
    directoryCount: expectedDirectories.length
  });
}

function permissionBits(stat) {
  return stat.mode & 0o777;
}

function assertPermissionSealed(absolutePath, label) {
  const stat = fs.lstatSync(absolutePath);
  if (stat.isSymbolicLink() || (permissionBits(stat) & 0o222) !== 0) {
    throw new Error(`${label} is not permission-sealed against ordinary writes`);
  }
}

function sealReleaseDirectory(directory, relativePaths) {
  for (const relativePath of relativePaths) {
    fs.chmodSync(path.join(directory, ...relativePath.split("/")), 0o444);
  }
  const directories = expectedDirectoryPaths(relativePaths)
    .sort((left, right) => right.split("/").length - left.split("/").length ||
      compareOrdinal(right, left));
  for (const relativePath of directories) {
    fs.chmodSync(path.join(directory, ...relativePath.split("/")), 0o555);
  }
  fs.chmodSync(directory, 0o555);
}

function verifyReleaseSeal(directory, relativePaths) {
  assertPermissionSealed(directory, "Release directory");
  for (const relativePath of expectedDirectoryPaths(relativePaths)) {
    assertPermissionSealed(path.join(directory, ...relativePath.split("/")),
      `Release child directory ${relativePath}`);
  }
  for (const relativePath of relativePaths) {
    assertPermissionSealed(path.join(directory, ...relativePath.split("/")),
      `Release file ${relativePath}`);
  }
}

function assertExistingDirectoryChainHasNoLinks(directory) {
  let current = path.resolve(directory);
  while (true) {
    const stat = fs.lstatSync(current);
    if (!stat.isDirectory() || stat.isSymbolicLink()) {
      throw new Error(`Custody parent chain contains a non-directory or link: ${current}`);
    }
    const parent = path.dirname(current);
    if (parent === current) return;
    current = parent;
  }
}

function makeOwnedTreeWritable(directory) {
  if (!fs.existsSync(directory)) return;
  const stat = fs.lstatSync(directory);
  if (stat.isSymbolicLink() || !stat.isDirectory()) {
    fs.rmSync(directory, { force: true });
    return;
  }
  fs.chmodSync(directory, 0o700);
  for (const entry of fs.readdirSync(directory, { withFileTypes: true })) {
    const child = path.join(directory, entry.name);
    if (entry.isDirectory() && !entry.isSymbolicLink()) {
      makeOwnedTreeWritable(child);
    } else if (entry.isSymbolicLink()) {
      fs.rmSync(child, { force: true });
    } else {
      fs.chmodSync(child, 0o600);
    }
  }
}

function removeOwnedTree(directory) {
  if (!fs.existsSync(directory)) return;
  makeOwnedTreeWritable(directory);
  fs.rmSync(directory, { recursive: true, force: true });
}

function verifyReleaseDirectoryAgainstClosure(kind, verified, directory) {
  const releaseRoot = path.resolve(directory);
  const descriptor = packageDescriptor(kind, verified);
  if (path.basename(releaseRoot) !== descriptor.releaseDirectoryName) {
    throw new Error("Release directory name does not equal its package content address");
  }
  const proof = verifyMaterializedRootAgainstClosure(kind, verified, releaseRoot);
  verifyReleaseSeal(releaseRoot, packageRelativePaths(kind, verified));
  return Object.freeze({
    ...proof,
    schema: "runtime.mirust.git_blob_release_verification.v3",
    sealPolicy,
    activationPolicy,
    sealed: true
  });
}

function verifyReleaseDirectory(kind, reference, directory) {
  return verifyReleaseDirectoryAgainstClosure(
    kind, verifyGitClosure(reference), path.resolve(directory));
}

function verifyCustodyRootAgainstClosure(kind, verified, directory) {
  const custodyRoot = path.resolve(directory);
  const descriptor = packageDescriptor(kind, verified);
  const custodyStat = fs.lstatSync(custodyRoot);
  if (!custodyStat.isDirectory() || custodyStat.isSymbolicLink()) {
    throw new Error("Custody root must be one regular directory");
  }
  assertPermissionSealed(custodyRoot, "Custody root");
  const entries = fs.readdirSync(custodyRoot, { withFileTypes: true });
  if (entries.length !== 1 || entries[0].name !== descriptor.releaseDirectoryName ||
      !entries[0].isDirectory() || entries[0].isSymbolicLink()) {
    throw new Error("Custody root must contain only its content-addressed release directory");
  }
  const releaseProof = verifyReleaseDirectoryAgainstClosure(
    kind, verified, path.join(custodyRoot, descriptor.releaseDirectoryName));
  return Object.freeze({
    ...releaseProof,
    schema: "runtime.mirust.git_blob_custody_verification.v3",
    custodyPolicy
  });
}

function verifyCustodyRoot(kind, reference, directory) {
  return verifyCustodyRootAgainstClosure(
    kind, verifyGitClosure(reference), path.resolve(directory));
}

function stageGitPackage(kind, reference, custodyDirectory) {
  const verified = verifyGitClosure(reference);
  const custodyRoot = path.resolve(custodyDirectory);
  if (fs.existsSync(custodyRoot)) {
    throw new Error("Custody root must not already exist");
  }
  assertExistingDirectoryChainHasNoLinks(path.dirname(custodyRoot));
  const descriptor = packageDescriptor(kind, verified);
  const outputRoot = path.join(custodyRoot, descriptor.releaseDirectoryName);
  const relativePaths = packageRelativePaths(kind, verified);
  fs.mkdirSync(custodyRoot, { recursive: false, mode: 0o700 });
  try {
    fs.mkdirSync(outputRoot, { recursive: false, mode: 0o700 });
    for (const relativePath of relativePaths) {
      const bytes = verified.readBytes(relativePath);
      const destination = path.join(outputRoot, ...relativePath.split("/"));
      fs.mkdirSync(path.dirname(destination), { recursive: true, mode: 0o700 });
      fs.writeFileSync(destination, bytes, { flag: "wx", mode: 0o600 });
      const actualBytes = fs.readFileSync(destination);
      if (!actualBytes.equals(bytes)) {
        throw new Error(`Staged bytes differ from Git blob: ${relativePath}`);
      }
    }
    verifyMaterializedRootAgainstClosure(kind, verified, outputRoot);
    sealReleaseDirectory(outputRoot, relativePaths);
    fs.chmodSync(custodyRoot, 0o500);
    const proof = verifyCustodyRootAgainstClosure(kind, verified, custodyRoot);
    return Object.freeze({
      ...proof,
      schema: "runtime.mirust.git_blob_custody_stage.v3",
      status: "sealed"
    });
  } catch (error) {
    removeOwnedTree(custodyRoot);
    throw error;
  }
}

function usage() {
  return [
    "Usage:",
    "  node tools/build-runtime-manifests.js [--check|--print|--write]",
    "  node tools/build-runtime-manifests.js --verify-git <ref>",
    "  node tools/build-runtime-manifests.js --stage-git redirect <ref> <new-custody-root>",
    "  node tools/build-runtime-manifests.js --verify-custody redirect <ref> <custody-root>",
    "  node tools/build-runtime-manifests.js --verify-release redirect <ref> <release-directory>"
  ].join("\n");
}

function main(argumentsList = process.argv.slice(2)) {
  const mode = argumentsList[0] || "--check";
  if (["--check", "--print", "--write"].includes(mode) && argumentsList.length <= 1) {
    for (const [relativePath, expectedBytes] of generatedWorktreeDocuments()) {
      applyDocument(relativePath, expectedBytes, mode);
    }
    return;
  }
  if (mode === "--verify-git" && argumentsList.length === 2) {
    const verified = verifyGitClosure(argumentsList[1]);
    process.stdout.write(`${JSON.stringify({
      schema: "runtime.mirust.git_blob_manifest_verification.v2",
      commit: verified.commit,
      tree: verified.tree,
      generator: verified.generator,
      policies: {
        root: exactRootPolicy,
        custody: custodyPolicy,
        seal: sealPolicy,
        activation: activationPolicy
      },
      status: "pass"
    })}\n`);
    return;
  }
  if (mode === "--stage-git" && argumentsList.length === 4) {
    const proof = stageGitPackage(argumentsList[1], argumentsList[2], argumentsList[3]);
    process.stdout.write(`${JSON.stringify(proof)}\n`);
    return;
  }
  if (mode === "--verify-custody" && argumentsList.length === 4) {
    const proof = verifyCustodyRoot(argumentsList[1], argumentsList[2], argumentsList[3]);
    process.stdout.write(`${JSON.stringify(proof)}\n`);
    return;
  }
  if (mode === "--verify-release" && argumentsList.length === 4) {
    const proof = verifyReleaseDirectory(argumentsList[1], argumentsList[2], argumentsList[3]);
    process.stdout.write(`${JSON.stringify(proof)}\n`);
    return;
  }
  throw new Error(usage());
}

if (require.main === module) {
  try {
    main();
  } catch (error) {
    process.stderr.write(`ERROR: ${error.message}\n`);
    process.exitCode = 1;
  }
}

module.exports = Object.freeze({
  activationPolicy,
  aggregateIdentity,
  buildPackageManifest,
  compareOrdinal,
  custodyPolicy,
  exactRootPolicy,
  forbiddenRepositoryPaths,
  generatedWorktreeDocuments,
  generatorRelativePath,
  identity,
  packageDescriptor,
  parseReleaseMetadata,
  redirectPayloadPaths,
  resolveGitClosure,
  sha256,
  sealPolicy,
  stageGitPackage,
  verifyGitClosure,
  verifyCustodyRoot,
  verifyReleaseDirectory,
  worktreeBytes
});
