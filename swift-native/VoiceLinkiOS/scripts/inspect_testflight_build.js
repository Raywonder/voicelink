#!/usr/bin/env node

const fs = require('fs');
const crypto = require('crypto');

const API_BASE = 'https://api.appstoreconnect.apple.com/v1';

function base64url(input) {
  return Buffer.from(input).toString('base64').replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/g, '');
}

function toFixedWidth(buffer, width) {
  if (buffer.length === width) return buffer;
  if (buffer.length === width + 1 && buffer[0] === 0) return buffer.slice(1);
  if (buffer.length < width) return Buffer.concat([Buffer.alloc(width - buffer.length), buffer]);
  throw new Error('ECDSA component is too long');
}

function derToJose(signature) {
  const input = Buffer.from(signature);
  let offset = 2;
  if (input[1] & 0x80) offset = 2 + (input[1] & 0x7f);
  if (input[offset] !== 0x02) throw new Error('Invalid DER signature');
  const rLength = input[offset + 1];
  const rStart = offset + 2;
  const r = input.slice(rStart, rStart + rLength);
  offset = rStart + rLength;
  if (input[offset] !== 0x02) throw new Error('Invalid DER signature');
  const sLength = input[offset + 1];
  const sStart = offset + 2;
  const s = input.slice(sStart, sStart + sLength);
  return Buffer.concat([toFixedWidth(r, 32), toFixedWidth(s, 32)]);
}

function makeJwt({ keyId, issuerId, privateKeyPem }) {
  const header = { alg: 'ES256', kid: keyId, typ: 'JWT' };
  const now = Math.floor(Date.now() / 1000);
  const payload = { iss: issuerId, aud: 'appstoreconnect-v1', iat: now, exp: now + 60 * 20 };
  const signingInput = `${base64url(JSON.stringify(header))}.${base64url(JSON.stringify(payload))}`;
  const derSignature = crypto.sign('sha256', Buffer.from(signingInput), crypto.createPrivateKey(privateKeyPem));
  return `${signingInput}.${base64url(derToJose(derSignature))}`;
}

async function apiRequest(token, pathname, query = {}) {
  const url = new URL(`${API_BASE}${pathname}`);
  Object.entries(query).forEach(([key, value]) => {
    if (value !== undefined && value !== null && value !== '') url.searchParams.set(key, String(value));
  });
  const response = await fetch(url, {
    headers: { Authorization: `Bearer ${token}`, Accept: 'application/json' }
  });
  const text = await response.text();
  const json = text ? JSON.parse(text) : {};
  if (!response.ok) {
    throw new Error(`${response.status} ${JSON.stringify(json.errors || json)}`);
  }
  return json;
}

async function main() {
  const keyId = process.env.ASC_KEY_ID;
  const issuerId = process.env.ASC_ISSUER_ID;
  const privateKeyPem = process.env.ASC_PRIVATE_KEY
    || (process.env.ASC_PRIVATE_KEY_PATH ? fs.readFileSync(process.env.ASC_PRIVATE_KEY_PATH, 'utf8') : '');
  const bundleId = process.env.ASC_APP_BUNDLE_ID || 'com.devinecreations.voicelink';
  const version = process.env.ASC_MARKETING_VERSION || '1.0.0';
  const buildNumber = process.env.ASC_BUILD_NUMBER || '86';
  if (!keyId || !issuerId || !privateKeyPem) throw new Error('Missing ASC credentials');
  const token = makeJwt({ keyId, issuerId, privateKeyPem });
  const appJson = await apiRequest(token, '/apps', { 'filter[bundleId]': bundleId, limit: 1 });
  const appId = appJson.data?.[0]?.id;
  if (!appId) throw new Error(`App not found for ${bundleId}`);
  const buildsJson = await apiRequest(token, '/builds', {
    'filter[app]': appId,
    'filter[preReleaseVersion.version]': version,
    'filter[version]': buildNumber,
    include: 'betaAppReviewSubmission,betaGroups,preReleaseVersion',
    limit: 10
  });
  const build = (buildsJson.data || []).find((item) => item.attributes?.version === String(buildNumber));
  if (!build) throw new Error(`Build ${version} (${buildNumber}) not found`);
  const included = buildsJson.included || [];
  const review = included.find((item) => item.type === 'betaAppReviewSubmissions') || null;
  const groups = included.filter((item) => item.type === 'betaGroups').map((item) => item.attributes?.name || item.id);
  console.log(JSON.stringify({
    id: build.id,
    version,
    buildNumber,
    attributes: build.attributes,
    betaGroups: groups,
    betaAppReviewSubmission: review ? { id: review.id, attributes: review.attributes } : null
  }, null, 2));
}

main().catch((error) => {
  console.error(error.message || error);
  process.exit(1);
});
