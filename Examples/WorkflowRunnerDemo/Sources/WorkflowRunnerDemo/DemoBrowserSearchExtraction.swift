import Foundation

/// Runs in an isolated WebKit content world. Only known, rendered result containers are read.
enum DemoBrowserSearchExtraction {
    static let script = #"""
    const visible = (element) => {
        if (!element || !element.isConnected || !element.getClientRects().length) return false;
        for (let e = element; e; e = e.parentElement) {
            const style = getComputedStyle(e);
            if (e.hidden || e.getAttribute('aria-hidden') === 'true' || style.display === 'none' ||
                style.visibility === 'hidden' || style.visibility === 'collapse' || Number(style.opacity) === 0) return false;
        }
        return true;
    };
    const title = String(document.title || '').slice(0, 512);
    const challengeTitle = /^(百度安全验证|百度安全校验|百度账号登录|百度帐号登录|安全验证)(?:\s|$|[-·])/;
    const challenge = [...document.querySelectorAll('iframe[src*="wappass.baidu.com"], #captcha, #verify-wrapper, form[action*="passport.baidu.com"]')].some(visible);
    if (challengeTitle.test(title) || challenge) return {status: 'verification', title, text: ''};
    const root = document.querySelector('#content_left') || document.querySelector('#results');
    if (!visible(root)) return {status: 'waiting', title, text: '', rootPresent: !!root, mobilePage: !!document.querySelector('#page'), homePage: !!document.querySelector('#wrapper')};
    const excluded = 'script, style, noscript, template, form, input, textarea, select, option, button, [hidden], [aria-hidden="true"], [contenteditable]:not([contenteditable="false"])';
    const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT);
    let node, text = '', visited = 0;
    while ((node = walker.nextNode()) && ++visited <= 20000 && text.length < 8192) {
        const parent = node.parentElement;
        if (!parent || parent.closest(excluded) || !visible(parent)) continue;
        const range = document.createRange();
        range.selectNodeContents(node);
        if (![...range.getClientRects()].some(rect => rect.width > 0 && rect.height > 0)) continue;
        const value = String(node.nodeValue || '').replace(/\s+/g, ' ').trim();
        if (value) text += (text ? '\n' : '') + value.slice(0, 8192 - text.length);
    }
    return {status: text.trim() ? 'ready' : 'waiting', title, text: text.slice(0, 8192)};
    """#
}
