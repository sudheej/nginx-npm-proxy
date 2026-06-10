"use strict";

const assert = require("assert");
const fs = require("fs");
const path = require("path");

const browserDir = path.join(
  __dirname,
  "..",
  "dist",
  "cache-lab-angular-build",
  "browser"
);

assert.ok(fs.existsSync(browserDir), `Angular browser output missing: ${browserDir}`);

const files = fs.readdirSync(browserDir);
assert.ok(files.includes("index.html"), "Angular build did not emit index.html");
assert.ok(
  files.some((file) => /^main.*\.js$/.test(file)),
  "Angular build did not emit a main JavaScript bundle"
);

const bytes = files.reduce((total, file) => {
  const filePath = path.join(browserDir, file);
  return total + (fs.statSync(filePath).isFile() ? fs.statSync(filePath).size : 0);
}, 0);

assert.ok(bytes > 0, "Angular build output is empty");
console.log(`[verify] Angular production output: ${files.length} files, ${bytes} bytes`);
