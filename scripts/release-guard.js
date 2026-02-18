#!/usr/bin/env node
/**
 * Release guard for VoiceLink desktop updates.
 *
 * Prevents shipping broken updater metadata by validating:
 * - ZIP exists and looks valid
 * - Manifest points to canonical ZIP path
 * - Manifest checksum/size match local ZIP
 * - Public web links do not point to stale mac-native or mis-cased filenames
 *
 * Usage:
 *   node scripts/release-guard.js
 *   node scripts/release-guard.js --manifest-url https://voicelink.devinecreations.net/downloads/latest-mac.yml
 *   node scripts/release-guard.js --manifest-file /path/to/latest-mac.yml --zip /path/to/VoiceLink-macOS.zip
 */

const crypto = require('crypto');
const fs = require('fs');
const http = require('http');
const https = require('https');
const path = require('path');
const { URL } = require('url');

const ROOT = path.resolve(__dirname, '..');
const DEFAULT_ZIP = path.join(ROOT, 'swift-native', 'VoiceLinkNative', 'VoiceLink-macOS.zip');
const DEFAULT_MANIFEST_URL = 'https://voicelink.devinecreations.net/downloads/latest-mac.yml';
const CANONICAL_ZIP_NAME = 'VoiceLink-macOS.zip';
const CANONICAL_ZIP_PATH = '/downloads/voicelink/VoiceLink-macOS.zip';

function parseArgs(argv) {
    const options = {};
    for (let i = 0; i < argv.length; i += 1) {
        const arg = argv[i];
        if (!arg.startsWith('--')) continue;
        const key = arg.slice(2);
        const next = argv[i + 1];
        if (!next || next.startsWith('--')) {
            options[key] = true;
            continue;
        }
        options[key] = next;
        i += 1;
    }
    return options;
}

function readURL(urlString) {
    return new Promise((resolve, reject) => {
        const parsed = new URL(urlString);
        const client = parsed.protocol === 'http:' ? http : https;
        const req = client.get(parsed, { timeout: 15000 }, (res) => {
            if (res.statusCode !== 200) {
                reject(new Error(`HTTP ${res.statusCode} for ${urlString}`));
                return;
            }
            let body = '';
            res.setEncoding('utf8');
            res.on('data', (chunk) => {
                body += chunk;
            });
            res.on('end', () => resolve(body));
        });
        req.on('error', reject);
        req.on('timeout', () => {
            req.destroy(new Error(`Timeout while fetching ${urlString}`));
        });
    });
}

function parseYAMLScalar(raw) {
    const trimmed = String(raw || '').trim();
    if (!trimmed) return '';
    if (
        (trimmed.startsWith('"') && trimmed.endsWith('"')) ||
        (trimmed.startsWith("'") && trimmed.endsWith("'"))
    ) {
        return trimmed.slice(1, -1).trim();
    }
    return trimmed;
}

function parseManifestYAML(yaml) {
    const out = {
        version: '',
        build: '',
        path: '',
        sha512: '',
        size: '',
        files: []
    };

    const lines = String(yaml || '').split('\n');
    let inFilesSection = false;
    let currentFile = null;

    for (const line of lines) {
        const raw = line.replace(/\r$/, '');
        const trimmed = raw.trim();
        if (!trimmed || trimmed.startsWith('#')) continue;

        if (!raw.startsWith(' ') && trimmed === 'files:') {
            inFilesSection = true;
            currentFile = null;
            continue;
        }

        if (!raw.startsWith(' ') && trimmed.endsWith(':') && trimmed !== 'files:') {
            inFilesSection = false;
            currentFile = null;
        }

        if (!inFilesSection) {
            const idx = trimmed.indexOf(':');
            if (idx > 0) {
                const key = trimmed.slice(0, idx);
                const value = parseYAMLScalar(trimmed.slice(idx + 1));
                if (Object.prototype.hasOwnProperty.call(out, key)) {
                    out[key] = value;
                }
            }
            continue;
        }

        if (trimmed.startsWith('- ')) {
            currentFile = {};
            out.files.push(currentFile);
            const remainder = trimmed.slice(2);
            const idx = remainder.indexOf(':');
            if (idx > 0) {
                const key = remainder.slice(0, idx).trim();
                const value = parseYAMLScalar(remainder.slice(idx + 1));
                currentFile[key] = value;
            }
            continue;
        }

        if (!currentFile) continue;
        const idx = trimmed.indexOf(':');
        if (idx > 0) {
            const key = trimmed.slice(0, idx).trim();
            const value = parseYAMLScalar(trimmed.slice(idx + 1));
            currentFile[key] = value;
        }
    }

    return out;
}

