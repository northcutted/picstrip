#!/usr/bin/env node
/* eslint-disable no-console */
//
// Pseudo-localize Apple .xcstrings catalogs for layout smoke testing.
//
// PicStrip's production translations are LLM-generated and committed directly
// into the catalogs and fastlane/metadata/<locale>/ files. English is the
// canonical source; translations are edited inline when something reads off.
//
// What this script is for: pre-translation layout smoke testing.
// Running ``--languages de fr ja`` over a catalog produces ``[de] Save photo``
// strings that exercise the same code paths as a real translation but with
// loud markers, so you can spot truncation, overflow, or RTL mirroring bugs
// in the UI before the real strings land.
//
// Usage:
//   scripts/translate_xcstrings.js --languages es fr de ja
//   scripts/translate_xcstrings.js --files fastlane/MarketingHeadlines.xcstrings --languages de
//   scripts/translate_xcstrings.js --languages ar --dry-run

const fs = require("fs");

const DEFAULT_FILES = [
  "PicStrip/Localizable.xcstrings",
  "PicStrip/AppShortcuts.xcstrings"
];

function parseArgs(argv) {
  const args = {
    files: [],
    languages: [],
    dryRun: false,
    force: false,
    state: process.env.LOCALIZATION_STRING_STATE || "translated"
  };

  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    const next = () => argv[++index];

    switch (arg) {
    case "--files":
      args.files = collectValues(argv, index + 1);
      index += args.files.length;
      break;
    case "--languages":
      args.languages = collectValues(argv, index + 1);
      index += args.languages.length;
      break;
    case "--state":
      args.state = next();
      break;
    case "--dry-run":
      args.dryRun = true;
      break;
    case "--force":
      args.force = true;
      break;
    case "--help":
    case "-h":
      printHelp();
      process.exit(0);
      break;
    default:
      throw new Error(`Unknown argument: ${arg}`);
    }
  }

  if (args.files.length === 0) {
    args.files = DEFAULT_FILES;
  }

  if (args.languages.length === 0) {
    const envLanguages = process.env.LOCALIZATION_LANGUAGES || process.env.LANGUAGES || "";
    args.languages = envLanguages.split(/[,\s]+/).filter(Boolean);
  }

  if (args.languages.length === 0) {
    throw new Error("Pass --languages, for example: --languages es fr de ja");
  }

  return args;
}

function collectValues(argv, startIndex) {
  const values = [];
  for (let index = startIndex; index < argv.length; index += 1) {
    if (argv[index].startsWith("--")) {
      break;
    }
    values.push(argv[index]);
  }
  return values;
}

function printHelp() {
  console.log(`Pseudo-localize PicStrip string catalogs for layout smoke testing.

Usage:
  scripts/translate_xcstrings.js --languages es fr de
  scripts/translate_xcstrings.js --files fastlane/MarketingHeadlines.xcstrings --languages de
  scripts/translate_xcstrings.js --languages ar --dry-run

Options:
  --files <paths...>       .xcstrings files to update (default: app catalogs)
  --languages <codes...>   BCP-47 language codes, e.g. es fr de ja zh-Hans
  --state <state>          String catalog state to write (default: translated)
  --force                  Replace existing target-language values
  --dry-run                Print what would change without writing files
`);
}

function readCatalog(filePath) {
  const raw = fs.readFileSync(filePath, "utf8");
  return JSON.parse(raw);
}

function writeCatalog(filePath, catalog) {
  fs.writeFileSync(filePath, `${JSON.stringify(catalog, null, 2)}\n`, "utf8");
}

function sourceValue(catalog, entry) {
  const sourceLang = catalog.sourceLanguage || "en";
  const localizations = entry.localizations || {};
  return localizations[sourceLang]?.stringUnit?.value;
}

function targetValue(entry, language) {
  return entry.localizations?.[language]?.stringUnit?.value;
}

function setTargetValue(entry, language, value, state) {
  entry.localizations = entry.localizations || {};
  entry.localizations[language] = {
    stringUnit: { state, value }
  };
}

function collectWork(catalog, filePath, languages, force) {
  const work = [];
  const sourceLanguage = catalog.sourceLanguage || "en";
  for (const [key, entry] of Object.entries(catalog.strings || {})) {
    const source = sourceValue(catalog, entry);
    if (typeof source !== "string" || source.length === 0) continue;
    for (const language of languages) {
      if (language === sourceLanguage) continue;
      if (!force && typeof targetValue(entry, language) === "string") continue;
      work.push({ filePath, key, language, source });
    }
  }
  return work;
}

function pseudoTranslate(value, language) {
  return `[${language}] ${value}`;
}

function main() {
  const options = parseArgs(process.argv.slice(2));
  const catalogs = new Map();
  const work = [];

  for (const filePath of options.files) {
    const catalog = readCatalog(filePath);
    catalogs.set(filePath, catalog);
    work.push(...collectWork(catalog, filePath, options.languages, options.force));
  }

  if (work.length === 0) {
    console.log("All requested localizations are already present.");
    return;
  }

  console.log(
    `Preparing ${work.length} pseudo-translation${work.length === 1 ? "" : "s"} `
    + `across ${options.files.length} catalog${options.files.length === 1 ? "" : "s"}.`
  );
  if (options.dryRun) {
    for (const item of work.slice(0, 20)) {
      console.log(`[dry-run] ${item.filePath} ${item.language}: ${item.key}`);
    }
    if (work.length > 20) {
      console.log(`[dry-run] ...and ${work.length - 20} more.`);
    }
    return;
  }

  for (const item of work) {
    const translated = pseudoTranslate(item.source, item.language);
    const catalog = catalogs.get(item.filePath);
    const entry = catalog.strings[item.key];
    setTargetValue(entry, item.language, translated, options.state);
  }

  for (const [filePath, catalog] of catalogs.entries()) {
    writeCatalog(filePath, catalog);
    console.log(`Updated ${filePath}`);
  }
}

try {
  main();
} catch (error) {
  console.error(error.message);
  process.exit(1);
}
