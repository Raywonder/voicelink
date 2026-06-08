#!/usr/bin/env node

const fs = require('fs');
const path = require('path');
const crypto = require('crypto');

const API_BASE = 'https://api.appstoreconnect.apple.com/v1';

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
  if (buffer.length < width) return Buffer.concat([Buffer.alloc(width - buffer.length), buffer]);
  throw new Error(`ECDSA component longer than expected (${buffer.length} > ${width})`);
}

function derToJose(signature, outputLength = 64) {
  const input = Buffer.from(signature);
  if (input[0] !== 0x30) throw new Error('Invalid DER signature: expected sequence');
  let offset = 2;
  if (input[1] & 0x80) offset = 2 + (input[1] & 0x7f);
  if (input[offset] !== 0x02) throw new Error('Invalid DER signature: expected integer for R');
  const rLength = input[offset + 1];
  const rStart = offset + 2;
  const r = input.slice(rStart, rStart + rLength);
  offset = rStart + rLength;
  if (input[offset] !== 0x02) throw new Error('Invalid DER signature: expected integer for S');
  const sLength = input[offset + 1];
  const sStart = offset + 2;
  const s = input.slice(sStart, sStart + sLength);
  return Buffer.concat([toFixedWidth(r, outputLength / 2), toFixedWidth(s, outputLength / 2)]);
}

function makeJwt({ keyId, issuerId, privateKeyPem }) {
  const header = { alg: 'ES256', kid: keyId, typ: 'JWT' };
  const now = Math.floor(Date.now() / 1000);
  const payload = {
    iss: issuerId,
    aud: 'appstoreconnect-v1',
    iat: now,
    exp: now + 20 * 60
  };
  const signingInput = `${base64url(JSON.stringify(header))}.${base64url(JSON.stringify(payload))}`;
  const derSignature = crypto.sign('sha256', Buffer.from(signingInput), crypto.createPrivateKey(privateKeyPem));
  return `${signingInput}.${base64url(derToJose(derSignature))}`;
}

function readFileRequired(filePath, label) {
  if (!fs.existsSync(filePath)) throw new Error(`${label} not found: ${filePath}`);
  return fs.readFileSync(filePath, 'utf8');
}

function extractPbxprojValue(contents, key) {
  const match = contents.match(new RegExp(`${key}\\s*=\\s*([^;]+);`));
  return match ? match[1].replace(/^"|"$/g, '').trim() : null;
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
  const json = text ? JSON.parse(text) : {};
  if (!response.ok) {
    const detail = json?.errors
      ? json.errors.map((item) => `${item.status || response.status} ${item.code || ''} ${item.title || ''} ${item.detail || ''}`.trim()).join(' | ')
      : JSON.stringify(json || text);
    throw new Error(`${method} ${url.pathname} failed: ${detail}`);
  }
  return json;
}

async function findAppId(token, bundleId) {
  const json = await apiRequest(token, '/apps', {
    query: {
      'filter[bundleId]': bundleId,
      limit: 1
    }
  });
  const appId = json?.data?.[0]?.id;
  if (!appId) throw new Error(`No App Store Connect app found for bundle ID ${bundleId}`);
  return appId;
}

async function listBuilds(token, appId, version) {
  const json = await apiRequest(token, '/builds', {
    query: {
      'filter[app]': appId,
      'filter[preReleaseVersion.version]': version,
      limit: 200,
      sort: '-uploadedDate'
    }
  });
  return json?.data || [];
}

async function expireBuild(token, buildId) {
  await apiRequest(token, `/builds/${buildId}`, {
    method: 'PATCH',
    body: {
      data: {
        type: 'builds',
        id: buildId,
        attributes: {
          expired: true
        }
      }
    }
  });
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  const projectRoot = path.resolve(__dirname, '..');
  const pbxprojPath = path.resolve(projectRoot, args['pbxproj'] || 'VoiceLinkiOS.xcodeproj/project.pbxproj');
  const pbxproj = readFileRequired(pbxprojPath, 'Xcode project');
  const bundleId = args['bundle-id'] || process.env.ASC_APP_BUNDLE_ID || extractPbxprojValue(pbxproj, 'PRODUCT_BUNDLE_IDENTIFIER');
  const version = args.version || process.env.ASC_MARKETING_VERSION || extractPbxprojValue(pbxproj, 'MARKETING_VERSION');
  const keepBuildNumber = String(args['keep-build-number'] || process.env.ASC_BUILD_NUMBER || extractPbxprojValue(pbxproj, 'CURRENT_PROJECT_VERSION') || '').trim();
  const keyId = process.env.ASC_KEY_ID;
  const issuerId = process.env.ASC_ISSUER_ID;
  const privateKeyPem = process.env.ASC_PRIVATE_KEY
    || (process.env.ASC_PRIVATE_KEY_PATH ? readFileRequired(process.env.ASC_PRIVATE_KEY_PATH, 'App Store Connect private key') : null);

  if (!bundleId || !version || !keepBuildNumber) {
    throw new Error(`Missing build metadata. bundleId=${bundleId || 'n/a'} version=${version || 'n/a'} keepBuildNumber=${keepBuildNumber || 'n/a'}`);
  }
  if (!keyId || !issuerId || !privateKeyPem) {
    throw new Error('Missing App Store Connect API credentials. Set ASC_KEY_ID, ASC_ISSUER_ID, and ASC_PRIVATE_KEY_PATH or ASC_PRIVATE_KEY.');
  }

  const token = makeJwt({ keyId, issuerId, privateKeyPem });
  const appId = await findAppId(token, bundleId);
  const builds = await listBuilds(token, appId, version);
  let expiredCount = 0;

  for (const build of builds) {
    const buildNumber = String(build?.attributes?.version || '').trim();
    const isExpired = Boolean(build?.attributes?.expired);
    if (!build?.id || !buildNumber || isExpired || buildNumber === keepBuildNumber) {
      continue;
    }
    console.log(`Expiring TestFlight build ${version} (${buildNumber}) [${build.id}]`);
    await expireBuild(token, build.id);
    expiredCount += 1;
  }

  console.log(`Expired ${expiredCount} old TestFlight build(s); kept build ${version} (${keepBuildNumber}).`);
}

main().catch((error) => {
  console.error(error.message || error);
  process.exit(1);
});
