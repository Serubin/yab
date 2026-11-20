import Foundation

/// The page side of a userscript (docs/userscripts.md, "The runtime"): one
/// block per script that leaves at once where its `@match`, `@include`
/// and `@exclude` rule it out, then gives the code the GM API. Each GM
/// call that reaches outside the script's world goes to Yab through one
/// message handler per world (Userscripts.Relay), which checks it against
/// what the script was kept with.
enum UserscriptRuntime {
    /// The handler's name: its own world's, or one per script in the page's.
    static func handler(_ id: String, inPage: Bool) -> String { inPage ? "yabUserscript_" + id.replacingOccurrences(of: "-", with: "_") : "yabUserscript" }

    /// The events a script in the page's world and its bridge talk over.
    private static func pipe(_ id: String, token: String) -> (ask: String, answer: String) {
        ("yab-us-" + token + "-" + id, "yab-us-" + token + "-" + id + "-back")
    }

    /// In the script's own world, for a script in the page's on Chromium,
    /// whose engine gives a page's world no relay.
    static func bridge(_ id: String, token: String) -> String {
        let (ask, answer) = pipe(id, token: token)
        return #"""
        const relay = window.webkit.messageHandlers.yabUserscript;
        const back = (detail) => document.dispatchEvent(new CustomEvent(\#(BoostScript.json(answer)), { detail: JSON.stringify(detail) }));
        document.addEventListener(\#(BoostScript.json(ask)), (event) => {
          const { n, body } = JSON.parse(event.detail);
          relay.postMessage(body).then((value) => back({ n, value }), (error) => back({ n, error: String(error && error.message || error) }));
        });
        """#
    }

    /// The bridge's other end, shaped like the handler a script otherwise holds.
    private static func piped(_ id: String, token: String) -> String {
        let (ask, answer) = pipe(id, token: token)
        return #"""
        { postMessage(body) { const n = Math.random().toString(36).slice(2) + performance.now();
          return new Promise((resolve, reject) => {
            const heard = (event) => { const said = JSON.parse(event.detail); if (said.n !== n) return;
              document.removeEventListener(\#(BoostScript.json(answer)), heard);
              if (said.error) reject(new Error(said.error)); else resolve(said.value); };
            document.addEventListener(\#(BoostScript.json(answer)), heard);
            document.dispatchEvent(new CustomEvent(\#(BoostScript.json(ask)), { detail: JSON.stringify({ n, body }) }));
          }); } }
        """#
    }

    static func source(_ script: Userscript, id: String, values: [String: Any], inPage: Bool, token: String, appVersion: String, piped pipes: Bool = false) -> String {
        let rules = script.runs
        let rule = { (list: [(String, String)]) in BoostScript.json(list.map { [$0.0, $0.1] }) }
        let info: [String: Any] = [
            "scriptHandler": Brand.name, "version": appVersion, "scriptMetaStr": metaBlock(script.source),
            "injectInto": inPage ? "page" : "content",
            "script": [
                "name": script.name, "namespace": script.namespace, "version": script.version,
                "description": script.summary, "author": script.author,
                "matches": script.matches, "includes": script.includes, "excludes": script.excludes,
                "grant": script.grants, "connects": script.connects, "runAt": script.runAt,
                "noframes": script.noframes, "icon": script.icon ?? "",
                "resources": script.resources.map { ["name": $0.name, "url": $0.url, "mimetype": $0.mime] },
                "require": script.requireURLs,
            ] as [String: Any],
        ]
        var resources: [String: [String: String]] = [:]
        for file in script.resources { resources[file.name] = ["text": file.text, "mime": file.mime] }
        let requires = script.requires.map { "/* @require \($0.url) */\n" + $0.text }.joined(separator: "\n;\n")
        let handler = pipes ? "" : handler(id, inPage: inPage)
        let found = pipes ? piped(id, token: token) : "window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers[\(BoostScript.json(handler))]"
        return #"""
        /* yab-userscript: \#(id) */
        (() => {
          const __href = location.href;
          const __test = (list) => list.some(([s, f]) => { try { return new RegExp(s, f).test(__href); } catch (e) { return false; } });
          if (!__test(\#(rule(rules.include))) || __test(\#(rule(rules.exclude)))) return;
          if (/(?:^|\/)(?:login|signin|sign-in|oauth|checkout|payment|wallet)(?:\/|$)/i.test(location.pathname)) return;
          const __handler = \#(found);
          if (!__handler) return;
          const __post = __handler.postMessage.bind(__handler);
          const __call = (op, args) => __post({ op, args: args || {}, token: \#(BoostScript.json(token)) }).then((r) => { if (r && r.error) throw new Error(r.error); return r ? r.value : undefined; });
          const __clone = (v) => v === undefined ? undefined : JSON.parse(JSON.stringify(v));
          const __values = \#(BoostScript.json(values));
          const __listeners = new Map();
          let __nextListener = 1;
          const __fire = (key, old, now, remote) => {
            for (const l of __listeners.values()) if (l.key === key) { try { l.fn(key, old, now, remote); } catch (e) { console.error(e); } }
          };
          const __menus = new Map();
          let __nextMenu = 1;
          const __errors = [];
          const __own = window.__yabUserscripts || (window.__yabUserscripts = {});
          __own[\#(BoostScript.json(id))] = {
            changed(key, value, removed) {
              const old = __values[key];
              if (removed) delete __values[key]; else __values[key] = value;
              __fire(key, old, removed ? undefined : value, true);
            },
            menu(id) { const m = __menus.get(String(id)); if (m) { try { m.fn(new MouseEvent('click')); } catch (e) { console.error(e); __errors.push(String(e)); } return true; } return false; },
            errors() { return __errors.slice(); },
            ran: false,
          };
          const GM_info = \#(BoostScript.json(info));
          const GM_getValue = (key, fallback) => Object.prototype.hasOwnProperty.call(__values, key) ? __clone(__values[key]) : fallback;
          const GM_setValue = (key, value) => {
            const old = __values[key];
            if (value === undefined) delete __values[key]; else __values[key] = __clone(value);
            __fire(key, old, value, false);
            __call('set', value === undefined ? { key, remove: true } : { key, value: __clone(value) }).catch((e) => console.error('GM_setValue: ' + e.message));
          };
          const GM_deleteValue = (key) => GM_setValue(key, undefined);
          const GM_listValues = () => Object.keys(__values);
          const GM_getValues = (keys) => {
            const out = {};
            if (Array.isArray(keys)) { for (const k of keys) if (k in __values) out[k] = __clone(__values[k]); }
            else if (keys && typeof keys === 'object') { for (const k of Object.keys(keys)) out[k] = GM_getValue(k, keys[k]); }
            return out;
          };
          const GM_setValues = (values) => { for (const k of Object.keys(values || {})) GM_setValue(k, values[k]); };
          const GM_deleteValues = (keys) => { for (const k of keys || []) GM_deleteValue(k); };
          const GM_addValueChangeListener = (key, fn) => { const id = __nextListener++; __listeners.set(id, { key, fn }); return id; };
          const GM_removeValueChangeListener = (id) => { __listeners.delete(id); };
          const GM_addStyle = (css) => {
            const style = document.createElement('style');
            style.textContent = String(css);
            (document.head || document.documentElement).appendChild(style);
            return style;
          };
          const GM_addElement = (parent, tag, attributes) => {
            if (typeof parent === 'string') { attributes = tag; tag = parent; parent = null; }
            const element = document.createElement(tag);
            for (const [k, v] of Object.entries(attributes || {})) { if (k === 'textContent') element.textContent = v; else element.setAttribute(k, v); }
            (parent || (['script', 'style', 'link', 'meta'].includes(String(tag).toLowerCase()) ? document.head : document.body) || document.documentElement).appendChild(element);
            return element;
          };
          const GM_registerMenuCommand = (caption, fn, options) => {
            const given = options && typeof options === 'object' ? options.id : undefined;
            const id = String(given !== undefined ? given : __nextMenu++);
            __menus.set(id, { caption: String(caption), fn });
            __call('menu', { op: 'add', id, caption: String(caption), title: options && options.title ? String(options.title) : '' }).catch(() => {});
            return id;
          };
          const GM_unregisterMenuCommand = (id) => { __menus.delete(String(id)); __call('menu', { op: 'remove', id: String(id) }).catch(() => {}); };
          const GM_notification = (details, title, image, onclick) => {
            const d = typeof details === 'object' && details ? details : { text: details, title, image, onclick };
            __call('notify', { text: String(d.text || ''), title: String(d.title || GM_info.script.name) }).catch((e) => console.error('GM_notification: ' + e.message));
          };
          const GM_openInTab = (url, options) => {
            const background = typeof options === 'boolean' ? options : options && typeof options === 'object' ? options.active === false || options.loadInBackground === true : false;
            __call('open', { url: new URL(url, location.href).href, background }).catch((e) => console.error('GM_openInTab: ' + e.message));
            return { closed: false, close() {}, onclose: null };
          };
          const GM_setClipboard = (data) => { __call('clipboard', { text: String(data) }).catch((e) => console.error('GM_setClipboard: ' + e.message)); };
          const GM_download = (details, name) => {
            const d = typeof details === 'object' && details ? details : { url: details, name };
            __call('download', { url: new URL(d.url, location.href).href, name: String(d.name || '') }).then(() => d.onload && d.onload({}), (e) => d.onerror ? d.onerror({ error: e.message }) : console.error('GM_download: ' + e.message));
          };
          const __resources = \#(BoostScript.json(resources));
          const GM_getResourceText = (name) => __resources[name] ? __resources[name].text : null;
          const GM_getResourceURL = (name) => {
            const r = __resources[name];
            if (!r) return null;
            const bytes = new TextEncoder().encode(r.text);
            let binary = ''; for (const b of bytes) binary += String.fromCharCode(b);
            return 'data:' + (r.mime || 'text/plain') + ';base64,' + btoa(binary);
          };
          const GM_log = (...args) => console.log(...args);
          const __base64 = (text) => { const s = atob(text || ''); const out = new Uint8Array(s.length); for (let i = 0; i < s.length; i++) out[i] = s.charCodeAt(i); return out.buffer; };
          const GM_xmlhttpRequest = (d) => {
            d = d || {};
            let aborted = false;
            const type = String(d.responseType || '').toLowerCase();
            let data = d.data;
            if (data instanceof URLSearchParams) data = data.toString();
            else if (data !== undefined && data !== null && typeof data !== 'string') { try { data = JSON.stringify(data); } catch (e) { data = String(data); } }
            const request = { url: new URL(d.url, location.href).href, method: String(d.method || 'GET').toUpperCase(), headers: d.headers || {},
              data: data === undefined ? null : data, responseType: type, timeout: Number(d.timeout) || 0, anonymous: !!d.anonymous, binary: ['arraybuffer', 'blob'].includes(type) };
            const finish = (response) => {
              if (aborted) return;
              if (d.onreadystatechange) try { d.onreadystatechange(response); } catch (e) { console.error(e); }
              const handler = response.status ? d.onload : (response.timedOut ? (d.ontimeout || d.onerror) : d.onerror);
              if (handler) try { handler(response); } catch (e) { console.error(e); __errors.push(String(e)); }
              if (d.onloadend) try { d.onloadend(response); } catch (e) { console.error(e); }
            };
            __call('xhr', request).then((r) => {
              let body = r.text;
              if (type === 'json') { try { body = JSON.parse(r.text); } catch (e) { body = null; } }
              else if (type === 'arraybuffer') body = __base64(r.base64);
              else if (type === 'blob') body = new Blob([__base64(r.base64)], { type: r.mime || '' });
              else if (type === 'document') { try { body = new DOMParser().parseFromString(r.text, r.mime && r.mime.includes('xml') ? 'application/xml' : 'text/html'); } catch (e) { body = null; } }
              finish({ readyState: 4, status: r.status, statusText: r.statusText, responseHeaders: r.headers, responseText: r.text, response: body,
                finalUrl: r.finalUrl, context: d.context, responseXML: type === 'document' ? body : null });
            }, (e) => {
              console.error('GM_xmlhttpRequest: ' + e.message);
              finish({ readyState: 4, status: 0, statusText: '', responseHeaders: '', responseText: '', response: null, finalUrl: request.url,
                error: e.message, timedOut: /timed out/i.test(e.message), context: d.context });
            });
            return { abort() { aborted = true; if (d.onabort) try { d.onabort({}); } catch (e) {} } };
          };
          const __promise = (fn) => (...args) => Promise.resolve().then(() => fn(...args));
          const GM = Object.freeze({
            info: GM_info,
            getValue: __promise(GM_getValue), setValue: __promise(GM_setValue), deleteValue: __promise(GM_deleteValue), listValues: __promise(GM_listValues),
            getValues: __promise(GM_getValues), setValues: __promise(GM_setValues), deleteValues: __promise(GM_deleteValues),
            addValueChangeListener: __promise(GM_addValueChangeListener), removeValueChangeListener: __promise(GM_removeValueChangeListener),
            addStyle: __promise(GM_addStyle), addElement: __promise(GM_addElement),
            registerMenuCommand: __promise(GM_registerMenuCommand), unregisterMenuCommand: __promise(GM_unregisterMenuCommand),
            notification: __promise(GM_notification), openInTab: __promise(GM_openInTab), setClipboard: __promise(GM_setClipboard),
            download: __promise(GM_download), getResourceText: __promise(GM_getResourceText), getResourceUrl: __promise(GM_getResourceURL),
            getResourceURL: __promise(GM_getResourceURL), log: __promise(GM_log),
            xmlHttpRequest: (d) => new Promise((resolve, reject) => {
              GM_xmlhttpRequest({ ...d, onload: (r) => { if (d && d.onload) d.onload(r); resolve(r); },
                onerror: (r) => { if (d && d.onerror) d.onerror(r); reject(r); }, ontimeout: (r) => { if (d && d.ontimeout) d.ontimeout(r); reject(r); } });
            }),
          });
          const unsafeWindow = window;
          const __run = () => {
            __own[\#(BoostScript.json(id))].ran = true;
            try {
              (function (GM, GM_info, GM_getValue, GM_setValue, GM_deleteValue, GM_listValues, GM_getValues, GM_setValues, GM_deleteValues,
                         GM_addValueChangeListener, GM_removeValueChangeListener, GM_addStyle, GM_addElement, GM_registerMenuCommand,
                         GM_unregisterMenuCommand, GM_notification, GM_openInTab, GM_setClipboard, GM_download, GM_getResourceText,
                         GM_getResourceURL, GM_xmlhttpRequest, GM_log, unsafeWindow) {
        \#(requires)
        ;
        \#(script.code)
              }).call(window, GM, GM_info, GM_getValue, GM_setValue, GM_deleteValue, GM_listValues, GM_getValues, GM_setValues, GM_deleteValues,
                      GM_addValueChangeListener, GM_removeValueChangeListener, GM_addStyle, GM_addElement, GM_registerMenuCommand,
                      GM_unregisterMenuCommand, GM_notification, GM_openInTab, GM_setClipboard, GM_download, GM_getResourceText,
                      GM_getResourceURL, GM_xmlhttpRequest, GM_log, unsafeWindow);
            } catch (e) {
              __errors.push(String(e && e.stack || e));
              console.error('[' + GM_info.script.name + '] ' + (e && e.message || e));
              __call('error', { message: String(e && e.message || e) }).catch(() => {});
            }
          };
          \#(runAt(script.runAt))
        })();
        """#
    }

    /// When the code starts: at once for document-start and document-end
    /// (WebKit's own times); for document-idle, once the page has loaded
    /// and the main thread has a moment, two seconds at most.
    private static func runAt(_ when: String) -> String {
        guard when == "document-idle" else { return "__run();" }
        return """
        {
          let __started = false;
          const __go = () => { if (__started) return; __started = true; __run(); };
          const __idle = () => (window.requestIdleCallback ? requestIdleCallback(__go, { timeout: 500 }) : setTimeout(__go, 0));
          if (document.readyState === 'complete') __idle(); else window.addEventListener('load', __idle, { once: true });
          setTimeout(__go, 2000);
        }
        """
    }

    /// The header as written, for GM_info.scriptMetaStr.
    static func metaBlock(_ source: String) -> String {
        guard let start = source.range(of: "==UserScript=="), let end = source.range(of: "==/UserScript==", range: start.upperBound..<source.endIndex) else { return "" }
        let from = source[..<start.lowerBound].lastIndex(of: "\n").map { source.index(after: $0) } ?? source.startIndex
        return String(source[from..<end.upperBound])
    }
}
