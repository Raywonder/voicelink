/**
 * VoiceLink Documentation Generator
 * Converts Markdown to properly formatted HTML docs
 */

const fs = require('fs');
const path = require('path');

class DocsGenerator {
    constructor(docsDir) {
        this.docsDir = docsDir;
        this.templateDir = path.join(docsDir, 'scripts');
    }

    /**
     * HTML template with proper formatting
     */
    getTemplate(title, content, breadcrumb = '') {
        return `<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>${title} - VoiceLink Documentation</title>
    <link rel="stylesheet" href="../styles/docs.css">
    <style>
        :root {
            --primary: #667eea;
            --primary-dark: #5a6fd6;
            --secondary: #764ba2;
            --bg: #f8f9fa;
            --card-bg: #ffffff;
            --text: #333333;
            --text-muted: #666666;
            --border: #e0e0e0;
            --code-bg: #1e1e1e;
            --code-text: #d4d4d4;
            --success: #28a745;
            --warning: #ffc107;
            --danger: #dc3545;
        }
        * { margin: 0; padding: 0; box-sizing: border-box; }
        body {
            font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
            line-height: 1.6;
            color: var(--text);
            background: var(--bg);
        }
        .docs-header {
            background: linear-gradient(135deg, var(--primary), var(--secondary));
            color: white;
            padding: 2rem;
            text-align: center;
        }
        .docs-header h1 { font-size: 2rem; margin-bottom: 0.5rem; }
        .docs-header .breadcrumb {
            font-size: 0.9rem;
            opacity: 0.9;
        }
        .docs-header .breadcrumb a { color: white; text-decoration: none; }
        .docs-header .breadcrumb a:hover { text-decoration: underline; }
        .container {
            max-width: 900px;
            margin: 0 auto;
            padding: 2rem;
        }
        .card {
            background: var(--card-bg);
            border-radius: 12px;
            box-shadow: 0 4px 20px rgba(0,0,0,0.1);
            padding: 2rem;
            margin-bottom: 2rem;
        }
        h2 {
            color: var(--primary);
            margin: 2rem 0 1rem;
            padding-bottom: 0.5rem;
            border-bottom: 2px solid var(--border);
        }
        h3 {
            color: var(--text);
            margin: 1.5rem 0 0.75rem;
        }
        h4 { margin: 1rem 0 0.5rem; }
        p { margin-bottom: 1rem; }
        ul, ol {
            margin: 1rem 0;
            padding-left: 2rem;
        }
        li { margin-bottom: 0.5rem; }
        code {
            font-family: 'SF Mono', Monaco, 'Courier New', monospace;
            background: var(--code-bg);
            color: var(--code-text);
            padding: 0.2rem 0.5rem;
            border-radius: 4px;
            font-size: 0.9em;
        }
        pre {
            background: var(--code-bg);
            color: var(--code-text);
            padding: 1rem;
            border-radius: 8px;
            overflow-x: auto;
            margin: 1rem 0;
        }
        pre code {
            background: none;
            padding: 0;
        }
        .highlight-bash { color: #9cdcfe; }
        .highlight-comment { color: #6a9955; }
        .highlight-string { color: #ce9178; }
        .highlight-keyword { color: #569cd6; }
        a {
            color: var(--primary);
            text-decoration: none;
        }
        a:hover { text-decoration: underline; }
        blockquote {
            border-left: 4px solid var(--primary);
            padding-left: 1rem;
            margin: 1rem 0;
            color: var(--text-muted);
            font-style: italic;
        }
        .alert {
            padding: 1rem;
            border-radius: 8px;
            margin: 1rem 0;
        }
        .alert-info {
            background: #e3f2fd;
            border-left: 4px solid #2196f3;
        }
        .alert-warning {
            background: #fff3cd;
            border-left: 4px solid var(--warning);
        }
        .alert-danger {
            background: #f8d7da;
            border-left: 4px solid var(--danger);
        }
        .alert-success {
            background: #d4edda;
            border-left: 4px solid var(--success);
        }
        table {
            width: 100%;
            border-collapse: collapse;
            margin: 1rem 0;
        }
        th, td {
            padding: 0.75rem;
            text-align: left;
            border-bottom: 1px solid var(--border);
        }
        th {
            background: var(--bg);
            font-weight: 600;
        }
        .nav-links {
            display: flex;
            justify-content: space-between;
            margin-top: 2rem;
            padding-top: 1rem;
            border-top: 1px solid var(--border);
        }
        .nav-links a {
            display: flex;
            align-items: center;
            gap: 0.5rem;
        }
        .footer {
            text-align: center;
            padding: 2rem;
            color: var(--text-muted);
            font-size: 0.9rem;
        }
        @media (max-width: 768px) {
            .container { padding: 1rem; }
            .card { padding: 1rem; }
            pre { font-size: 0.85rem; }
        }
    </style>
</head>
<body>
    <div class="docs-header">
        <h1>${title}</h1>
        ${breadcrumb ? `<div class="breadcrumb">${breadcrumb}</div>` : ''}
    </div>
    <div class="container">
        <div class="card">
            ${content}
        </div>
    </div>
    <div class="footer">
        <p>VoiceLink Documentation &copy; ${new Date().getFullYear()} Devine Creations</p>
        <p><a href="../index.html">Back to Documentation Home</a></p>
    </div>
</body>
</html>`;
    }

