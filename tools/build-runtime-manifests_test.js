"use strict";

const assert = require("node:assert/strict");
const crypto = require("node:crypto");
const fs = require("node:fs");
const path = require("node:path");
const test = require("node:test");
const vm = require("node:vm");
const generator = require("./build-runtime-manifests.js");

const sourcePath = path.join(__dirname, "build-runtime-manifests.js");
const source = fs.readFileSync(sourcePath);
const repositoryRoot = path.dirname(__dirname);

/** Run the real generator with virtual Git blobs and a wholly in-memory stage. */
function fixture() {
  const entries = new Map();
  const key = (name) => path.resolve(name);
  const stat = (name) => {
    const entry = entries.get(key(name));
    if (!entry) throw Object.assign(new Error("ENOENT"), { code: "ENOENT" });
    return {
      mode: entry.mode,
      isFile: () => entry.kind === "file",
      isDirectory: () => entry.kind === "directory",
      isSymbolicLink: () => entry.kind === "link"
    };
  };
  const virtualFs = {
    existsSync: (name) => entries.has(key(name)),
    lstatSync: stat,
    mkdirSync(name, options = {}) {
      const absolute = key(name);
      if (options.recursive && path.dirname(absolute) !== absolute && !entries.has(path.dirname(absolute))) {
        this.mkdirSync(path.dirname(absolute), options);
      }
      if (!entries.has(absolute)) entries.set(absolute, { kind: "directory", mode: options.mode ?? 0o700 });
    },
    writeFileSync(name, bytes, options = {}) {
      const absolute = key(name);
      assert.equal(entries.get(path.dirname(absolute))?.kind, "directory");
      if (options.flag === "wx" && entries.has(absolute)) throw new Error("EEXIST");
      entries.set(absolute, { kind: "file", mode: options.mode ?? 0o600, bytes: Buffer.from(bytes) });
    },
    readFileSync(name) {
      const entry = entries.get(key(name));
      assert.equal(entry?.kind, "file");
      return Buffer.from(entry.bytes);
    },
    readdirSync(name) {
      return [...entries.keys()].filter((entry) => entry !== key(name) && path.dirname(entry) === key(name))
        .map((entry) => ({ name: path.basename(entry), ...stat(entry) }));
    },
    chmodSync(name, mode) { entries.get(key(name)).mode = mode; },
    rmSync(name, options = {}) {
      for (const entry of entries.keys()) {
        if (entry === key(name) || (options.recursive && entry.startsWith(key(name) + path.sep))) entries.delete(entry);
      }
    }
  };
  virtualFs.mkdirSync(__dirname, { recursive: true });
  virtualFs.writeFileSync(sourcePath, source);
  const blobs = new Map([
    ["tools/build-runtime-manifests.js", source],
    ["version.json", Buffer.from(JSON.stringify({ site: "Runtime.MiRust.com", status: "retired-redirect",
      updated_utc: "2030-01-02T03:04:05Z", package_version: "7.6.5-fixture.1" }) + "\n")],
    [".htaccess", Buffer.from("# inert test data\n")],
    ["index.php", Buffer.from("inert test data\n")],
    ["assets/css/redirect.css", Buffer.from("inert test data\n")],
    ["docs/index.md", Buffer.from("# In-memory fixture\n")]
  ]);
  const read = (name) => blobs.get(name);
  blobs.set("docs/MANIFEST.md", generator.buildDocsManifest(read, ["docs/index.md"]));
  blobs.set("PACKAGE-MANIFEST.md", generator.buildPackageManifest(read));
  const oid = (bytes) => crypto.createHash("sha1").update(`blob ${bytes.length}\0`).update(bytes).digest("hex");
  const moduleObject = { exports: {} };
  vm.runInNewContext(source.toString("utf8"), {
    __dirname, __filename: sourcePath, Buffer, module: moduleObject,
    process: { argv: [], stdout: { write() {} } },
    require(name) {
      if (name === "node:fs") return virtualFs;
      if (name === "node:child_process") return { spawnSync(command, args, options) {
        assert.equal(command, "git");
        assert.equal(options.encoding, null);
        assert.deepEqual(Array.from(args.slice(0, 2)), ["-C", repositoryRoot]);
        let output;
        if (args[2] === "rev-parse") output = (args.at(-1).endsWith("^{tree}") ? "b" : "a").repeat(40) + "\n";
        else if (args[2] === "ls-tree") output = [...blobs].map(([name, bytes]) => `100644 blob ${oid(bytes)}\t${name}\0`).join("");
        else if (args[2] === "cat-file") output = [...blobs.values()].find((bytes) => oid(bytes) === args.at(-1));
        else throw new Error(`Unexpected Git command: ${args[2]}`);
        assert.ok(output !== undefined);
        return { status: 0, stdout: Buffer.from(output), stderr: Buffer.alloc(0) };
      } };
      return require(name);
    }
  }, { filename: sourcePath, timeout: 5000 });
  return { api: moduleObject.exports, blobs, entries, virtualFs,
    custody: path.join(repositoryRoot, "artifacts", "virtual-custody") };
}

