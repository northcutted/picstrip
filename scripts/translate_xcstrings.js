#!/usr/bin/env node
/* eslint-disable no-console */

const fs = require("fs");
const crypto = require("crypto");

const DEFAULT_FILES = [
  "PicStrip/Localizable.xcstrings",
  "PicStrip/AppShortcuts.xcstrings"
];

function parseArgs(argv) {
  const args = {
    files: [],
    languages: [],
    provider: process.env.LOCALIZATION_PROVIDER || "pseudo",
    model: process.env.OPENAI_TRANSLATION_MODEL || "gpt-4.1-mini",
    batchSize: Number(process.env.LOCALIZATION_BATCH_SIZE || 30),
    concurrency: Number(process.env.LOCALIZATION_CONCURRENCY || 5),
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
    case "--provider":
      args.provider = next();
      break;
    case "--model":
      args.model = next();
      break;
    case "--batch-size":
      args.batchSize = Number(next());
      break;
    case "--concurrency":
      args.concurrency = Number(next());
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

  if (!Number.isFinite(args.batchSize) || args.batchSize < 1) {
    throw new Error("--batch-size must be a positive number");
  }

  if (!Number.isFinite(args.concurrency) || args.concurrency < 1) {
    throw new Error("--concurrency must be a positive number");
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
  console.log(`Translate PicStrip string catalogs.

Usage:
  scripts/translate_xcstrings.js --languages es fr de
  scripts/translate_xcstrings.js --provider openai --languages es fr
  scripts/translate_xcstrings.js --provider pseudo --languages ar --dry-run

Options:
  --files <paths...>       .xcstrings files to update
  --languages <codes...>   BCP-47 language codes, e.g. es fr de ja zh-Hans
  --provider <name>        pseudo or openai
  --model <name>           OpenAI model when --provider openai is used
  --batch-size <number>    Strings per translation request (default 30)
  --concurrency <number>   Parallel requests in flight at once (default 5)
  --state <state>          String catalog state for generated localizations
  --force                  Replace existing target-language values
  --dry-run                Print what would change without writing files
`);
}

function readCatalog(filePath) {
  const raw = fs.readFileSync(filePath, "utf8");
  return JSON.parse(raw);
}

function writeCatalog(filePath, catalog) {
  catalog.strings = Object.fromEntries(
    Object.entries(catalog.strings || {}).sort(([lhs], [rhs]) => lhs.localeCompare(rhs))
  );
  fs.writeFileSync(filePath, `${JSON.stringify(catalog, null, 2)}\n`);
}

function sourceValue(entry, key, sourceLanguage) {
  const localization = entry.localizations?.[sourceLanguage];
  return localization?.stringUnit?.value ?? (key.length > 0 ? key : null);
}

function targetValue(entry, language) {
  return entry.localizations?.[language]?.stringUnit?.value;
}

function setTargetValue(entry, language, value, state) {
  entry.localizations ||= {};
  entry.localizations[language] = {
    stringUnit: {
      state,
      value
    }
  };
}

function collectWork(catalog, filePath, languages, force) {
  const sourceLanguage = catalog.sourceLanguage || "en";
  const work = [];

  for (const [key, entry] of Object.entries(catalog.strings || {})) {
    const value = sourceValue(entry, key, sourceLanguage);
    if (!value || value.trim().length === 0) {
      continue;
    }

    for (const language of languages) {
      if (!force && targetValue(entry, language)) {
        continue;
      }

      work.push({
        id: stableId(filePath, key, language),
        filePath,
        key,
        language,
        sourceLanguage,
        source: value
      });
    }
  }

  return work;
}

function stableId(filePath, key, language) {
  const base = `${filePath}:${language}:${key}`;
  return crypto.createHash("sha256").update(base).digest("hex").slice(0, 24);
}

function chunks(items, size) {
  const result = [];
  for (let index = 0; index < items.length; index += size) {
    result.push(items.slice(index, index + size));
  }
  return result;
}

async function translateBatch(provider, batch, options) {
  switch (provider) {
  case "pseudo":
    return Object.fromEntries(batch.map((item) => [item.id, pseudoTranslate(item.source, item.language)]));
  case "openai":
    return openAITranslateBatch(batch, options);
  default:
    throw new Error(`Unsupported provider: ${provider}`);
  }
}

function pseudoTranslate(value, language) {
  return `[${language}] ${value}`;
}

// ── Inflection-markup helpers ─────────────────────────────────────────────────
// Apple's `^[text](inflect: true)` syntax is uncommon enough that LLMs often
// drop or mangle it.  We normalise it to XML-style <INFLECT> tags before
// sending to the provider and restore it afterwards.
//
//   ^[%lld photo](inflect: true)  →  <INFLECT>%lld photo</INFLECT>

const INFLECT_SOURCE_RE = /\^\[([^\]]*)\]\(inflect: true\)/g;
const INFLECT_TAG_RE    = /<INFLECT>([\s\S]*?)<\/INFLECT>/g;

function encodeInflections(value) {
  return value.replace(INFLECT_SOURCE_RE, "<INFLECT>$1</INFLECT>");
}

function decodeInflections(value) {
  return value.replace(INFLECT_TAG_RE, "^[$1](inflect: true)");
}

// ── Fullwidth-ASCII normalizer ────────────────────────────────────────────────
// CJK-locale LLMs sometimes return fullwidth ASCII variants (U+FF01–U+FF5E)
// inside printf format tokens — e.g. ％@ instead of %@, or ％lld instead of
// %lld.  Map the entire fullwidth ASCII block back to plain ASCII so placeholder
// validation works correctly.
//
// This is standard NFKC normalisation and is safe: legitimate CJK punctuation
// (。、「」…) lives in U+3000–U+303F and is entirely unaffected.

function normalizeFullwidthASCII(value) {
  return value.replace(/[\uFF01-\uFF5E]/g, (ch) =>
    String.fromCodePoint(ch.codePointAt(0) - 0xFF01 + 0x21)
  );
}

async function openAITranslateBatch(batch, options) {
  const apiKey = process.env.OPENAI_API_KEY;
  if (!apiKey) {
    throw new Error("OPENAI_API_KEY is required when --provider openai is used");
  }

  const systemPrompt = [
    "You are translating iOS app string catalog entries for PicStrip.",
    "Return only JSON matching the requested schema.",
    "Preserve printf placeholders (%lld, %@, %d, etc.) and ${applicationName} variables exactly.",
    "Preserve the product name PicStrip.",
    "Strings may contain <INFLECT>...</INFLECT> tags that mark a noun phrase for automatic grammatical inflection.",
    "Translate the text inside <INFLECT> tags as part of the surrounding sentence,",
    "but always keep the literal <INFLECT> and </INFLECT> wrappers in the correct position for the target language.",
    "Example: '<INFLECT>%lld photo</INFLECT> selected' → '<INFLECT>%lld Foto</INFLECT> ausgewählt' (de).",
    "IMPORTANT: if the source string contains NO <INFLECT> tags, your translation must also contain NO <INFLECT> tags.",
    "Keep translations concise enough for mobile UI.",
    "Use natural, privacy-respecting language for the target locale."
  ].join(" ");

  const jsonSchema = {
    type: "object",
    additionalProperties: false,
    properties: {
      translations: {
        type: "array",
        items: {
          type: "object",
          additionalProperties: false,
          properties: {
            id: { type: "string" },
            text: { type: "string" }
          },
          required: ["id", "text"]
        }
      }
    },
    required: ["translations"]
  };

  const userContent = JSON.stringify({
    items: batch.map((item) => ({
      id: item.id,
      targetLanguage: item.language,
      sourceLanguage: item.sourceLanguage,
      text: encodeInflections(item.source)
    }))
  });

  const payload = {
    model: options.model,
    messages: [
      { role: "system", content: systemPrompt },
      { role: "user",   content: userContent }
    ],
    response_format: {
      type: "json_schema",
      json_schema: {
        name: "picstrip_translations",
        strict: true,
        schema: jsonSchema
      }
    }
  };

  const response = await fetch("https://api.openai.com/v1/chat/completions", {
    method: "POST",
    headers: {
      "Authorization": `Bearer ${apiKey}`,
      "Content-Type": "application/json"
    },
    body: JSON.stringify(payload)
  });

  const bodyText = await response.text();
  if (!response.ok) {
    throw new Error(`OpenAI translation request failed (${response.status}): ${bodyText}`);
  }

  const body = JSON.parse(bodyText);
  const text = body.choices?.[0]?.message?.content;
  if (!text) {
    throw new Error(`Unexpected OpenAI response shape: ${JSON.stringify(body).slice(0, 300)}`);
  }
  const parsed = JSON.parse(text);
  return Object.fromEntries(parsed.translations.map((item) => [item.id, item.text]));
}

function validateTranslation(item, translated) {
  const sourceTokens = tokens(item.source);
  const translatedTokens = tokens(translated);
  const sourceSorted = [...sourceTokens].sort();
  const translatedSorted = [...translatedTokens].sort();

  if (JSON.stringify(sourceSorted) !== JSON.stringify(translatedSorted)) {
    throw new Error([
      `Placeholder mismatch for ${item.filePath} (${item.language})`,
      `key: ${item.key}`,
      `source tokens: ${sourceSorted.join(", ") || "(none)"}`,
      `translated tokens: ${translatedSorted.join(", ") || "(none)"}`,
      `translation: ${translated}`
    ].join("\n"));
  }

  const sourceInflections = countOccurrences(item.source, "](inflect: true)");
  const translatedInflections = countOccurrences(translated, "](inflect: true)");
  if (sourceInflections !== translatedInflections) {
    throw new Error(`Inflection markup mismatch for ${item.filePath} (${item.language}) key: ${item.key}`);
  }
}

function tokens(value) {
  const matches = [
    ...value.matchAll(/%\d+\$[@dDuUxXfFgGeEscC]/g),
    ...value.matchAll(/%lld/g),
    ...value.matchAll(/%[@dDuUxXfFgGeEscC]/g),
    ...value.matchAll(/\$\{[A-Za-z0-9_.-]+\}/g)
  ];
  return matches.map((match) => match[0]);
}

function countOccurrences(value, needle) {
  return value.split(needle).length - 1;
}

// ── Concurrency helper ────────────────────────────────────────────────────────
// Runs `fn` over every item in `items`, keeping at most `concurrency` calls
// in-flight at once.  Uses a shared-index worker-pool pattern that is safe in
// JavaScript's single-threaded event loop: `pos++` is always synchronous and
// completes before the next `await` can yield to another task.

async function withConcurrency(concurrency, items, fn) {
  let pos = 0;
  async function worker() {
    while (pos < items.length) {
      const item = items[pos++];
      await fn(item);
    }
  }
  await Promise.all(
    Array.from({ length: Math.min(concurrency, items.length) }, worker)
  );
}

async function main() {
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

  console.log(`Preparing ${work.length} translation${work.length === 1 ? "" : "s"} across ${options.files.length} catalog${options.files.length === 1 ? "" : "s"} (${options.concurrency} concurrent batch${options.concurrency === 1 ? "" : "es"}).`);
  if (options.dryRun) {
    for (const item of work.slice(0, 20)) {
      console.log(`[dry-run] ${item.filePath} ${item.language}: ${item.key}`);
    }
    if (work.length > 20) {
      console.log(`[dry-run] ...and ${work.length - 20} more.`);
    }
    return;
  }

  const allBatches = chunks(work, options.batchSize);
  await withConcurrency(options.concurrency, allBatches, async (batch) => {
    let translations = await translateBatch(options.provider, batch, options);

    // Some models silently omit strings they consider "untranslatable" (e.g. a
    // string that is mostly proper nouns or technical terms).  Retry missing
    // items as a smaller batch, then fall back to the source value if they are
    // still absent so the run never crashes on an incomplete model response.
    const missing = batch.filter((item) => !translations[item.id]);
    if (missing.length > 0) {
      console.warn(`Retrying ${missing.length} missing translation${missing.length === 1 ? "" : "s"}...`);
      const retried = await translateBatch(options.provider, missing, options);
      translations = { ...translations, ...retried };
    }

    for (const item of batch) {
      let translated = translations[item.id];
      if (!translated) {
        console.warn(`Translation unavailable for (${item.language}) "${item.key}" — using source.`);
        translated = item.source;
      }

      // Normalize fullwidth ASCII variants (e.g. ％ → %) that CJK-locale models
      // sometimes emit inside printf tokens, then restore Apple inflection markup.
      let decoded = decodeInflections(normalizeFullwidthASCII(translated));

      // If the source has no inflect markup but the model added some anyway
      // (e.g. for grammatical agreement in French/German), strip it back out.
      // The developer opts in to inflect markup explicitly in source strings.
      if (countOccurrences(item.source, "](inflect: true)") === 0) {
        decoded = decoded.replace(/\^\[([^\]]*)\]\(inflect: true\)/g, "$1");
      }
      validateTranslation(item, decoded);

      const catalog = catalogs.get(item.filePath);
      const entry = catalog.strings[item.key];
      setTargetValue(entry, item.language, decoded, options.state);
    }
    console.log(`Translated ${batch.length} string${batch.length === 1 ? "" : "s"}...`);
  });

  for (const [filePath, catalog] of catalogs.entries()) {
    writeCatalog(filePath, catalog);
    console.log(`Updated ${filePath}`);
  }
}

main().catch((error) => {
  console.error(error.message);
  process.exit(1);
});
