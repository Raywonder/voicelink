/**
 * VoiceLink Local Documentation JavaScript
 * Main documentation functionality and utilities
 */

class DocumentationManager {
    constructor() {
        this.currentPage = window.location.pathname.split('/').pop();
        this.init();
    }

    init() {
        this.setupNavigation();
        this.setupAccessibility();
        this.setupHelp();
        this.setupTables();
        this.setupCodeBlocks();
        this.setupScrollToTop();
    }

    setupNavigation() {
        // Add active states to navigation
        const navLinks = document.querySelectorAll('nav a, .nav-link');
        navLinks.forEach(link => {
            if (link.href.includes(this.currentPage)) {
                link.classList.add('active');
            }
        });

        // Smooth scrolling for anchor links
        document.querySelectorAll('a[href^="#"]').forEach(anchor => {
            anchor.addEventListener('click', (e) => {
                e.preventDefault();
                const target = document.querySelector(anchor.getAttribute('href'));
                if (target) {
                    target.scrollIntoView({
                        behavior: 'smooth',
                        block: 'start'
                    });
                }
            });
        });
    }

    setupAccessibility() {
        // Add keyboard navigation for card elements
        const cards = document.querySelectorAll('.feature-card, .quick-card, .platform-card, .trouble-card');
        cards.forEach(card => {
            if (!card.hasAttribute('tabindex')) {
                card.setAttribute('tabindex', '0');
            }

            card.addEventListener('keydown', (e) => {
                if (e.key === 'Enter' || e.key === ' ') {
                    e.preventDefault();
                    const link = card.querySelector('a') || card;
                    if (link.href) {
                        window.location.href = link.href;
                    }
                }
            });
        });

        // Add skip navigation link
        this.addSkipNavigation();

        // Improve table accessibility
        const tables = document.querySelectorAll('table');
        tables.forEach(table => {
            if (!table.hasAttribute('role')) {
                table.setAttribute('role', 'table');
            }
        });
    }

    addSkipNavigation() {
        const skipNav = document.createElement('a');
        skipNav.href = '#main-content';
        skipNav.textContent = 'Skip to main content';
        skipNav.className = 'skip-nav';
        skipNav.style.cssText = `
            position: absolute;
            top: -40px;
            left: 6px;
            background: #000;
            color: #fff;
            padding: 8px;
            text-decoration: none;
            border-radius: 4px;
            z-index: 10000;
        `;

        skipNav.addEventListener('focus', () => {
            skipNav.style.top = '6px';
        });

        skipNav.addEventListener('blur', () => {
            skipNav.style.top = '-40px';
        });

        document.body.insertBefore(skipNav, document.body.firstChild);

        // Add main content ID if it doesn't exist
        const mainContent = document.querySelector('main, .docs-container, .content');
        if (mainContent && !mainContent.id) {
            mainContent.id = 'main-content';
        }
    }

    setupHelp() {
        // Add help tooltips for complex terms
        const helpTerms = {
            '3D Audio': 'Spatial audio that positions voices in 3D space for immersive communication',
            'Audio Ducking': 'Automatic volume reduction to prevent feedback and improve clarity',
            'P2P': 'Peer-to-peer direct connection between users without central server',
            'WebRTC': 'Web Real-Time Communication technology for voice and video',
            'TTS': 'Text-to-Speech conversion for announcements',
            'PA System': 'Public Address system for broadcasting to all users',
            '2FA': 'Two-Factor Authentication for enhanced security',
            'VoiceOver': 'Apple\'s screen reader technology for accessibility'
        };

        Object.entries(helpTerms).forEach(([term, description]) => {
            const regex = new RegExp(`\\b${term.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}\\b`, 'g');
            this.addTooltips(regex, term, description);
        });
    }

    addTooltips(regex, term, description) {
        const walker = document.createTreeWalker(
            document.body,
            NodeFilter.SHOW_TEXT,
            null,
            false
        );

        const textNodes = [];
        let node;
        while (node = walker.nextNode()) {
            if (node.nodeValue.match(regex) &&
                !node.parentElement.closest('.tooltip, code, pre')) {
                textNodes.push(node);
            }
        }

        textNodes.forEach(textNode => {
            const parent = textNode.parentElement;
            const newHTML = textNode.nodeValue.replace(regex,
                `<span class="help-term" data-tooltip="${description}" tabindex="0">${term}</span>`
            );

            const wrapper = document.createElement('span');
            wrapper.innerHTML = newHTML;
            parent.replaceChild(wrapper, textNode);
        });

        // Add tooltip styles and behavior
        this.setupTooltipBehavior();
    }

