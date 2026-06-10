"use strict";

const assert = require("assert");
const fs = require("fs");
const path = require("path");

const root = path.join(__dirname, "..");
const addonPath = path.join(root, "build", "Release", "cache_lab_addon.node");
const markerPath = path.join(root, "build", "postinstall-ran.json");

assert.ok(fs.existsSync(addonPath), `node-gyp output missing: ${addonPath}`);
assert.ok(fs.existsSync(markerPath), `postinstall marker missing: ${markerPath}`);

const addon = require(addonPath);
assert.strictEqual(addon.add(19, 23), 42, "compiled addon returned wrong result");

const sharp = require("sharp");
const versions = sharp.versions;
assert.ok(versions && versions.vips, "sharp did not load its native libvips binary");

sharp({
  create: {
    width: 2,
    height: 2,
    channels: 4,
    background: "#336699"
  }
})
  .png()
  .toBuffer()
  .then((buffer) => {
    assert.ok(buffer.length > 8, "sharp produced an invalid PNG");
    assert.strictEqual(buffer.subarray(1, 4).toString("ascii"), "PNG");
    console.log(
      `[verify] node-gyp addon loaded; sharp loaded libvips ${versions.vips}`
    );
  })
  .catch((error) => {
    console.error(error);
    process.exitCode = 1;
  });
