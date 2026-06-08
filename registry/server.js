const crypto = require("crypto");
const fs = require("fs");
const path = require("path");

const express = require("express");

const app = express();
const port = Number(process.env.PORT || 4873);
const tarballBaseUrl = (process.env.TARBALL_BASE_URL || "http://localhost:8080").replace(/\/$/, "");

const packageName = "hello-cache";
const scopedPackageName = "@myscope/hello-cache";
const version = "1.0.0";
const packageRoot = path.join(__dirname, "packages", "hello-cache");
const tarballs = {
  [packageName]: path.join(packageRoot, "hello-cache-1.0.0.tgz"),
  [scopedPackageName]: path.join(packageRoot, "scoped-hello-cache-1.0.0.tgz")
};

app.use((req, res, next) => {
  console.log(`[registry] ${new Date().toISOString()} ${req.method} ${req.originalUrl}`);
  next();
});

function tarballInfo(name, tarballUrlPath) {
  const result = {
    tarball: `${tarballBaseUrl}${tarballUrlPath}`
  };

  const tarballPath = tarballs[name];
  if (fs.existsSync(tarballPath)) {
    const data = fs.readFileSync(tarballPath);
    result.shasum = crypto.createHash("sha1").update(data).digest("hex");
    result.integrity = `sha512-${crypto.createHash("sha512").update(data).digest("base64")}`;
  }

  return result;
}

function packageVersionMetadata(name, tarballUrlPath) {
  return {
    name,
    version,
    description: "Small package for NGINX npm tarball cache experiments.",
    main: "index.js",
    dist: tarballInfo(name, tarballUrlPath)
  };
}

function packument(name, tarballUrlPath) {
  return {
    name,
    "dist-tags": {
      latest: version
    },
    versions: {
      [version]: packageVersionMetadata(name, tarballUrlPath)
    }
  };
}

function sendTarball(name, req, res) {
  const tarballPath = tarballs[name];

  if (!fs.existsSync(tarballPath)) {
    res.status(404).json({
      error: "tarball_not_built",
      message: "Run ./scripts/build-package.sh before installing."
    });
    return;
  }

  res.setHeader("Content-Type", "application/octet-stream");
  res.setHeader("Cache-Control", "public, max-age=31536000, immutable");
  res.sendFile(tarballPath);
}

app.get("/hello-cache", (req, res) => {
  res.json(packument(packageName, "/hello-cache/-/hello-cache-1.0.0.tgz"));
});

app.get("/hello-cache/-/hello-cache-1.0.0.tgz", (req, res) => {
  sendTarball(packageName, req, res);
});

app.get("*", (req, res, next) => {
  const normalizedPath = req.path.replace(/%2f/ig, "/");

  if (normalizedPath === "/@myscope/hello-cache") {
    res.json(packument(scopedPackageName, "/@myscope/hello-cache/-/hello-cache-1.0.0.tgz"));
    return;
  }

  if (normalizedPath === "/@myscope/hello-cache/-/hello-cache-1.0.0.tgz") {
    sendTarball(scopedPackageName, req, res);
    return;
  }

  next();
});

app.get("/-/ping", (req, res) => {
  res.json({ ok: true });
});

app.use((req, res) => {
  res.status(404).json({
    error: "not_found",
    method: req.method,
    path: req.originalUrl
  });
});

app.listen(port, "0.0.0.0", () => {
  console.log(`[registry] listening on http://0.0.0.0:${port}`);
  console.log(`[registry] metadata tarball base URL: ${tarballBaseUrl}`);
});