function resolveDownloadURL(rawPath, manifestSource) {
    const cleaned = parseYAMLScalar(rawPath);
    if (!cleaned) return null;

    if (cleaned.startsWith('voicelink://')) {
        try {
            const parsed = new URL(cleaned);
            const encoded = parsed.searchParams.get('url');
            if (!encoded) return null;
            return new URL(decodeURIComponent(encoded));
        } catch (_) {
            return null;
        }
    }

    if (cleaned.startsWith('http://') || cleaned.startsWith('https://')) {
        try {
            return new URL(cleaned);
        } catch (_) {
            return null;
        }
    }

    if (!manifestSource) return null;
    try {
        const base = new URL('.', manifestSource);
        return new URL(cleaned, base);
    } catch (_) {
        return null;
    }
}

function computeHashAndSize(zipPath) {
    const buf = fs.readFileSync(zipPath);
    const base64 = crypto.createHash('sha512').update(buf).digest('base64');
    const hex = crypto.createHash('sha512').update(buf).digest('hex');
    return { base64, hex, size: buf.length };
}

function normalizeManifestSha(raw) {
    const value = String(raw || '').trim().replace(/\s+/g, '');
    if (!value) return '';
    if (value.startsWith('sha512-')) return value.slice('sha512-'.length);
    return value;
}

function shaMatches(manifestSha, computedBase64, computedHex) {
    const normalized = normalizeManifestSha(manifestSha);
    if (!normalized) return false;
    return normalized === computedBase64 || normalized.toLowerCase() === computedHex.toLowerCase();
}

function checkZipHeader(zipPath) {
    const fd = fs.openSync(zipPath, 'r');
    const header = Buffer.alloc(4);
    fs.readSync(fd, header, 0, 4, 0);
    fs.closeSync(fd);
    return (
        header.equals(Buffer.from([0x50, 0x4b, 0x03, 0x04])) ||
        header.equals(Buffer.from([0x50, 0x4b, 0x05, 0x06]))
    );
}

function checkLinkFile(filePath) {
    const issues = [];
    if (!fs.existsSync(filePath)) return issues;
    const content = fs.readFileSync(filePath, 'utf8');

    const badPatterns = [
        '/downloads/mac-native/VoiceLink-1.0.0-macos.zip',
        '/downloads/mac-native/VoiceLink-macOS.zip',
        '/downloads/VoiceLink-macOS.zip',
        'VoiceLinkMacOS.zip',
        '/downloads/voicelink/VoiceLinkMacOS.zip'
    ];

    for (const pattern of badPatterns) {
        if (content.includes(pattern)) {
            issues.push(`contains stale pattern: ${pattern}`);
        }
    }

    if (!content.includes(CANONICAL_ZIP_PATH)) {
        issues.push(`missing canonical ${CANONICAL_ZIP_PATH} link`);
    }

    return issues;
}