    setupTooltipBehavior() {
        const style = document.createElement('style');
        style.textContent = `
            .help-term {
                border-bottom: 1px dotted #667eea;
                cursor: help;
                position: relative;
            }

            .help-term:hover, .help-term:focus {
                border-bottom-style: solid;
            }

            .help-term::after {
                content: attr(data-tooltip);
                position: absolute;
                bottom: 100%;
                left: 50%;
                transform: translateX(-50%);
                background: #333;
                color: white;
                padding: 0.5rem;
                border-radius: 4px;
                font-size: 0.875rem;
                white-space: nowrap;
                opacity: 0;
                pointer-events: none;
                transition: opacity 0.3s;
                z-index: 1000;
                max-width: 200px;
                white-space: normal;
            }

            .help-term:hover::after,
            .help-term:focus::after {
                opacity: 1;
            }
        `;
        document.head.appendChild(style);
    }

    setupTables() {
        // Make tables responsive
        const tables = document.querySelectorAll('table');
        tables.forEach(table => {
            if (!table.closest('.table-responsive')) {
                const wrapper = document.createElement('div');
                wrapper.className = 'table-responsive';
                wrapper.style.cssText = 'overflow-x: auto; margin: 1rem 0;';
                table.parentNode.insertBefore(wrapper, table);
                wrapper.appendChild(table);
            }

            // Add sorting functionality
            this.addTableSorting(table);
        });
    }

    addTableSorting(table) {
        const headers = table.querySelectorAll('th');
        headers.forEach((header, index) => {
            if (!header.classList.contains('no-sort')) {
                header.style.cursor = 'pointer';
                header.setAttribute('role', 'button');
                header.setAttribute('tabindex', '0');

                header.addEventListener('click', () => {
                    this.sortTable(table, index);
                });

                header.addEventListener('keydown', (e) => {
                    if (e.key === 'Enter' || e.key === ' ') {
                        e.preventDefault();
                        this.sortTable(table, index);
                    }
                });
            }
        });
    }

    sortTable(table, columnIndex) {
        const tbody = table.querySelector('tbody');
        if (!tbody) return;

        const rows = Array.from(tbody.querySelectorAll('tr'));
        const isAscending = table.getAttribute('data-sort-direction') !== 'asc';

        rows.sort((a, b) => {
            const aValue = a.cells[columnIndex]?.textContent.trim() || '';
            const bValue = b.cells[columnIndex]?.textContent.trim() || '';

            // Try to parse as numbers
            const aNum = parseFloat(aValue);
            const bNum = parseFloat(bValue);

            if (!isNaN(aNum) && !isNaN(bNum)) {
                return isAscending ? aNum - bNum : bNum - aNum;
            }

            // String comparison
            return isAscending ?
                aValue.localeCompare(bValue) :
                bValue.localeCompare(aValue);
        });

        // Update table
        rows.forEach(row => tbody.appendChild(row));
        table.setAttribute('data-sort-direction', isAscending ? 'asc' : 'desc');

        // Update header indicators
        const headers = table.querySelectorAll('th');
        headers.forEach((header, index) => {
            header.classList.remove('sort-asc', 'sort-desc');
            if (index === columnIndex) {
                header.classList.add(isAscending ? 'sort-asc' : 'sort-desc');
            }
        });
    }

    setupCodeBlocks() {
        // Add copy buttons to code blocks
        const codeBlocks = document.querySelectorAll('pre code');
        codeBlocks.forEach(codeBlock => {
            const pre = codeBlock.parentElement;
            if (pre.querySelector('.copy-btn')) return; // Already has copy button

            const copyBtn = document.createElement('button');
            copyBtn.className = 'copy-btn';
            copyBtn.textContent = 'Copy';
            copyBtn.setAttribute('aria-label', 'Copy code to clipboard');

            copyBtn.addEventListener('click', async () => {
                try {
                    await navigator.clipboard.writeText(codeBlock.textContent);
                    copyBtn.textContent = 'Copied!';
                    setTimeout(() => {
                        copyBtn.textContent = 'Copy';
                    }, 2000);
                } catch (err) {
                    console.error('Failed to copy code:', err);
                    copyBtn.textContent = 'Failed';
                    setTimeout(() => {
                        copyBtn.textContent = 'Copy';
                    }, 2000);
                }
            });

            pre.style.position = 'relative';
            pre.appendChild(copyBtn);
        });

        // Add copy button styles
        const style = document.createElement('style');
        style.textContent = `
            .copy-btn {
                position: absolute;
                top: 0.5rem;
                right: 0.5rem;
                background: #667eea;
                color: white;
                border: none;
                padding: 0.25rem 0.5rem;
                border-radius: 4px;
                font-size: 0.75rem;
                cursor: pointer;
                opacity: 0.7;
                transition: opacity 0.3s;
            }

            .copy-btn:hover, .copy-btn:focus {
                opacity: 1;
            }

            pre:hover .copy-btn {
                opacity: 1;
            }

            th.sort-asc::after {
                content: " ↑";
            }

            th.sort-desc::after {
                content: " ↓";
            }

            .table-responsive {
                border: 1px solid #dee2e6;
                border-radius: 8px;
            }
        `;
        document.head.appendChild(style);
    }