test("real canonical Git closure binds the unchanged generator without copying source", () => {
  const proof = generator.verifyGitClosure("HEAD");
  assert.equal(proof.generator.bytes, source.length);
  assert.equal(proof.generator.sha256, generator.sha256(source));
});

test("virtual staging retains exact blobs, seals custody and rejects reuse", () => {
  const f = fixture();
  f.virtualFs.mkdirSync(path.dirname(f.custody));
  const proof = f.api.stageGitPackage("redirect", "HEAD", f.custody);
  assert.equal(proof.status, "sealed");
  assert.equal(proof.fileCount, 5);
  assert.equal(proof.directoryCount, 2);
  const release = path.join(f.custody, proof.releaseDirectoryName);
  for (const name of [...generator.redirectPayloadPaths, "PACKAGE-MANIFEST.md"]) {
    assert.deepEqual(f.virtualFs.readFileSync(path.join(release, name)), f.blobs.get(name));
    assert.equal(f.virtualFs.lstatSync(path.join(release, name)).mode & 0o222, 0);
  }
  assert.equal(f.api.verifyCustodyRoot("redirect", "HEAD", f.custody).sha256, proof.sha256);
  assert.equal(f.api.verifyReleaseDirectory("redirect", "HEAD", release).sha256, proof.sha256);
  assert.throws(() => f.api.stageGitPackage("redirect", "HEAD", f.custody), /must not already exist/);
});

for (const [label, mutate, rejection] of [
  ["extra file", (f, root) => f.virtualFs.writeFileSync(path.join(root, "unexpected.bin"), Buffer.from("x")), /file inventory/],
  ["extra directory", (f, root) => f.virtualFs.mkdirSync(path.join(root, "unexpected")), /directory inventory/],
  ["changed bytes", (f, root) => f.entries.get(path.join(root, "index.php")).bytes = Buffer.from("drift"), /bytes differ/],
  ["writable release", (f, root) => f.virtualFs.chmodSync(root, 0o700), /not permission-sealed/],
  ["link", (f, root) => f.entries.get(path.join(root, "index.php")).kind = "link", /symbolic link/]
]) {
  test(`release verification rejects ${label} without materializing product files`, () => {
    const f = fixture();
    f.virtualFs.mkdirSync(path.dirname(f.custody));
    const proof = f.api.stageGitPackage("redirect", "HEAD", f.custody);
    const release = path.join(f.custody, proof.releaseDirectoryName);
    mutate(f, release);
    assert.throws(() => f.api.verifyReleaseDirectory("redirect", "HEAD", release), rejection);
  });
}

for (const [label, mutate, rejection] of [
  ["CRLF drift", (f) => f.blobs.set(".htaccess", Buffer.from("# inert test data\r\n")), /must already use LF/],
  ["generator drift", (f) => f.entries.get(sourcePath).bytes = Buffer.from("drift"), /generator differs/],
  ["manifest drift", (f) => f.blobs.set("PACKAGE-MANIFEST.md", Buffer.from("drift")), /does not bind/],
  ["forbidden source path", (f) => f.blobs.set("docs/workspace.uai", Buffer.from("inert")), /Permanently forbidden/]
]) {
  test(`Git verification rejects ${label} before any staging write`, () => {
    const f = fixture();
    mutate(f);
    assert.throws(() => f.api.stageGitPackage("redirect", "HEAD", f.custody), rejection);
    assert.equal(f.entries.has(f.custody), false);
  });
}

test("failed staging removes only its virtual owned custody", () => {
  const f = fixture();
  f.virtualFs.mkdirSync(path.dirname(f.custody));
  const write = f.virtualFs.writeFileSync.bind(f.virtualFs);
  f.virtualFs.writeFileSync = (name, ...args) => {
    if (path.basename(name) === "index.php") throw new Error("injected write failure");
    write(name, ...args);
  };
  assert.throws(() => f.api.stageGitPackage("redirect", "HEAD", f.custody), /injected write failure/);
  assert.equal(f.entries.has(f.custody), false);
  assert.equal(f.entries.has(sourcePath), true);
});