    /**
     * Convert Markdown to HTML with proper formatting
     */
    markdownToHtml(md) {
        let html = md;

        // Convert code blocks first (preserve content)
        html = html.replace(/```(\w+)?\n([\s\S]*?)```/g, (match, lang, code) => {
            const escaped = this.escapeHtml(code.trim());
            return `<pre><code class="language-${lang || 'text'}">${escaped}</code></pre>`;
        });

        // Inline code
        html = html.replace(/`([^`]+)`/g, '<code>$1</code>');

        // Headers
        html = html.replace(/^#### (.+)$/gm, '<h4>$1</h4>');
        html = html.replace(/^### (.+)$/gm, '<h3>$1</h3>');
        html = html.replace(/^## (.+)$/gm, '<h2>$1</h2>');
        html = html.replace(/^# (.+)$/gm, '<h1>$1</h1>');

        // Alert boxes (special syntax)
        html = html.replace(/>\s*\*\*(Note|Info|Warning|Danger|Success)\*\*:\s*(.+)/gi, (match, type, text) => {
            const alertType = type.toLowerCase();
            const alertClass = alertType === 'note' ? 'info' : alertType;
            return `<div class="alert alert-${alertClass}"><strong>${type}:</strong> ${text}</div>`;
        });

        // Blockquotes
        html = html.replace(/^>\s*(.+)$/gm, '<blockquote>$1</blockquote>');

        // Lists
        html = html.replace(/^(\d+)\.\s+(.+)$/gm, '<li>$2</li>');
        html = html.replace(/^[-*]\s+(.+)$/gm, '<li>$1</li>');

        // Wrap consecutive <li> elements in <ul> or <ol>
        html = html.replace(/(<li>.*<\/li>\n?)+/g, (match) => {
            if (match.includes('1.')) {
                return `<ol>\n${match}</ol>\n`;
            }
            return `<ul>\n${match}</ul>\n`;
        });

        // Bold and Italic
        html = html.replace(/\*\*([^*]+)\*\*/g, '<strong>$1</strong>');
        html = html.replace(/\*([^*]+)\*/g, '<em>$1</em>');

        // Links
        html = html.replace(/\[([^\]]+)\]\(([^)]+)\)/g, '<a href="$2">$1</a>');

        // Horizontal rules
        html = html.replace(/^---$/gm, '<hr>');

        // Paragraphs (lines that aren't already wrapped)
        const lines = html.split('\n');
        const processedLines = [];
        let inList = false;
        let inPre = false;

        for (let line of lines) {
            if (line.includes('<pre>')) inPre = true;
            if (line.includes('</pre>')) inPre = false;
            if (line.includes('<ul>') || line.includes('<ol>')) inList = true;
            if (line.includes('</ul>') || line.includes('</ol>')) inList = false;

            if (!inPre && !inList && line.trim() &&
                !line.startsWith('<h') && !line.startsWith('<ul') && !line.startsWith('<ol') &&
                !line.startsWith('<li') && !line.startsWith('<blockquote') &&
                !line.startsWith('<div') && !line.startsWith('<pre') && !line.startsWith('<hr')) {
                line = `<p>${line}</p>`;
            }
            processedLines.push(line);
        }

        return processedLines.join('\n');
    }

    /**
     * Escape HTML special characters
     */
    escapeHtml(str) {
        return str
            .replace(/&/g, '&amp;')
            .replace(/</g, '&lt;')
            .replace(/>/g, '&gt;')
            .replace(/"/g, '&quot;')
            .replace(/'/g, '&#039;');
    }

    /**
     * Generate HTML from a markdown file
     */
    generateFromMarkdown(mdFile, outputFile) {
        const content = fs.readFileSync(mdFile, 'utf8');

        // Extract title from first H1
        const titleMatch = content.match(/^#\s+(.+)$/m);
        const title = titleMatch ? titleMatch[1] : path.basename(mdFile, '.md');

        // Convert to HTML
        const htmlContent = this.markdownToHtml(content);

        // Generate breadcrumb
        const relativePath = path.relative(this.docsDir, mdFile);
        const parts = relativePath.split(path.sep);
        const breadcrumb = `<a href="../index.html">Docs</a> / ${parts.slice(0, -1).join(' / ')} / ${title}`;

        // Generate full HTML
        const html = this.getTemplate(title, htmlContent, breadcrumb);

        // Ensure output directory exists
        const outputDir = path.dirname(outputFile);
        if (!fs.existsSync(outputDir)) {
            fs.mkdirSync(outputDir, { recursive: true });
        }

        // Write file
        fs.writeFileSync(outputFile, html);
        console.log(`Generated: ${outputFile}`);
    }

    /**
     * Generate all documentation
     */
    generateAll() {
        console.log('Generating VoiceLink documentation...\n');

        // Find all markdown files
        const mdFiles = this.findMarkdownFiles(this.docsDir);

        for (const mdFile of mdFiles) {
            // Skip node_modules
            if (mdFile.includes('node_modules')) continue;

            const relativePath = path.relative(this.docsDir, mdFile);
            const htmlPath = relativePath.replace('.md', '.html');
            const outputFile = path.join(this.docsDir, htmlPath);

            this.generateFromMarkdown(mdFile, outputFile);
        }

        // Generate index if needed
        this.updateIndex();

        console.log('\nDocumentation generation complete!');
    }

    /**
     * Find all markdown files recursively
     */
    findMarkdownFiles(dir) {
        const files = [];
        const items = fs.readdirSync(dir);

        for (const item of items) {
            const fullPath = path.join(dir, item);
            const stat = fs.statSync(fullPath);

            if (stat.isDirectory() && item !== 'node_modules' && item !== 'scripts' && item !== 'styles') {
                files.push(...this.findMarkdownFiles(fullPath));
            } else if (item.endsWith('.md')) {
                files.push(fullPath);
            }
        }

        return files;
    }

    /**
     * Update main index with links to generated docs
     */
    updateIndex() {
        const indexPath = path.join(this.docsDir, 'index.html');

        // Check for installation guides
        const installDir = path.join(this.docsDir, 'installation');
        if (fs.existsSync(installDir)) {
            const installFiles = fs.readdirSync(installDir)
                .filter(f => f.endsWith('.html'));

            if (installFiles.length > 0) {
                console.log(`\nInstallation guides available:`);
                installFiles.forEach(f => console.log(`  - installation/${f}`));
            }
        }
    }
}

// Run if called directly
if (require.main === module) {
    const docsDir = path.resolve(__dirname, '..');
    const generator = new DocsGenerator(docsDir);
    generator.generateAll();
}

module.exports = { DocsGenerator };