async function main() {
    const args = parseArgs(process.argv.slice(2));
    const zipPath = path.resolve(String(args.zip || DEFAULT_ZIP));
    const skipManifest = args['skip-manifest'] === true;
    const manifestFile = args['manifest-file'] ? path.resolve(String(args['manifest-file'])) : null;
    const manifestURL = args['manifest-url'] ? String(args['manifest-url']) : (!manifestFile ? DEFAULT_MANIFEST_URL : null);

    const failures = [];
    const notes = [];

    if (!fs.existsSync(zipPath)) {
        failures.push(`ZIP not found: ${zipPath}`);
    } else {
        const stat = fs.statSync(zipPath);
        if (stat.size < 10 * 1024 * 1024) {
            failures.push(`ZIP too small (${stat.size} bytes): ${zipPath}`);
        }
        if (!checkZipHeader(zipPath)) {
            failures.push(`ZIP header invalid (not a PK zip): ${zipPath}`);
        } else {
            notes.push(`ZIP header OK: ${zipPath}`);
        }
    }

    let manifestText = '';
    let manifestSource = '';

    if (!skipManifest) {
        try {
            if (manifestFile) {
                manifestText = fs.readFileSync(manifestFile, 'utf8');
                manifestSource = `file://${manifestFile}`;
                notes.push(`Loaded manifest file: ${manifestFile}`);
            } else if (manifestURL) {
                manifestText = await readURL(manifestURL);
                manifestSource = manifestURL;
                notes.push(`Loaded manifest URL: ${manifestURL}`);
            } else {
                failures.push('No manifest source provided');
            }
        } catch (err) {
            failures.push(`Failed to read manifest: ${err.message}`);
        }
    } else {
        notes.push('Manifest checks skipped (--skip-manifest)');
    }

    if (manifestText && fs.existsSync(zipPath)) {
        const manifest = parseManifestYAML(manifestText);
        const fileEntry = manifest.files && manifest.files.length ? manifest.files[0] : {};

        const downloadPath = manifest.path || fileEntry.url || '';
        const resolved = resolveDownloadURL(downloadPath, manifestSource.startsWith('http') ? manifestSource : DEFAULT_MANIFEST_URL);
        const manifestSha = fileEntry.sha512 || manifest.sha512 || '';
        const manifestSize = Number(fileEntry.size || manifest.size || 0);

        if (!downloadPath) {
            failures.push('Manifest missing download path (path or files[0].url)');
        }
        if (!resolved) {
            failures.push(`Could not resolve download URL from manifest path: ${downloadPath || '<empty>'}`);
        } else {
            const scheme = resolved.protocol.replace(':', '');
            if (scheme !== 'https' && scheme !== 'http') {
                failures.push(`Download URL has unsupported scheme: ${resolved.toString()}`);
            }
            if (path.basename(resolved.pathname) !== CANONICAL_ZIP_NAME) {
                failures.push(
                    `Download URL must end with ${CANONICAL_ZIP_NAME}, got: ${resolved.pathname}`
                );
            } else if (resolved.pathname !== CANONICAL_ZIP_PATH) {
                failures.push(`Download URL must be ${CANONICAL_ZIP_PATH}, got: ${resolved.pathname}`);
            } else {
                notes.push(`Manifest download URL OK: ${resolved.toString()}`);
            }
        }

        if (!manifestSha) {
            failures.push('Manifest missing sha512');
        } else {
            const computed = computeHashAndSize(zipPath);
            if (!shaMatches(manifestSha, computed.base64, computed.hex)) {
                failures.push('Manifest sha512 does not match local ZIP');
            } else {
                notes.push('Manifest sha512 matches ZIP');
            }

            if (manifestSize && manifestSize !== computed.size) {
                failures.push(`Manifest size (${manifestSize}) does not match ZIP size (${computed.size})`);
            } else if (manifestSize) {
                notes.push(`Manifest size matches ZIP (${computed.size} bytes)`);
            } else {
                notes.push('Manifest size not provided; checksum match used as source of truth');
            }
        }
    }

    const linkTargets = [
        path.join(ROOT, 'downloads.html'),
        path.join(ROOT, 'client', 'index.html')
    ];
    for (const target of linkTargets) {
        const issues = checkLinkFile(target);
        if (issues.length) {
            for (const issue of issues) {
                failures.push(`${target}: ${issue}`);
            }
        } else if (fs.existsSync(target)) {
            notes.push(`Link checks OK: ${target}`);
        }
    }

    console.log('VoiceLink release guard');
    console.log(`- ZIP: ${zipPath}`);
    if (skipManifest) console.log('- Manifest checks: skipped');
    if (!skipManifest && manifestFile) console.log(`- Manifest file: ${manifestFile}`);
    if (!skipManifest && !manifestFile && manifestURL) console.log(`- Manifest URL: ${manifestURL}`);
    console.log('');

    for (const note of notes) {
        console.log(`[OK] ${note}`);
    }

    if (failures.length) {
        console.log('');
        for (const failure of failures) {
            console.error(`[FAIL] ${failure}`);
        }
        console.error(`\nRelease guard failed with ${failures.length} issue(s).`);
        process.exit(1);
    }

    console.log('\nRelease guard passed.');
}

main().catch((err) => {
    console.error(`[FAIL] ${err.message}`);
    process.exit(1);
});
