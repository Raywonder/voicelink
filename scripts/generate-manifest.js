#!/usr/bin/env node
/**
 * Generate file manifest for VoiceLink incremental updates
 *
 * Run this after each build to create the manifest that clients use
 * to determine which files need to be updated.
 *
 * Usage: node scripts/generate-manifest.js
 */

const crypto = require('crypto');
const fs = require('fs');
const path = require('path');

const ROOT_DIR = path.join(__dirname, '..');
const OUTPUT_DIR = path.join(ROOT_DIR, 'dist', 'updates');
const MANIFEST_FILE = 'file-manifest.json';

// Directories and files to include in manifest
const INCLUDE_PATHS = [
    'client/js',
    'client/css',
    'client/index.html',
    'server/routes',
    'server/utils'
];

// File extensions to include
const INCLUDE_EXTENSIONS = ['.js', '.css', '.html', '.json'];

// Files/directories to exclude
const EXCLUDE_PATTERNS = [
    'node_modules',
    '.git',
    '.DS_Store',
    'package-lock.json'
];

function hashFile(filePath) {
    const content = fs.readFileSync(filePath);
    return crypto.createHash('sha256').update(content).digest('hex');
}

function shouldInclude(filePath, stats) {
    const fileName = path.basename(filePath);
    const ext = path.extname(fileName).toLowerCase();

    for (const pattern of EXCLUDE_PATTERNS) {
        if (filePath.includes(pattern)) {
            return false;
        }
    }

    if (stats.isFile()) {
        return INCLUDE_EXTENSIONS.includes(ext);
    }

    return true;
}

function scanDirectory(dir, basePath = '', files = {}) {
    if (!fs.existsSync(dir)) {
        console.warn(`Directory not found: ${dir}`);
        return files;
    }

    const stats = fs.statSync(dir);

    if (stats.isFile()) {
        if (shouldInclude(dir, stats)) {
            const hash = hashFile(dir);
            files[basePath] = {
                hash: hash,
                size: stats.size,
                modified: stats.mtime.toISOString()
            };
        }
        return files;
    }

    const items = fs.readdirSync(dir, { withFileTypes: true });

    for (const item of items) {
        const fullPath = path.join(dir, item.name);
        const relativePath = basePath ? path.join(basePath, item.name) : item.name;

        if (!shouldInclude(fullPath, item)) {
            continue;
        }

        if (item.isDirectory()) {
            scanDirectory(fullPath, relativePath, files);
        } else if (item.isFile()) {
            const hash = hashFile(fullPath);
            const stats = fs.statSync(fullPath);

            files[relativePath] = {
                hash: hash,
                size: stats.size,
                modified: stats.mtime.toISOString()
            };
        }
    }

    return files;
}

function copyFilesForUpdate(files, sourceRoot, outputRoot) {
    const filesDir = path.join(outputRoot, 'files');

    for (const relativePath of Object.keys(files)) {
        const sourcePath = path.join(sourceRoot, relativePath);
        const destPath = path.join(filesDir, relativePath);
        const destDir = path.dirname(destPath);

        if (!fs.existsSync(destDir)) {
            fs.mkdirSync(destDir, { recursive: true });
        }

        fs.copyFileSync(sourcePath, destPath);
    }

    console.log(`Copied ${Object.keys(files).length} files to ${filesDir}`);
}

function main() {
    console.log('Generating VoiceLink incremental update manifest...\n');

    // Read package.json for version
    const packageJson = JSON.parse(fs.readFileSync(path.join(ROOT_DIR, 'package.json'), 'utf8'));
    const version = packageJson.version;

    console.log(`Version: ${version}`);
    console.log(`Root directory: ${ROOT_DIR}`);
    console.log(`Output directory: ${OUTPUT_DIR}\n`);

    // Create output directory
    if (!fs.existsSync(OUTPUT_DIR)) {
        fs.mkdirSync(OUTPUT_DIR, { recursive: true });
    }

    // Scan all included paths
    const allFiles = {};

    for (const includePath of INCLUDE_PATHS) {
        const fullPath = path.join(ROOT_DIR, includePath);
        console.log(`Scanning: ${includePath}`);
        scanDirectory(fullPath, includePath, allFiles);
    }

    // Create manifest
    const manifest = {
        version: version,
        generated: new Date().toISOString(),
        filesCount: Object.keys(allFiles).length,
        totalSize: Object.values(allFiles).reduce((sum, f) => sum + f.size, 0),
        files: allFiles
    };

    // Write manifest
    const manifestPath = path.join(OUTPUT_DIR, MANIFEST_FILE);
    fs.writeFileSync(manifestPath, JSON.stringify(manifest, null, 2));
    console.log(`\nManifest written to: ${manifestPath}`);

    // Copy all files to update directory
    console.log('\nCopying files for incremental updates...');
    copyFilesForUpdate(allFiles, ROOT_DIR, OUTPUT_DIR);

    // Summary
    console.log('\n=== Manifest Summary ===');
    console.log(`Version: ${manifest.version}`);
    console.log(`Files: ${manifest.filesCount}`);
    console.log(`Total size: ${(manifest.totalSize / 1024).toFixed(2)} KB`);
    console.log(`Generated: ${manifest.generated}`);

    console.log('\nDone! Upload the contents of dist/updates/ to your update server.');
}

main();
