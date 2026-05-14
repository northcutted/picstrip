#!/usr/bin/env node

import fs from "node:fs";
import path from "node:path";
import process from "node:process";
import semanticRelease from "semantic-release";

const cwd = process.cwd();
const outputPath = process.argv[2] || path.join("build", "semantic-release.json");

const result = await semanticRelease(
  {
    ci: false,
    dryRun: true
  },
  {
    cwd,
    env: process.env
  }
);

const payload = result
  ? {
      will_release: true,
      version: result.nextRelease.version,
      git_tag: result.nextRelease.gitTag,
      notes: result.nextRelease.notes || ""
    }
  : {
      will_release: false,
      version: "",
      git_tag: "",
      notes: ""
    };

fs.mkdirSync(path.dirname(outputPath), { recursive: true });
fs.writeFileSync(outputPath, `${JSON.stringify(payload, null, 2)}\n`);
process.stdout.write(`${JSON.stringify(payload)}\n`);
