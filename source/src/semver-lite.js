/**
 * Lightweight semver comparison for VoiceLink Local
 * Handles basic version comparison without full semver dependency
 */

function parseVersion(version) {
    const cleaned = version.replace(/^v/, ''); // Remove 'v' prefix if present
    const parts = cleaned.split(/[-+]/)[0]; // Remove pre-release/build suffixes
    const [major, minor, patch] = parts.split('.').map(x => parseInt(x) || 0);

    return { major, minor, patch, original: version };
}

function compareVersions(a, b) {
    const versionA = parseVersion(a);
    const versionB = parseVersion(b);

    if (versionA.major !== versionB.major) {
        return versionA.major - versionB.major;
    }

    if (versionA.minor !== versionB.minor) {
        return versionA.minor - versionB.minor;
    }

    return versionA.patch - versionB.patch;
}

function gt(a, b) {
    return compareVersions(a, b) > 0;
}

function gte(a, b) {
    return compareVersions(a, b) >= 0;
}

function lt(a, b) {
    return compareVersions(a, b) < 0;
}

function lte(a, b) {
    return compareVersions(a, b) <= 0;
}

function eq(a, b) {
    return compareVersions(a, b) === 0;
}

module.exports = {
    gt,
    gte,
    lt,
    lte,
    eq,
    compare: compareVersions,
    parse: parseVersion
};