    setupScrollToTop() {
        // Add scroll to top button
        const scrollBtn = document.createElement('button');
        scrollBtn.id = 'scroll-to-top';
        scrollBtn.innerHTML = '↑';
        scrollBtn.setAttribute('aria-label', 'Scroll to top');
        scrollBtn.style.cssText = `
            position: fixed;
            bottom: 2rem;
            right: 2rem;
            width: 50px;
            height: 50px;
            border: none;
            border-radius: 50%;
            background: #667eea;
            color: white;
            font-size: 1.5rem;
            cursor: pointer;
            opacity: 0;
            visibility: hidden;
            transition: all 0.3s ease;
            z-index: 1000;
            box-shadow: 0 4px 12px rgba(0, 0, 0, 0.2);
        `;

        scrollBtn.addEventListener('click', () => {
            window.scrollTo({
                top: 0,
                behavior: 'smooth'
            });
        });

        document.body.appendChild(scrollBtn);

        // Show/hide scroll button based on scroll position
        window.addEventListener('scroll', () => {
            if (window.scrollY > 500) {
                scrollBtn.style.opacity = '1';
                scrollBtn.style.visibility = 'visible';
            } else {
                scrollBtn.style.opacity = '0';
                scrollBtn.style.visibility = 'hidden';
            }
        });
    }

    // Utility method to create breadcrumbs
    createBreadcrumbs(items) {
        const breadcrumbNav = document.createElement('nav');
        breadcrumbNav.setAttribute('aria-label', 'Breadcrumb');
        breadcrumbNav.className = 'breadcrumb-nav';

        const breadcrumbList = document.createElement('ol');
        breadcrumbList.className = 'breadcrumb';

        items.forEach((item, index) => {
            const listItem = document.createElement('li');
            listItem.className = 'breadcrumb-item';

            if (index === items.length - 1) {
                // Current page
                listItem.textContent = item.text;
                listItem.setAttribute('aria-current', 'page');
            } else {
                // Link to parent pages
                const link = document.createElement('a');
                link.href = item.url;
                link.textContent = item.text;
                listItem.appendChild(link);
            }

            breadcrumbList.appendChild(listItem);
        });

        breadcrumbNav.appendChild(breadcrumbList);
        return breadcrumbNav;
    }

    // Method to highlight search terms in content
    highlightSearchTerms() {
        const urlParams = new URLSearchParams(window.location.search);
        const searchTerm = urlParams.get('search');

        if (searchTerm) {
            const regex = new RegExp(`(${searchTerm.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')})`, 'gi');
            this.highlightInElement(document.body, regex);
        }
    }

    highlightInElement(element, regex) {
        const walker = document.createTreeWalker(
            element,
            NodeFilter.SHOW_TEXT,
            node => {
                return node.parentElement.tagName !== 'SCRIPT' &&
                       node.parentElement.tagName !== 'STYLE' &&
                       !node.parentElement.closest('.search-highlight') ?
                       NodeFilter.FILTER_ACCEPT :
                       NodeFilter.FILTER_REJECT;
            },
            false
        );

        const textNodes = [];
        let node;
        while (node = walker.nextNode()) {
            if (regex.test(node.nodeValue)) {
                textNodes.push(node);
            }
        }

        textNodes.forEach(textNode => {
            const parent = textNode.parentElement;
            const highlightedHTML = textNode.nodeValue.replace(regex,
                '<span class="search-highlight">$1</span>'
            );

            const wrapper = document.createElement('span');
            wrapper.innerHTML = highlightedHTML;
            parent.replaceChild(wrapper, textNode);
        });

        // Add highlight styles
        if (textNodes.length > 0) {
            const style = document.createElement('style');
            style.textContent = `
                .search-highlight {
                    background: yellow;
                    padding: 1px 2px;
                    border-radius: 2px;
                }
            `;
            document.head.appendChild(style);
        }
    }
}

// Initialize documentation manager when DOM is loaded
document.addEventListener('DOMContentLoaded', () => {
    window.docsManager = new DocumentationManager();
});

// Export for use in other scripts
window.DocumentationManager = DocumentationManager;