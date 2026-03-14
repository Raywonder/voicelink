#!/usr/bin/env node

const fs = require('fs');
const path = require('path');
const crypto = require('crypto');

const API_BASE = 'https://api.appstoreconnect.apple.com/v1';
const DEFAULT_LOCALE = 'en-US';
const DEFAULT_WAIT_SECONDS = 20;
const DEFAULT_WAIT_ATTEMPTS = 30;

function parseArgs(argv) {
  const args = {};
  for (let i = 0; i < argv.length; i += 1) {
    const token = argv[i];
    if (!token.startsWith('--')) continue;
    const key = token.slice(2);
    const next = argv[i + 1];
    if (!next || next.startsWith('--')) {
      args[key] = true;
      continue;
    }
    args[key] = next;
    i += 1;
  }
  return args;
}

function base64url(input) {
  return Buffer.from(input)
    .toString('base64')
    .replace(/\+/g, '-')
    .replace(/\//g, '_')
    .replace(/=+$/g, '');
}

function toFixedWidth(buffer, width) {
  if (buffer.length === width) return buffer;
  if (buffer.length === width + 1 && buffer[0] === 0) return buffer.slice(1);
  if (buffer.length < width) {
    return Buffer.concat([Buffer.alloc(width - buffer.length), buffer]);
  }
  throw new Error(`ECDSA component longer than expected (${buffer.length} > ${width})`);
}

function derToJose(signature, outputLength = 64) {
  const input = Buffer.from(signature);
  if (input[0] !== 0x30) {
    throw new Error('Invalid DER signature: expected sequence');
  }
  let offset = 2;
  if (input[1] & 0x80) {
    offset = 2 + (input[1] & 0x7f);
  }
  if (input[offset] !== 0x02) {
    throw new Error('Invalid DER signature: expected integer for R');
  }
  const rLength = input[offset + 1];
  const rStart = offset + 2;
  const r = input.slice(rStart, rStart + rLength);
  offset = rStart + rLength;
  if (input[offset] !== 0x02) {
    throw new Error('Invalid DER signature: expected integer for S');
  }
  const sLength = input[offset + 1];
  const sStart = offset + 2;
  const s = input.slice(sStart, sStart + sLength);
  const rPadded = toFixedWidth(r, outputLength / 2);
  const sPadded = toFixedWidth(s, outputLength / 2);
  return Buffer.concat([rPadded, sPadded]);
}

function makeJwt({ keyId, issuerId, privateKeyPem }) {
  const header = {
    alg: 'ES256',
    kid: keyId,
    typ: 'JWT'
  };
  const now = Math.floor(Date.now() / 1000);
  const payload = {
    iss: issuerId,
    aud: 'appstoreconnect-v1',
    iat: now,
    exp: now + 60 * 20
  };
  const encodedHeader = base64url(JSON.stringify(header));
  const encodedPayload = base64url(JSON.stringify(payload));
  const signingInput = `${encodedHeader}.${encodedPayload}`;
  const key = crypto.createPrivateKey(privateKeyPem);
  const derSignature = crypto.sign('sha256', Buffer.from(signingInput), key);
  const joseSignature = derToJose(derSignature);
  return `${signingInput}.${base64url(joseSignature)}`;
}

function readFileRequired(filePath, label) {
  if (!fs.existsSync(filePath)) {
    throw new Error(`${label} not found: ${filePath}`);
  }
  return fs.readFileSync(filePath, 'utf8');
}

function extractPbxprojValue(contents, key) {
  const regex = new RegExp(`${key}\\s*=\\s*([^;]+);`);
  const match = contents.match(regex);
  return match ? match[1].replace(/^"|"$/g, '').trim() : null;
}

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

async function apiRequest(token, pathname, { method = 'GET', query = null, body = null } = {}) {
  const url = new URL(`${API_BASE}${pathname}`);
  if (query) {
    Object.entries(query).forEach(([key, value]) => {
      if (value !== undefined && value !== null && value !== '') {
        url.searchParams.set(key, String(value));
      }
    });
  }
  const response = await fetch(url, {
    method,
    headers: {
      Authorization: `Bearer ${token}`,
      Accept: 'application/json',
      ...(body ? { 'Content-Type': 'application/json' } : {})
    },
    body: body ? JSON.stringify(body) : undefined
  });

  const text = await response.text();
  let json = null;
  if (text) {
    try {
      json = JSON.parse(text);
    } catch {
      json = { raw: text };
    }
  }

  if (!response.ok) {
    const detail = json?.errors
      ? json.errors.map((item) => `${item.status || response.status} ${item.code || ''} ${item.title || ''} ${item.detail || ''}`.trim()).join(' | ')
      : JSON.stringify(json || text);
    throw new Error(`${method} ${url.pathname} failed: ${detail}`);
  }

  return json || {};
}

async function findAppId(token, bundleId) {
  const json = await apiRequest(token, '/apps', {
    query: {
      'filter[bundleId]': bundleId,
      limit: 1
    }
  });
  const app = json?.data?.[0];
  if (!app?.id) {
    throw new Error(`No App Store Connect app found for bundle ID ${bundleId}`);
  }
  return app.id;
}

async function findBuild(token, { appId, version, buildNumber, waitAttempts, waitSeconds }) {
  for (let attempt = 1; attempt <= waitAttempts; attempt += 1) {
    const json = await apiRequest(token, '/builds', {
      query: {
        'filter[app]': appId,
        'filter[preReleaseVersion.version]': version,
        'filter[version]': buildNumber,
        limit: 10
      }
    });
    const build = (json?.data || []).find((item) => item?.attributes?.version === String(buildNumber));
    if (build?.id) {
      return build;
    }
    if (attempt < waitAttempts) {
      console.log(`Build ${version} (${buildNumber}) not visible in App Store Connect yet. Waiting ${waitSeconds}s... [${attempt}/${waitAttempts}]`);
      await sleep(waitSeconds * 1000);
    }
  }
  throw new Error(`Build ${version} (${buildNumber}) not found in App Store Connect after waiting`);
}

async function upsertBetaLocalization(token, { buildId, locale, notes }) {
  const existing = await apiRequest(token, '/betaBuildLocalizations', {
    query: {
      'filter[build]': buildId,
      'filter[locale]': locale,
      limit: 1
    }
  });
  const localization = existing?.data?.[0];
  if (localization?.id) {
    const updated = await apiRequest(token, `/betaBuildLocalizations/${localization.id}`, {
      method: 'PATCH',
      body: {
        data: {
          type: 'betaBuildLocalizations',
          id: localization.id,
          attributes: {
            whatsNew: notes
          }
        }
      }
    });
    return { action: 'updated', id: updated?.data?.id || localization.id };
  }

  const created = await apiRequest(token, '/betaBuildLocalizations', {
    method: 'POST',
    body: {
      data: {
        type: 'betaBuildLocalizations',
        attributes: {
          locale,
          whatsNew: notes
        },
        relationships: {
          build: {
            data: {
              type: 'builds',
              id: buildId
            }
          }
        }
      }
    }
  });
  return { action: 'created', id: created?.data?.id };
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  const scriptDir = __dirname;
  const projectRoot = path.resolve(scriptDir, '..');
  const notesFile = path.resolve(projectRoot, args['notes-file'] || 'TestFlight/WhatToTest.en-US.txt');
  const pbxprojPath = path.resolve(projectRoot, args['pbxproj'] || 'VoiceLinkiOS.xcodeproj/project.pbxproj');
  const locale = args.locale || process.env.ASC_LOCALE || DEFAULT_LOCALE;
  const waitAttempts = Number(args['wait-attempts'] || process.env.ASC_WAIT_ATTEMPTS || DEFAULT_WAIT_ATTEMPTS);
  const waitSeconds = Number(args['wait-seconds'] || process.env.ASC_WAIT_SECONDS || DEFAULT_WAIT_SECONDS);

  const pbxproj = readFileRequired(pbxprojPath, 'Xcode project');
  const bundleId = args['bundle-id'] || process.env.ASC_APP_BUNDLE_ID || extractPbxprojValue(pbxproj, 'PRODUCT_BUNDLE_IDENTIFIER');
  const version = args.version || process.env.ASC_MARKETING_VERSION || extractPbxprojValue(pbxproj, 'MARKETING_VERSION');
  const buildNumber = args['build-number'] || process.env.ASC_BUILD_NUMBER || extractPbxprojValue(pbxproj, 'CURRENT_PROJECT_VERSION');
  const notes = readFileRequired(notesFile, 'What to Test notes').trim();

  const keyId = process.env.ASC_KEY_ID;
  const issuerId = process.env.ASC_ISSUER_ID;
  const privateKeyPem = process.env.ASC_PRIVATE_KEY
    || (process.env.ASC_PRIVATE_KEY_PATH ? readFileRequired(process.env.ASC_PRIVATE_KEY_PATH, 'App Store Connect private key') : null);

  if (!keyId || !issuerId || !privateKeyPem) {
    throw new Error('Missing App Store Connect API credentials. Set ASC_KEY_ID, ASC_ISSUER_ID, and ASC_PRIVATE_KEY_PATH or ASC_PRIVATE_KEY.');
  }
  if (!bundleId || !version || !buildNumber) {
    throw new Error(`Missing build metadata. bundleId=${bundleId || 'n/a'} version=${version || 'n/a'} buildNumber=${buildNumber || 'n/a'}`);
  }
  if (!notes) {
    throw new Error(`Notes file is empty: ${notesFile}`);
  }

  const token = makeJwt({ keyId, issuerId, privateKeyPem });
  console.log(`Syncing TestFlight notes for ${bundleId} version ${version} build ${buildNumber} locale ${locale}`);
  const appId = await findAppId(token, bundleId);
  const build = await findBuild(token, { appId, version, buildNumber, waitAttempts, waitSeconds });
  const result = await upsertBetaLocalization(token, { buildId: build.id, locale, notes });
  console.log(`TestFlight notes ${result.action} for build resource ${build.id} (${locale})`);
}

main().catch((error) => {
  console.error(error.message || error);
  process.exit(1);
});
