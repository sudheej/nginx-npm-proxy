"use strict";

const fs = require("fs");
const path = require("path");

const marker = path.join(__dirname, "..", "build", "postinstall-ran.json");
fs.mkdirSync(path.dirname(marker), { recursive: true });
fs.writeFileSync(
  marker,
  `${JSON.stringify({
    node: process.version,
    platform: process.platform,
    arch: process.arch
  }, null, 2)}\n`
);
console.log(`[postinstall] wrote ${marker}`);
