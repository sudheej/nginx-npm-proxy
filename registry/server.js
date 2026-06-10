const crypto = require("crypto");
const fs = require("fs");
const path = require("path");

const express = require("express");

const app = express();
const port = Number(process.env.PORT || 4873);
const tarballBaseUrl = (process.env.TARBALL_BASE_URL || "http://localhost:8080").replace(/\/$/, "");
const publicRegistryUrl = (process.env.PUBLIC_REGISTRY_URL || "https://registry.npmjs.org").replace(/\/$/, "");
const authToken = process.env.AUTH_TOKEN || "";

const packageName = "hello-cache";
const scopedPackageName = "@myscope/hello-cache";
const version = "1.0.0";
const packageRoot = path.join(__dirname, "packages", "hello-cache");
const tarballs = {
  [packageName]: path.join(packageRoot, "hello-cache-1.0.0.tgz"),
  [scopedPackageName]: path.join(packageRoot, "scoped-hello-cache-1.0.0.tgz")
};

app.use((req, res, next) => {
  const authorization = req.get("authorization") || "";
  const authState = authorization ? "present" : "absent";
  console.log(
    `[registry] ${new Date().toISOString()} ${req.method} ${req.originalUrl} auth=${authState}`
  );

  if (authToken && authorization !== `Bearer ${authToken}`) {
    res.setHeader("WWW-Authenticate", 'Bearer realm="npm-cache-lab"');
    res.status(401).json({
      error: "unauthorized",
      message: authorization ? "Invalid bearer token." : "Bearer token required."
    });
    return;
  }

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

function rewriteTarballUrls(value) {
  if (Array.isArray(value)) {
    return value.map(rewriteTarballUrls);
  }

  if (!value || typeof value !== "object") {
    return value;
  }

  for (const [key, child] of Object.entries(value)) {
    if (key === "tarball" && typeof child === "string") {
      const upstreamUrl = new URL(child);
      value[key] = `${tarballBaseUrl}${upstreamUrl.pathname}${upstreamUrl.search}`;
    } else {
      value[key] = rewriteTarballUrls(child);
    }
  }

  return value;
}

async function proxyPublicRegistry(req, res) {
  if (req.method !== "GET" && req.method !== "HEAD") {
    return false;
  }

  const upstreamUrl = `${publicRegistryUrl}${req.originalUrl}`;
  const headers = {
    accept: req.get("accept") || "application/json",
    "user-agent": req.get("user-agent") || "npm-cache-lab"
  };

  const upstream = await fetch(upstreamUrl, {
    method: req.method,
    headers,
    redirect: "follow"
  });
  const contentType = upstream.headers.get("content-type") || "application/octet-stream";
  const buffer = Buffer.from(await upstream.arrayBuffer());

  res.status(upstream.status);
  res.setHeader("Content-Type", contentType);
  for (const headerName of ["cache-control", "etag", "last-modified"]) {
    const headerValue = upstream.headers.get(headerName);
    if (headerValue) {
      res.setHeader(headerName, headerValue);
    }
  }

  if (upstream.ok && contentType.includes("json")) {
    const metadata = rewriteTarballUrls(JSON.parse(buffer.toString("utf8")));
    const body = Buffer.from(JSON.stringify(metadata));
    console.log(
      `[registry-upstream] ${req.method} ${req.originalUrl} status=${upstream.status} bytes=${body.length}`
    );
    res.send(body);
    return true;
  }

  console.log(
    `[registry-upstream] ${req.method} ${req.originalUrl} status=${upstream.status} bytes=${buffer.length}`
  );
  res.send(buffer);
  return true;
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

app.use(async (req, res) => {
  try {
    if (await proxyPublicRegistry(req, res)) {
      return;
    }
  } catch (error) {
    console.error(`[registry-upstream] ${req.method} ${req.originalUrl} error=${error.message}`);
    res.status(502).json({
      error: "upstream_registry_error",
      message: error.message
    });
    return;
  }

  res.status(404).json({
    error: "not_found",
    method: req.method,
    path: req.originalUrl
  });
});

app.listen(port, "0.0.0.0", () => {
  console.log(`[registry] listening on http://0.0.0.0:${port}`);
  console.log(`[registry] metadata tarball base URL: ${tarballBaseUrl}`);
  console.log(`[registry] public registry fallback: ${publicRegistryUrl}`);
  console.log(`[registry] bearer authentication: ${authToken ? "required" : "disabled"}`);
});
