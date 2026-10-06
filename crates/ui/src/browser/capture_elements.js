(() => {
    const width = innerWidth;
    const height = innerHeight;
    const elements = [];
    const interactive = 'button,a[href],input,select,textarea,[role="button"],[role="link"],[role="checkbox"],[role="tab"]';
    const selector = element => {
        const parts = [];
        for (let node = element; node && node.nodeType === 1 && parts.length < 5; node = node.parentElement) {
            if (node.id) {
                parts.unshift('#' + CSS.escape(node.id));
                break;
            }
            let part = node.localName;
            const siblings = node.parentElement ? Array.from(node.parentElement.children).filter(other => other.localName === node.localName) : [];
            if (siblings.length > 1) part += ':nth-of-type(' + (siblings.indexOf(node) + 1) + ')';
            parts.unshift(part);
        }
        return parts.join(' > ').slice(0, 400);
    };
    const visit = (root, prefix = '', offsetX = 0, offsetY = 0, depth = 0) => {
        for (const node of root.querySelectorAll('*')) {
            if (elements.length >= 3000) break;
            if (['html', 'body', 'script', 'style', 'meta', 'link', 'noscript', 'option'].includes(node.localName)) continue;
            const box = node.getBoundingClientRect();
            const left = Math.max(0, box.left + offsetX);
            const top = Math.max(0, box.top + offsetY);
            const right = Math.min(width, box.right + offsetX);
            const bottom = Math.min(height, box.bottom + offsetY);
            if (right - left < 4 || bottom - top < 4) continue;
            const style = node.ownerDocument.defaultView.getComputedStyle(node);
            if (style.visibility === 'hidden' || style.display === 'none' || Number(style.opacity) === 0 || style.pointerEvents === 'none') continue;
            const path = prefix + selector(node);
            if (node.shadowRoot) visit(node.shadowRoot, path + ' >>> ', offsetX, offsetY, depth + 1);
            if (node.localName === 'iframe') {
                try {
                    if (node.contentDocument) visit(node.contentDocument, path + ' >>> ', box.left + offsetX + node.clientLeft, box.top + offsetY + node.clientTop, depth + 1);
                } catch (_) {}
            }
            const control = node.closest(interactive);
            if (control && control !== node) continue;
            const hitRoot = node.getRootNode();
            const hit = (typeof hitRoot.elementFromPoint === 'function' ? hitRoot : node.ownerDocument).elementFromPoint((left + right) / 2 - offsetX, (top + bottom) / 2 - offsetY);
            if (hit && hit !== node && !node.contains(hit) && !hit.contains(node)) continue;
            const directText = Array.from(node.childNodes).filter(child => child.nodeType === 3).map(child => child.textContent).join(' ');
            const text = (node.getAttribute('aria-label') || node.getAttribute('alt') || node.getAttribute('title') || (control === node ? node.textContent : directText) || '').replace(/\s+/g, ' ').trim().slice(0, 180);
            elements.push({
                x: left / width, y: top / height, width: (right - left) / width, height: (bottom - top) / height,
                tag: node.localName, selector: path, text,
                depth: depth + path.split(' > ').length
            });
        }
    };
    visit(document);
    return elements;
})()
