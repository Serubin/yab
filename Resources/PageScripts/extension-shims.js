(() => {
  const root = globalThis;
  // Taken now, not looked up at each use: a sandbox that later locks
  // the globals away (MetaMask's LavaMoat) would break the shim's own
  // code that needs them, every fetch of a Request, every import.
  const { URL, FileReader, Response, Blob, File, DOMException, HTMLImageElement, HTMLAnchorElement, Element } = root;
  const chrome = root.chrome || root.browser;
  // A page's own world, where an extension's MAIN-world script runs with
  // this before it, has no extension APIs. Nothing to mend there, and
  // nothing may be left there for a page to see: Safari leaves nothing.
  const ours = (() => { try { return !!(chrome && chrome.runtime && chrome.runtime.id); } catch (e) { return false; } })();
  if (!ours || root.__yabShim) return;
  // Bitwarden's compiled `using` helpers need these before its crypto
  // handles define their disposal methods. WebKit does not yet supply
  // them. Cover its worker, pages and content scripts; keep native ones.
  for (const name of ["dispose", "asyncDispose"]) {
    if (typeof Symbol[name] === "undefined") {
      Object.defineProperty(Symbol, name, { value: Symbol("Symbol." + name) });
    }
  }
  // WebKit took requestIdleCallback out again after a page-load
  // regression (bug 287681), and Proton Pass's form detection waits on
  // it: it never found a sign-in form. Chrome's deadline is at most
  // 50 ms; this one gives the whole of it, after the caller finishes.
  if (typeof root.requestIdleCallback !== "function" || typeof root.cancelIdleCallback !== "function") {
    const idle = new Map();
    let idleId = 0;
    root.requestIdleCallback = (callback) => {
      const id = ++idleId;
      idle.set(id, setTimeout(() => {
        if (!idle.delete(id)) return;
        const start = Date.now();
        callback({ didTimeout: false, timeRemaining: () => Math.max(0, 50 - (Date.now() - start)) });
      }, 1));
      return id;
    };
    root.cancelIdleCallback = (id) => {
      if (!idle.has(id)) return;
      clearTimeout(idle.get(id));
      idle.delete(id);
    };
  }
  Object.defineProperty(root, "__yabShim", { value: true });
  // WebKit finds a page's extension APIs through the `chrome` and
  // `browser` globals when it delivers an event. A sandbox that locks
  // every global away (MetaMask's LavaMoat) cuts it off: nothing arrives
  // any more. Made fixed accessors, they can't be taken away, and code
  // that assigns its own polyfill to them still can.
  for (const key of ["browser", "chrome"]) {
    // SingleFile installs its browser namespace with __defineGetter__ at
    // worker startup. That requires a configurable property; chrome stays
    // protected for WebKit's event delivery.
    if (key === "browser" && chrome.runtime.id === "mpiodijhokgodhhofbcjdecpffjipkle") continue;
    const d = Object.getOwnPropertyDescriptor(root, key);
    if (!d || !d.configurable) continue;
    let value = root[key];
    // A replacement that hides the APIs, a Proxy some extensions put
    // there to keep them from other code (Proton Pass), would hide them
    // from WebKit too, and nothing would reach the extension again. A
    // replacement that still carries them is taken.
    const carries = (v) => { try { return !!(v && v.runtime && v.runtime.id); } catch (e) { return false; } };
    try { Object.defineProperty(root, key, { configurable: false, enumerable: d.enumerable, get: () => value, set: (v) => { if (carries(v)) value = v; } }); } catch (e) {}
  }
  // On a web page this is a content script: only Chrome's behavior is
  // mended there, no API that Chrome doesn't give content scripts either.
  const inContent = typeof location !== "undefined" && !/^(chrome|webkit)-extension:$/.test(location.protocol);
  // Object.defineProperty(localStorage, "getItem", {writable: true}), a
  // data descriptor with no value, ends the page's process in WebKit
  // (WebCore::JSStorage::defineOwnProperty). Fabric's capture.js does it
  // for the four methods of every page's localStorage, in its own world,
  // put there by scripting.executeScript: every page crashed (feedback
  // #429). Chrome takes it as its named setter, setItem(key, value),
  // the value "undefined" when none is given; so it is here, in an
  // extension's world (also put first where executeScript runs files or
  // a function in it). Self-contained: it is handed to executeScript.
  function yabStorageGuard() {
    const mark = Symbol.for("yab.storageGuard");
    if (typeof Storage !== "function" || Object[mark]) return;
    const define = Object.defineProperty, defines = Object.defineProperties, reflect = Reflect.defineProperty;
    const named = (o, k, d) => {
      try { if (!(o instanceof Storage)) return false; } catch (e) { return false; }
      return typeof k !== "symbol" && d !== null && typeof d === "object" && !("get" in d) && !("set" in d);
    };
    const put = (target, key, value) => define(target, key, { value, configurable: true, writable: true });
    put(Object, "defineProperty", function defineProperty(o, k, d) {
      if (!named(o, k, d)) return define(o, k, d);
      o.setItem(String(k), String(d.value));
      return o;
    });
    put(Object, "defineProperties", function defineProperties(o, all) {
      let storage = false;
      try { storage = o instanceof Storage; } catch (e) {}
      if (!storage || all === null || typeof all !== "object") return defines(o, all);
      for (const k of Reflect.ownKeys(all)) Object.defineProperty(o, k, all[k]);
      return o;
    });
    put(Reflect, "defineProperty", function defineProperty(o, k, d) {
      if (!named(o, k, d)) return reflect(o, k, d);
      try { o.setItem(String(k), String(d.value)); return true; } catch (e) { return false; }
    });
    define(Object, mark, { value: true });
  }
  if (inContent) { try { yabStorageGuard(); } catch (e) {} }
  // EyeDropper in a content script, which Chrome gives every world and
  // WebKit none (row 1074). The page's own is Yab's (eyedropper-page.js);
  // this world can't see it, so it asks the same bridge in Yab's world
  // with the same events on the shared window (EyeDropper.swift).
  if (inContent && typeof window !== "undefined" && !("EyeDropper" in root)) {
    try {
      const asked = "yab-eyedropper-ask", answered = "yab-eyedropper-answer";
      const waiting = new Map();
      let open = null;
      const abort = (text) => new DOMException(text, "AbortError");
      window.addEventListener(answered, (event) => {
        let m;
        try { m = JSON.parse(event.detail); } catch (e) { return; }
        const w = m && waiting.get(m.id);
        if (!w) return;
        waiting.delete(m.id);
        if (open === m.id) open = null;
        if (m.hex) w.resolve({ sRGBHex: m.hex });
        else if (m.error === "NotAllowedError" || m.error === "InvalidStateError") w.reject(new DOMException(m.message || m.error, m.error));
        else w.reject(abort(m.message || "The user canceled the selection."));
      });
      class EyeDropper {
        open(options) {
          const signal = options && options.signal;
          if (signal && signal.aborted) return Promise.reject(signal.reason !== undefined ? signal.reason : abort("The operation was aborted."));
          if (open) return Promise.reject(new DOMException("An eye dropper is already open.", "InvalidStateError"));
          if (navigator.userActivation && !navigator.userActivation.isActive) {
            return Promise.reject(new DOMException("EyeDropper.open() needs a user gesture.", "NotAllowedError"));
          }
          const id = "c" + Math.random().toString(36).slice(2) + Date.now().toString(36);
          open = id;
          return new Promise((resolve, reject) => {
            waiting.set(id, { resolve, reject });
            if (signal) signal.addEventListener("abort", () => {
              if (!waiting.delete(id)) return;
              if (open === id) open = null;
              window.dispatchEvent(new CustomEvent(asked, { detail: JSON.stringify({ kind: "cancel", id }) }));
              reject(signal.reason !== undefined ? signal.reason : abort("The operation was aborted."));
            }, { once: true });
            window.dispatchEvent(new CustomEvent(asked, { detail: JSON.stringify({ kind: "open", id }) }));
          });
        }
      }
      Object.defineProperty(root, "EyeDropper", { value: EyeDropper, configurable: true, writable: true, enumerable: false });
    } catch (e) {}
  }
  // WebUSB and WebHID, which Chrome has and WebKit doesn't: an extension
  // page that lists the hardware wallets already allowed reads
  // navigator.usb.getDevices() and filters it, and Rabby's popup threw
  // on the missing list. There are none here: empty lists, and asking
  // for one finds nothing, as when no device is chosen.
  if (!inContent && typeof navigator !== "undefined" && typeof document !== "undefined") {
    for (const name of ["usb", "hid"]) {
      if (name in navigator) continue;
      const none = () => Promise.reject(new DOMException("No device selected.", "NotFoundError"));
      const api = { getDevices: () => Promise.resolve([]), requestDevice: none, onconnect: null, ondisconnect: null,
        addEventListener() {}, removeEventListener() {}, dispatchEvent() { return false; } };
      try { Object.defineProperty(Object.getPrototypeOf(navigator), name, { get: () => api, configurable: true, enumerable: true }); } catch (e) {}
    }
  }
  // The page's window.close(), which Yab carries to its popup or popout
  // (ExtensionPopup.closeBridge), made before the page's own scripts run.
  // MetaMask's LavaMoat takes away every global it doesn't name as its
  // page starts, close among them, and the bridge, put in once the
  // document was built, found close already gone: "property close of
  // globalThis is inaccessible", at every opening of its popup, which
  // stayed open. LavaMoat leaves alone what can't be redefined, so close
  // is made so here, still the page's to set as WebKit's was, and told
  // later where to carry the call (`__yabPopupClose`). Until then, and
  // in any page that isn't a popup, it is WebKit's close.
  if (!inContent && typeof window !== "undefined" && typeof document !== "undefined" && window.top === window) {
    // Held now: the globals go too.
    const page = window, apply = Reflect.apply, isArray = Array.isArray, text = String;
    const own = Object.getOwnPropertyDescriptor(page, "close");
    const nativeClose = page.close;
    const kit = (() => { try { return page.webkit && page.webkit.messageHandlers; } catch (e) { return null; } })();
    let carry = null;
    const close = function close(...args) {
      if ((this === page || this === undefined) && carry) {
        try { (kit || page.webkit.messageHandlers)[carry[0]].postMessage(carry[1]); return; } catch (e) {}
      }
      return apply(nativeClose, this === undefined ? page : this, args);
    };
    let current = close;
    if (own && own.configurable && typeof nativeClose === "function") {
      try {
        Object.defineProperty(page, "close", { configurable: false, enumerable: own.enumerable, get: () => current, set: (f) => { current = f; } });
        Object.defineProperty(page, "__yabPopupClose", { configurable: false, enumerable: false, get: () => undefined,
          set: (v) => { if (isArray(v) && v.length === 2) carry = [text(v[0]), text(v[1])]; } });
      } catch (e) {}
    }
  }
  // An extension page's deferred scripts run back to back in Chrome, so a
  // jQuery ready callback one of them queues runs after all of them.
  // WebKit lets a timer in between, and the callback ran before the later
  // scripts defined what it calls: AdBlock's options page threw "Can't find
  // variable: initializeProxies" and never filled its tabs. Until
  // DOMContentLoaded, readyState reads "loading" on an extension's page,
  // and jQuery waits for that event, as it does in Chrome.
  if (!inContent && typeof document !== "undefined" && document.readyState === "loading" && typeof Document !== "undefined") {
    const real = Object.getOwnPropertyDescriptor(Document.prototype, "readyState");
    if (real && real.get) {
      let parsed = false;
      try {
        Object.defineProperty(document, "readyState", { configurable: true, enumerable: true,
          get() { const state = real.get.call(this); return state === "interactive" && !parsed ? "loading" : state; } });
        document.addEventListener("DOMContentLoaded", () => { parsed = true; delete document.readyState; }, { once: true, capture: true });
      } catch (e) {}
    }
  }
  const runtime = chrome.runtime;
  // One of the extension's pages in a frame of a website: Vimium's bar,
  // the list iCloud Passwords opens under a field, 1Password's menu.
  // WebKit runs it in the website's process, which it trusts with no
  // more than a content script: a single call to tabs, windows,
  // scripting… and WebKit takes the process for compromised and ends
  // it. The page reloads, and a frame that makes the call as it loads
  // reloads it for ever. Chrome gives such a frame everything, so here
  // the worker makes those calls for it (see `__yabCall`).
  const framed = !inContent && typeof window !== "undefined" && window.top !== window && (() => {
    try { const a = location.ancestorOrigins; if (a && a.length) return [...a].some((o) => o !== location.origin); } catch (e) {}
    try { return window.top.location.origin !== location.origin; } catch (e) { return true; }
  })();

  // WebKit's objects are kept, WebKit finds an extension's listeners
  // through them, and a replacement would hide them. Members are set on
  // them instead: a method lives on the prototype, so an own property of
  // the same name takes its place.
  // WebKit's namespace and event objects are wrappers it doesn't keep
  // alive: once no script holds one, it is collected, and the next
  // `chrome.tabs` is a fresh object without what was set on it. So every
  // object touched here is held for good.
  const kept = new Set();
  try { Object.defineProperty(root, "__yabKept", { value: kept }); } catch (e) {}
  const put = (target, key, value) => {
    if (target && (typeof target === "object" || typeof target === "function")) kept.add(target);
    try { Object.defineProperty(target, key, { value, configurable: true, writable: true, enumerable: true }); }
    catch (e) { try { target[key] = value; } catch (e2) {} }
  };
  // Held from the start, before the extension's own code runs, its
  // polyfills set things on these objects too.
  const spaces = new Set(Object.keys(chrome));
  for (let o = Object.getPrototypeOf(chrome); o && o !== Object.prototype; o = Object.getPrototypeOf(o)) Object.getOwnPropertyNames(o).forEach((k) => spaces.add(k));
  for (const space of spaces) {
    let ns; try { ns = chrome[space]; } catch (e) { continue; }
    if (!ns || typeof ns !== "object") continue;
    kept.add(ns);
    // And the same object every time it is asked for: WebKit can hand
    // out a fresh one, without what was set on the last.
    if (!Object.prototype.hasOwnProperty.call(chrome, space) || Object.getOwnPropertyDescriptor(chrome, space).get) {
      try { Object.defineProperty(chrome, space, { value: ns, configurable: true, writable: true, enumerable: true }); } catch (e) {}
    }
    for (let o = ns; o && o !== Object.prototype; o = Object.getPrototypeOf(o)) {
      for (const key of Object.getOwnPropertyNames(o)) {
        if (!/^on[A-Z]/.test(key)) continue;
        try { const ev = ns[key]; if (ev && typeof ev === "object") kept.add(ev); } catch (e) {}
      }
    }
    for (const sub of ["local", "sync", "session", "managed"]) { try { if (ns[sub] && typeof ns[sub] === "object") kept.add(ns[sub]); } catch (e) {} }
  }
  // Chrome accepts null or undefined for the optional localization
  // arguments. WebKit's argument matcher can read a trailing null as
  // the required name and throw instead: iCloud's PIN labels use
  // getMessage(name, null, null). Omit only those empty arguments.
  // An empty name is an unknown message to Chrome, which answers "";
  // WebKit throws, and crxMouse's gesture editor went blank on it.
  if (chrome.i18n && typeof chrome.i18n.getMessage === "function") {
    const message = chrome.i18n.getMessage.bind(chrome.i18n);
    put(chrome.i18n, "getMessage", (...args) => {
      if (args[0] === "") return "";
      if (args.length > 1 && args[1] == null) args[1] = undefined;
      if (args.length === 3 && args[2] == null) args.pop();
      while (args.length > 1 && args[args.length - 1] === undefined) args.pop();
      return message(...args);
    });
  }
  // This start of the worker (see the end of the script).
  const workerLife = Math.random().toString(36).slice(2) + Date.now().toString(36);
  const withLastError = (error, callback) => {
    put(runtime, "lastError", { message: String(error && error.message || error) });
    try { callback(); } finally { try { delete runtime.lastError; } catch (e) {} }
  };
  const native = (api, args) =>
    runtime.sendNativeMessage("yab", { api, args: JSON.parse(JSON.stringify(args ?? [])) })
      .then((reply) => {
        if (reply && reply.error) throw new Error(reply.error);
        return reply ? reply.value : undefined;
      });
  // Chrome's APIs take a callback last, or return a promise without one.
  const call = (api) => (...args) => {
    const callback = args.length && typeof args[args.length - 1] === "function" ? args.pop() : null;
    const promise = native(api, args);
    if (!callback) return promise;
    promise.then((value) => callback(value), (error) => withLastError(error, callback));
  };
  const event = () => {
    const listeners = new Set();
    return {
      addListener: (f) => listeners.add(f), removeListener: (f) => listeners.delete(f),
      hasListener: (f) => listeners.has(f), hasListeners: () => listeners.size > 0,
      listeners,
    };
  };

  // Chrome's favicon permission: chrome-extension://<id>/_favicon/?pageUrl=…
  // is the browser's icon for that page. WebKit has no such file, so the
  // image failed and OneTab's list wore its gray globe on every tab
  // (feedback #156). An image or a fetch of it gets the icon Yab keeps for
  // the page's site, as a data: URL from the browser ("favicon.get"), and
  // reads back the address it was given, as in Chromium. No icon at all:
  // the address is loaded as it was, and fails as before.
  // A worker's fetch of it too: The Great Suspender's worker fetches its
  // default icons as it starts, and each fetch of a file WebKit doesn't have
  // put "Unable to find "_favicon/" in the extension's resources" on its
  // card (feedback #163).
  const favicons = !inContent && !framed &&
    (() => { try { return (runtime.getManifest().permissions || []).includes("favicon"); } catch (e) { return false; } })();
  const imaged = favicons && typeof document !== "undefined" && typeof HTMLImageElement !== "undefined";
  if (!inContent && favicons) {
    const prefix = runtime.getURL("/_favicon/");
    const asked = (value) => {
      const text = typeof value === "string" ? value : value instanceof URL ? value.href : null;
      return text && (text.startsWith(prefix) || text.startsWith(prefix.slice(0, -1) + "?")) ? text : null;
    };
    const icons = new Map();
    const icon = (url) => {
      let found = icons.get(url);
      if (!found) {
        let page = null, size = 16;
        try { const u = new URL(url); page = u.searchParams.get("pageUrl") || u.searchParams.get("page_url"); size = parseInt(u.searchParams.get("size"), 10) || 16; } catch (e) {}
        found = page ? native("favicon.get", [page, size]).catch(() => null) : Promise.resolve(null);
        icons.set(url, found);
        if (icons.size > 2000) icons.delete(icons.keys().next().value);
      }
      return found;
    };
    const shown = new WeakMap();
    const proto = imaged ? HTMLImageElement.prototype : null;
    const d = proto && Object.getOwnPropertyDescriptor(proto, "src");
    if (d && d.get && d.set) {
      Object.defineProperty(proto, "src", Object.assign({}, d, {
        get() {
          const value = d.get.call(this), was = shown.get(this);
          return was && was.data === value ? was.url : value;
        },
        set(value) {
          const url = asked(value);
          if (!url) { shown.delete(this); return d.set.call(this, value); }
          const was = { url, data: null };
          shown.set(this, was);
          icon(url).then((data) => {
            if (shown.get(this) !== was) return;
            if (typeof data === "string" && data.startsWith("data:image/")) { was.data = data; d.set.call(this, data); }
            else { shown.delete(this); d.set.call(this, url); }
          });
        },
      }));
      const setAttribute = Element.prototype.setAttribute;
      Element.prototype.setAttribute = function (name, value) {
        if (this instanceof HTMLImageElement && String(name).toLowerCase() === "src" && asked(value)) { this.src = value; return; }
        return setAttribute.call(this, name, value);
      };
    }
    if (typeof root.fetch === "function") {
      const fetch = root.fetch;
      root.fetch = function (input, init) {
        const url = asked(input) || (typeof Request === "function" && input instanceof Request ? asked(input.url) : null);
        if (!url) return fetch.apply(this, arguments);
        return icon(url).then((data) => typeof data === "string" && data.startsWith("data:image/") ? fetch.call(root, data) : fetch.call(root, url, init));
      };
    }
  }

  // An agent's tab works in a window no one has in front, where the page
  // never has focus, and a password manager's menu on a field (Bitwarden's
  // inline menu) neither opens nor finds its place until it does. Where
  // Yab marked the page as the one its agent is signing in on, its content
  // scripts are told it has focus, as they would be in front of someone.
  // Only the extension's own world hears it; the page's is untouched.
  // YAB_PORT_TRACE=1 (a diagnosis, evals/feedback-283): each time this
  // shim runs in a page, the extension and when, on the page's root, so a
  // page can count how often an extension's scripts were put into it.
  if (__YAB_PORT_TRACE__ && inContent && typeof document !== "undefined" && document.documentElement && window.top === window) {
    try {
      const root = document.documentElement, was = root.getAttribute("data-yab-ran") || "";
      root.setAttribute("data-yab-ran", (was + " " + String(runtime && runtime.id || "?").slice(0, 4) + "@" + Math.round(performance.now())).slice(-4000));
    } catch (e) {}
  }
  if (inContent && typeof Document !== "undefined" && Document.prototype && typeof Document.prototype.hasFocus === "function") {
    const hasFocus = Document.prototype.hasFocus;
    put(Document.prototype, "hasFocus", function () {
      if (hasFocus.call(this)) return true;
      try { return !!(this.documentElement && this.documentElement.hasAttribute("data-yab-agent-signing-in")); } catch (e) { return false; }
    });
  }

  // NordPass draws its menu on a field in a closed shadow root, which Yab
  // can't read, so Yab's list could only say "Fill with NordPass", even
  // where NordPass has nothing for the site. Its logins are copied onto
  // the menu's host as data-yab-menu ({logins: [[name, detail]]}, an empty
  // list when it offers only other things, {locked: true}); a login Yab
  // writes to data-yab-pick is pressed in it (ManagerMenus). Only the
  // extension's own world is patched.
  if (inContent && typeof Element === "function" && typeof Element.prototype.attachShadow === "function" &&
      typeof MutationObserver === "function") {
    const attach = Element.prototype.attachShadow;
    const text = (e) => (e ? (e.textContent || "").trim() : "");
    put(Element.prototype, "attachShadow", function (init) {
      const shadow = attach.call(this, init);
      if (this.localName !== "nordpass-autofill-portal") return shadow;
      const host = this;
      const rows = () => [...shadow.querySelectorAll('[data-testid="password-item-title"],[data-testid="passkey-item-title"]')].map((title) => {
        const row = title.closest('[role=option],[role=button],button') || title.parentElement;
        const sub = row && row.querySelector('[data-testid="password-item-subtitle"],[data-testid="passkey-item-subtitle"]');
        return { row, lines: [text(title), text(sub)] };
      }).filter((r) => r.lines[0]);
      let said = null, soon = 0;
      const tell = () => {
        soon = 0;
        const found = rows();
        let now = null;
        if (found.length) now = { logins: found.map((r) => r.lines) };
        else if (shadow.querySelector('input[type=password]') || /\bunlock\b|\blocked\b|log in to/i.test(text(shadow.firstElementChild))) now = { locked: true };
        else if (shadow.querySelector('[data-testid="autofill-listbox"],[data-testid="autofill-empty-state"]')) now = { logins: [] };
        if (!now) return;
        const json = JSON.stringify(now);
        if (json !== said) { said = json; host.setAttribute("data-yab-menu", json); }
      };
      new MutationObserver(() => { if (!soon) soon = setTimeout(tell, 60); })
        .observe(shadow, { childList: true, subtree: true, characterData: true });
      new MutationObserver(() => {
        const asked = host.getAttribute("data-yab-pick");
        if (asked === null) return;
        host.removeAttribute("data-yab-pick");
        let want = [];
        try { want = JSON.parse(asked); } catch (e) {}
        const hit = rows().find((r) => r.lines[0] === want[0] && (!want[1] || r.lines[1] === want[1]));
        if (!hit || !hit.row) return;
        const box = hit.row.getBoundingClientRect();
        const at = { bubbles: true, cancelable: true, composed: true, clientX: box.left + 8, clientY: box.top + box.height / 2, button: 0 };
        for (const type of ["pointerdown", "mousedown", "pointerup", "mouseup", "click"])
          hit.row.dispatchEvent(type.startsWith("pointer") ? new PointerEvent(type, at) : new MouseEvent(type, at));
      }).observe(host, { attributes: true, attributeFilter: ["data-yab-pick"] });
      return shadow;
    });
  }

  // What the extension does as the page's DOMContentLoaded fires waits for
  // the page's first frame (two frames, half a second at most). The
  // page's own script runs at the end of its body and DOMContentLoaded
  // right after it, before anything is drawn; 1Password imports its
  // 449 KB injected.js there in every frame, and its compile and run
  // (about 25 ms on m4) came before the new tab's first frame
  // (docs/evidence/night-extensions-2026-10-14.md). Only this extension's
  // world is patched; the page's listeners are untouched and run as they
  // did. YAB_CONTENT_DCL=now: at once, as before.
  if (inContent && __YAB_DCL_LATE__ && typeof EventTarget === "function" && typeof document !== "undefined" &&
      document.readyState === "loading" && typeof requestAnimationFrame === "function") {
    const add = EventTarget.prototype.addEventListener, remove = EventTarget.prototype.removeEventListener;
    const wrapped = new WeakMap();
    let drawn = false;
    const queue = [];
    const flush = () => {
      if (drawn) return;
      drawn = true;
      for (const run of queue.splice(0)) { try { run(); } catch (e) { setTimeout(() => { throw e; }); } }
    };
    add.call(document, "DOMContentLoaded", () => {
      requestAnimationFrame(() => requestAnimationFrame(() => setTimeout(flush, 0)));
      setTimeout(flush, 500);
    }, { once: true });
    const late = (listener) => {
      let w = wrapped.get(listener);
      if (!w) {
        w = function (event) {
          const self = this;
          const call = () => typeof listener === "function" ? listener.call(self, event) : listener.handleEvent(event);
          if (drawn) return call();
          queue.push(call);
        };
        wrapped.set(listener, w);
      }
      return w;
    };
    const ours = (target, type, listener) => type === "DOMContentLoaded" && !drawn && listener &&
      (typeof listener === "function" || typeof listener.handleEvent === "function") &&
      (target === document || target === window);
    put(EventTarget.prototype, "addEventListener", function (type, listener, options) {
      return add.call(this, type, ours(this, type, listener) ? late(listener) : listener, options);
    });
    put(EventTarget.prototype, "removeEventListener", function (type, listener, options) {
      if (type === "DOMContentLoaded" && listener && wrapped.has(listener)) remove.call(this, type, wrapped.get(listener), options);
      return remove.call(this, type, listener, options);
    });
  }

  // Several onMessage listeners: WebKit takes the first one's return,
  // usually undefined, as the answer, where Chrome waits for whichever
  // calls sendResponse or returns true. So the extension's listeners are
  // gathered behind a single one of WebKit's that follows Chrome's rule.
  const worker = typeof ServiceWorkerGlobalScope !== "undefined" && root instanceof ServiceWorkerGlobalScope;
  // The extension's background, whichever WebKit runs: the worker, or a
  // page, it picks the page when a manifest names scripts as well.
  const background = worker || (!inContent && typeof document !== "undefined" && (() => {
    try { return chrome.extension && typeof chrome.extension.getBackgroundPage === "function" && chrome.extension.getBackgroundPage() === root; }
    catch (e) { return false; }
  })());
  // A script a worker imports that isn't there: Chrome throws at once.
  // WebKit goes looking for it first, and while it does, runs the
  // promises already waiting, code that notes "still starting" until
  // its first promise settles (Tampermonkey) then thinks startup is
  // over, and refuses its own listeners. The extension's files are
  // known, so a missing one is refused the way Chromium refuses it, and
  // an empty one, Tampermonkey's test.js, isn't fetched at all.
  // The static routing API of Chrome's service workers (install
  // event.addRoutes), a speed-up, so nothing is lost without it.
  if (worker && typeof root.InstallEvent === "function" && !InstallEvent.prototype.addRoutes) {
    InstallEvent.prototype.addRoutes = () => Promise.resolve();
  }
  // Chrome's extension pages are its worker's clients and talk to it with
  // postMessage. WebKit's aren't: clients.matchAll() lists none of them,
  // and what a page posts to navigator.serviceWorker's worker never
  // reaches the extension's. Zotero Connector's offscreen document hands
  // its worker a MessagePort so (offscreen.js), then the worker finds it
  // with matchAll; not found, it makes another and is refused ("Only a
  // single offscreen document may be created"), and its requests come
  // back undefined (feedback #404). So the offscreen document is listed
  // as a client, and both ways go as runtime messages only this shim
  // takes (`__yabClients`, in `gather`, which
  // listens for them in a page with no listener of its own too), a page's ports with them: the
  // page keeps the real port, the worker gets one that relays.
  const sendClients = (() => {
    const send = chrome.runtime && chrome.runtime.sendMessage;
    const ports = new Map(), closed = new Set(), retired = new Set();
    const clients = new Map(), waiting = new Map(), owners = new Map();
    const documentID = root.crypto && typeof root.crypto.randomUUID === "function"
      ? root.crypto.randomUUID() : Date.now().toString(36) + "-" + Math.random().toString(36).slice(2);
    const base = chrome.runtime.getURL("");
    let workerURL = null, next = 0, dead = false;
    try { workerURL = chrome.runtime.getURL(chrome.runtime.getManifest().background.service_worker); } catch (e) {}
    const say = (said) => {
      if (dead) return;
      try { Promise.resolve(send.call(chrome.runtime, { __yabClients: { ...said, owner: documentID } })).catch(() => {}); } catch (e) {}
    };
    const peer = (said, sender) => {
      if (dead || !sender || sender.id !== chrome.runtime.id || typeof sender.url !== "string") return null;
      // WebKit reports a service worker's sender as its bare extension
      // origin, without a path or frame. Canonicalize only that native
      // worker shape to the worker declared by this extension. A page,
      // tab or subframe must still identify its actual document.
      const originOnlyWorker = workerURL && sender.url === base.replace(/\/$/, "") &&
        sender.tab == null && (sender.frameId == null || sender.frameId === -1);
      const url = originOnlyWorker ? workerURL : sender.url;
      if (!url.startsWith(base) ||
          (sender.frameId != null && sender.frameId !== 0 && !(url === workerURL && sender.frameId === -1)) ||
          typeof said.owner !== "string" || !/^[a-zA-Z0-9.-]{1,128}$/.test(said.owner) || retired.has(said.owner) ||
          (said.toOwner !== undefined && said.toOwner !== documentID)) return null;
      const from = { owner: said.owner, url, tab: sender.tab?.id ?? -1,
        // A document keeps its identity through history.replaceState. Stylus
        // changes its installer hash into ?updateUrl before asking to compile.
        // Without a native document id, pin the path but allow query/hash changes.
        key: JSON.stringify([sender.id, base, sender.documentId ? null : url.split(/[?#]/)[0],
          sender.tab?.id ?? -1, sender.frameId ?? -1, sender.documentId ?? ""]) };
      if (owners.has(from.owner) && owners.get(from.owner) !== from.key) return null;
      owners.set(from.owner, from.key);
      return from;
    };
    const same = (a, b) => a.owner === b.owner && a.key === b.key;
    const bind = (record, from) => {
      if (record.peer) return same(record.peer, from);
      if (!record.expected || record.expected.url !== from.url || (record.expected.worker && from.tab !== -1) ||
          (record.expected.tab !== undefined && record.expected.tab !== from.tab)) return false;
      record.peer = from;
      return true;
    };
    const close = (id) => {
      const record = ports.get(id);
      if (!record) return false;
      ports.delete(id);
      closed.add(id);
      record.port.close();
      return true;
    };
    const keep = (port, id, from, expected) => {
      const record = { port, peer: from, expected };
      ports.set(id, record);
      port.onmessage = (event) => {
        if (ports.get(id) !== record) return;
        say({ [worker ? "toPort" : "port"]: id, toOwner: record.peer?.owner,
          ...pack(event.data, event.ports, record.peer || record.expected) });
      };
      return id;
    };
    // runtime messages cannot carry native ports. Move their ownership here,
    // then bridge them to real local MessageChannels in the receiving realm.
    // The reference paths keep {res: port} identical to event.ports[0].
    const pack = (data, transfer, expected) => {
      const list = Array.isArray(transfer) ? transfer : (transfer && Array.isArray(transfer.transfer) ? transfer.transfer : []);
      let given = list.filter((port) => port instanceof MessagePort);
      if (new Set(given).size !== given.length) throw new DOMException("Duplicate MessagePort", "DataCloneError");
      const references = [], walking = new Set();
      const copy = (value, path) => {
        if (value instanceof MessagePort) {
          const index = given.indexOf(value);
          if (index < 0) throw new DOMException("MessagePort must be transferred", "DataCloneError");
          references.push([path, index]);
          return null;
        }
        if (!value || typeof value !== "object" || (!Array.isArray(value) && Object.prototype.toString.call(value) !== "[object Object]")) return value;
        if (walking.has(value)) throw new DOMException("Cyclic runtime message", "DataCloneError");
        const result = Array.isArray(value) ? [] : Object.create(null);
        walking.add(value);
        for (const key of Object.keys(value)) Object.defineProperty(result, key, {
          value: copy(value[key], path.concat(key)), writable: true, enumerable: true, configurable: true,
        });
        walking.delete(value);
        return result;
      };
      const copied = copy(data, []);
      // Validate the whole payload before moving any endpoint or changing
      // the registry. Runtime's wire is JSON; the port itself moves natively.
      if (given.length) ({ given } = structuredClone({ data, given }, { transfer: given }));
      return { data: copied, ports: given.map((port) => keep(port, documentID + "#" + next++,
        expected?.owner ? expected : null, expected)), portRefs: references };
    };
    const read = (said, from) => {
      const list = said.ports || [], refs = said.portRefs || [];
      if (!Array.isArray(list) || !Array.isArray(refs) || new Set(list).size !== list.length ||
          list.some((id) => typeof id !== "string" || !id.startsWith(from.owner + "#") || ports.has(id) || closed.has(id))) return null;
      // Validate before allocating endpoints or replacing data properties.
      for (const ref of refs) {
        if (!Array.isArray(ref) || ref.length !== 2 || !Array.isArray(ref[0]) ||
            ref[0].some((key) => typeof key !== "string") || !Number.isInteger(ref[1]) || ref[1] < 0 || ref[1] >= list.length) return null;
        let value = said.data;
        for (const key of ref[0]) {
          if (!value || typeof value !== "object" || !Object.prototype.hasOwnProperty.call(value, key)) return null;
          value = value[key];
        }
      }
      const transferred = list.map((id) => {
        const channel = new MessageChannel();
        keep(channel.port2, id, from);
        say({ portAck: id, toOwner: from.owner });
        return channel.port1;
      });
      let data = said.data;
      for (const [path, index] of refs) {
        if (!path.length) { data = transferred[index]; continue; }
        let parent = data;
        for (const key of path.slice(0, -1)) parent = parent[key];
        Object.defineProperty(parent, path[path.length - 1], {
          value: transferred[index], writable: true, enumerable: true, configurable: true,
        });
      }
      return { data, ports: transferred };
    };
    const retire = (from) => {
      retired.add(from.owner);
      if (clients.get(from.url)?.owner === from.owner) clients.delete(from.url);
      for (const [id, record] of ports) if (record.peer && same(record.peer, from)) close(id);
    };
    say.pack = pack;
    say.read = read;
    say.peer = peer;
    say.worker = { url: workerURL, worker: true };
    say.control = (said, from) => {
      if (said.goodbye) { retire(from); return true; }
      if (worker && said.hello && from.tab === -1) {
        const old = clients.get(from.url);
        if (old && !same(old, from)) retire(old);
        clients.set(from.url, from);
        for (const packet of waiting.get(from.url) || []) say({ to: from.url, toOwner: from.owner, ...packet });
        waiting.delete(from.url);
        return true;
      }
      if (said.portAck !== undefined || said.closePort !== undefined) {
        const id = said.portAck ?? said.closePort, record = ports.get(id);
        if (!record || !bind(record, from)) return false;
        if (said.closePort !== undefined) close(id);
        return true;
      }
      return false;
    };
    say.deliver = (id, said, from) => {
      const record = ports.get(id);
      if (!record || !bind(record, from)) return false;
      const value = read(said, from);
      if (!value) return false;
      record.port.postMessage(value.data, value.ports);
      return true;
    };
    say.client = (url, data, transfer) => {
      const from = clients.get(url), packet = pack(data, transfer, from || { url, tab: -1 });
      if (from) say({ to: url, toOwner: from.owner, ...packet });
      else {
        if (!waiting.has(url)) waiting.set(url, []);
        waiting.get(url).push(packet);
        say({ discover: url });
      }
    };
    const shutdown = () => {
      dead = true;
      for (const id of ports.keys()) close(id);
      root.__yabClientsMessage = () => false;
    };
    let wrappedClose;
    say.installClose = () => {
      if (!worker || typeof chrome.offscreen?.closeDocument !== "function" || chrome.offscreen.closeDocument === wrappedClose) return;
      const nativeClose = chrome.offscreen.closeDocument;
      wrappedClose = function (...args) {
        // A replacement may open while native close waits. Retire only the
        // exact realms captured before that call, and only after it succeeds.
        const captured = [...clients.values()];
        const result = nativeClose.apply(this, args);
        if (!result || typeof result.then !== "function") return result;
        return result.then((value) => {
          for (const from of captured) {
            retire(from);
            say({ retireOwner: from.owner, toOwner: from.owner });
          }
          return value;
        });
      };
      put(chrome.offscreen, "closeDocument", wrappedClose);
    };
    say.shutdown = shutdown;
    say.installClose();
    if (!worker && typeof root.addEventListener === "function") root.addEventListener("pagehide", (event) => {
      if (event.persisted) return;
      say({ goodbye: true });
      shutdown();
    });
    return say;
  })();
  if (worker && typeof root.Clients === "function" && typeof Clients.prototype.matchAll === "function") {
    const matchAll = Clients.prototype.matchAll;
    root.__yabClientsMessage = (said, sender) => {
      const from = sendClients.peer(said, sender);
      if (!from) return false;
      if (sendClients.control(said, from)) return true;
      if (said.port !== undefined) return sendClients.deliver(said.port, said, from);
      if (!said.post) return false;
      const value = sendClients.read(said.post, from);
      if (!value) return false;
      const event = new Event("message");
      Object.defineProperties(event, {
        data: { value: value.data }, origin: { value: location.origin },
        ports: { value: Object.freeze(value.ports) },
      });
      root.dispatchEvent(event);
      return true;
    };
    put(Clients.prototype, "matchAll", async function (options) {
      const found = Array.from(await matchAll.call(this, options));
      if (options && options.type && options.type !== "window" && options.type !== "all") return found;
      let pages = [];
      try { pages = (await chrome.runtime.getContexts({ contextTypes: ["OFFSCREEN_DOCUMENT"] })) || []; } catch (e) {}
      const listed = new Set(found.map((client) => client.url));
      for (const page of pages) {
        const url = page.documentUrl;
        if (!url || listed.has(url)) continue;
        found.push(Object.freeze({
          url, id: "yab-" + page.contextId, type: "window", frameType: "top-level",
          postMessage(data, transfer) { sendClients.client(url, data, transfer); },
        }));
      }
      return found;
    });
  }
  // A normal extension page can hand its background worker a port too
  // (Stylus's manager waits on one before binding Import). Relay only to
  // the worker named by this extension's manifest; another worker keeps
  // WebKit's native postMessage. Offscreen clients keep their route.
  if (!inContent && !worker && typeof document !== "undefined" && root.navigator && navigator.serviceWorker && typeof root.ServiceWorker === "function") {
    const workerURL = (() => {
      try {
        const path = chrome.runtime.getManifest().background.service_worker;
        return typeof path === "string" && path ? chrome.runtime.getURL(path) : null;
      } catch (e) { return null; }
    })();
    const route = (said, sender) => {
      const from = sendClients.peer(said, sender);
      if (!from || from.url !== workerURL || from.tab !== -1) return false;
      if (sendClients.control(said, from)) return true;
      if (said.retireOwner === undefined && said.discover === location.href) {
        offscreen.then((yes) => { if (yes) sendClients({ hello: true }); });
        return true;
      }
      if (said.retireOwner !== undefined) {
        if (said.retireOwner !== said.toOwner) return false;
        sendClients.shutdown();
        return true;
      }
      if (said.toPort !== undefined) return sendClients.deliver(said.toPort, said, from);
      if (said.to !== location.href) return false;
      const value = sendClients.read(said, from);
      if (!value) return false;
      navigator.serviceWorker.ready.then((registration) => {
        let event;
        try { event = new MessageEvent("message", { ...value, source: registration.active }); }
        catch (e) { event = new MessageEvent("message", value); }
        navigator.serviceWorker.dispatchEvent(event);
      });
      return true;
    };
    // runtime.getContexts is this shim's, set further down: asked once it is.
    const asked = async () => {
      try {
        const pages = await chrome.runtime.getContexts({ contextTypes: ["OFFSCREEN_DOCUMENT"] });
        return (pages || []).some((page) => page.documentUrl === location.href);
      } catch (e) { return false; }
    };
    // While it loads the native side may not know its address yet.
    const offscreen = (async () => {
      for (let i = 0; i < 20; i++) {
        if (await asked()) return true;
        await new Promise((done) => setTimeout(done, i < 5 ? 50 : 250));
      }
      return false;
    })();
    const attach = (announce = false) => {
      root.__yabClientsMessage = route;
      if (announce) sendClients({ hello: true });
      if (typeof root.__yabClientsAttach === "function") root.__yabClientsAttach();
    };
    offscreen.then((yes) => { if (yes) attach(true); });
    const relay = (data, transfer) => {
      attach();
      sendClients({ post: sendClients.pack(data, transfer, sendClients.worker) });
    };
    const post = ServiceWorker.prototype.postMessage;
    put(ServiceWorker.prototype, "postMessage", function (data, transfer) {
      const target = this;
      if (workerURL && target.scriptURL === workerURL) { relay(data, transfer); return; }
      offscreen.then((yes) => {
        if (yes) relay(data, transfer);
        else post.call(target, data, transfer);
      });
    });
  }
  // WebKit runs an extension's worker on its web process's main thread,
  // and a worker's WebSocket waits there for the main thread to set up
  // its channel, for itself, for ever: the worker and every page of the
  // extension freeze. 1Password opens one as a sign-in succeeds. So a
  // worker's socket is made by the browser (ExtensionSocket.swift) and
  // its frames come and go over a native port.
  if (worker && typeof root.WebSocket === "function" && runtime && typeof runtime.connectNative === "function") {
    const connectNative = runtime.connectNative.bind(runtime);
    const encode = (bytes) => { let s = ""; for (let i = 0; i < bytes.length; i += 0x8000) s += String.fromCharCode.apply(null, bytes.subarray(i, i + 0x8000)); return btoa(s); };
    const decode = (text) => { const s = atob(text), bytes = new Uint8Array(s.length); for (let i = 0; i < s.length; i++) bytes[i] = s.charCodeAt(i); return bytes.buffer; };
    const states = { CONNECTING: 0, OPEN: 1, CLOSING: 2, CLOSED: 3 };
    class WebSocket extends EventTarget {
      #port; #state = 0; #queue = Promise.resolve(); #origin; #hello;
      constructor(url, protocols) {
        super();
        let parsed;
        try { parsed = new URL(url, location.href); } catch (e) { throw new DOMException("The URL '" + url + "' is invalid.", "SyntaxError"); }
        if (parsed.protocol === "http:") parsed.protocol = "ws:";
        if (parsed.protocol === "https:") parsed.protocol = "wss:";
        if (!/^wss?:$/.test(parsed.protocol) || parsed.hash) throw new DOMException("The URL '" + url + "' is invalid.", "SyntaxError");
        const list = protocols === undefined ? [] : (Array.isArray(protocols) ? protocols : [protocols]).map(String);
        Object.defineProperty(this, "url", { value: parsed.href, enumerable: true });
        this.#origin = parsed.origin;
        this.protocol = ""; this.extensions = ""; this.binaryType = "blob"; this.bufferedAmount = 0;
        this.onopen = null; this.onmessage = null; this.onerror = null; this.onclose = null;
        this.#hello = { open: this.url, protocols: list, userAgent: navigator.userAgent };
        this.#connect();
      }
      // WebKit drops what a worker posts on a port it has only just
      // opened, without a word either way. So the opening is said again,
      // on the same port, until the browser says it heard it: its word
      // that the port has arrived isn't enough, the opening sent before
      // it can still have been lost, and the socket would wait for ever.
      #connect() {
        const port = connectNative("yab.socket");
        let heard = false, tries = 0;
        this.#port = port;
        const again = () => {
          if (heard || this.#state === 3) return;
          if (tries++ >= 20) { this.#fire("error"); this.#closed(1006, "", false); return; }
          try { port.postMessage(this.#hello); } catch (e) {}
          setTimeout(again, 100 * Math.min(tries, 5));
        };
        port.onMessage.addListener((m) => {
          if (m && m.ready === true) { if (m.heard) heard = true; return; }
          heard = true;
          this.#take(m);
        });
        port.onDisconnect.addListener(() => {
          if (this.#state === 3) return;
          this.#fire("error");
          this.#closed(1006, "", false);
        });
        again();
      }
      get readyState() { return this.#state; }
      #fire(type, init) {
        let event;
        if (type === "message") event = new MessageEvent("message", init);
        else if (type === "close" && typeof CloseEvent === "function") event = new CloseEvent("close", init);
        else { event = new Event(type); if (init) for (const k in init) Object.defineProperty(event, k, { value: init[k] }); }
        const handler = this["on" + type];
        if (typeof handler === "function") { try { handler.call(this, event); } catch (e) { setTimeout(() => { throw e; }); } }
        this.dispatchEvent(event);
      }
      #closed(code, reason, wasClean) {
        this.#state = 3;
        try { this.#port.disconnect(); } catch (e) {}
        this.#fire("close", { code, reason, wasClean });
      }
      #take(m) {
        if (!m || this.#state === 3) return;
        if ("opened" in m) { this.protocol = m.opened; this.#state = 1; this.#fire("open"); }
        else if ("text" in m) this.#fire("message", { data: m.text, origin: this.#origin });
        else if ("binary" in m) {
          const buffer = decode(m.binary);
          this.#fire("message", { data: this.binaryType === "arraybuffer" ? buffer : new Blob([buffer]), origin: this.#origin });
        }
        else if ("failed" in m) this.#fire("error");
        else if ("closed" in m) this.#closed(m.closed, m.reason || "", !!m.clean);
      }
      send(data) {
        if (this.#state === 0) throw new DOMException("WebSocket is still in CONNECTING state.", "InvalidStateError");
        if (this.#state !== 1) return;
        const post = (message) => { try { this.#port.postMessage(message); } catch (e) {} };
        if (typeof data === "string") { this.#queue = this.#queue.then(() => post({ send: data })); return; }
        const bytes = data instanceof ArrayBuffer ? Promise.resolve(new Uint8Array(data))
          : ArrayBuffer.isView(data) ? Promise.resolve(new Uint8Array(data.buffer, data.byteOffset, data.byteLength))
          : data instanceof Blob ? data.arrayBuffer().then((b) => new Uint8Array(b))
          : Promise.resolve(null);
        this.#queue = this.#queue.then(() => bytes).then((b) => b ? post({ sendBinary: encode(b) }) : post({ send: String(data) }));
      }
      close(code, reason) {
        if (code !== undefined && code !== 1000 && !(code >= 3000 && code <= 4999)) {
          throw new DOMException("The close code must be either 1000, or between 3000 and 4999. " + code + " is neither.", "InvalidAccessError");
        }
        if (this.#state >= 2) return;
        this.#state = 2;
        const message = { close: code === undefined ? 1000 : code, reason: reason === undefined ? "" : String(reason) };
        this.#queue = this.#queue.then(() => { try { this.#port.postMessage(message); } catch (e) {} });
      }
    }
    for (const [k, v] of Object.entries(states)) { Object.defineProperty(WebSocket, k, { value: v }); Object.defineProperty(WebSocket.prototype, k, { value: v }); }
    Object.defineProperty(root, "WebSocket", { value: WebSocket, configurable: true, writable: true });
  }
  // A site's own cookies on an extension's request to it. Chrome makes a
  // request to a host the extension's permissions reach as the site's
  // own, its cookies sent unless credentials are "omit", SameSite=Lax and
  // Strict too; WebKit takes chrome-extension:// for another site and
  // leaves those out. Claude's side panel asks claude.ai with credentials
  // "include", got no account (its sessionKey is Lax), and asked to sign
  // in for ever. So such a fetch or XHR is offered to the browser
  // (ExtensionFetch.swift), which makes it when the site has a SameSite
  // cookie and otherwise answers "native": made here, as before. A host
  // the extension may not reach is remembered and never offered again
  // until its permissions change; fetches with credentials "omit", to the
  // extension's own files, or from content scripts never leave here.
  if (!inContent && !framed && typeof root.fetch === "function" && typeof Request === "function" && typeof ReadableStream === "function") {
    const nativeFetch = root.fetch;
    const { Headers, ReadableStream, TypeError, Uint8Array, JSON } = root;
    const encode = (bytes) => { let s = ""; for (let i = 0; i < bytes.length; i += 0x8000) s += String.fromCharCode.apply(null, bytes.subarray(i, i + 0x8000)); return btoa(s); };
    const decode = (text) => { const s = atob(text), bytes = new Uint8Array(s.length); for (let i = 0; i < s.length; i++) bytes[i] = s.charCodeAt(i); return bytes; };
    const aborted = (signal) => signal && signal.reason !== undefined ? signal.reason : new DOMException("The operation was aborted.", "AbortError");
    const failed = () => new TypeError("Load failed");
    // Origins the browser said this extension may not reach.
    const unreached = new Set();
    try {
      for (const name of ["onAdded", "onRemoved"]) chrome.permissions[name].addListener(() => unreached.clear());
    } catch (e) {}
    const site = (address) => {
      try {
        const u = new URL(address, location.href);
        return /^https?:$/.test(u.protocol) && u.origin !== location.origin && !unreached.has(u.origin) ? u.href : null;
      } catch (e) { return null; }
    };
    // The request through the browser, or null when it says to make it here.
    const viaBrowser = async (request) => {
      const signal = request.signal;
      if (signal && signal.aborted) throw aborted(signal);
      const bytes = request.method === "GET" || request.method === "HEAD" ? null : new Uint8Array(await request.clone().arrayBuffer());
      const head = await native("sitefetch.start", [{
        url: request.url, method: request.method, headers: [...request.headers],
        body: bytes && bytes.length ? encode(bytes) : null, userAgent: navigator.userAgent,
      }]).catch(() => null);
      // An app that can't take it (an older one): made here, as before.
      if (!head || head.native) {
        if (head && head.unreached) { try { unreached.add(new URL(request.url).origin); } catch (e) {} }
        return null;
      }
      if (head.failed) throw failed();
      const id = head.id;
      let done = false;
      const cancel = () => { if (!done) { done = true; native("sitefetch.cancel", [id]).catch(() => {}); } };
      if (signal && signal.aborted) { cancel(); throw aborted(signal); }
      if (signal) signal.addEventListener("abort", cancel, { once: true });
      const empty = request.method === "HEAD" || [101, 204, 205, 304].includes(head.status);
      if (empty) cancel();
      const body = empty ? null : new ReadableStream({
        pull: (controller) => native("sitefetch.read", [id]).then((piece) => {
          if (signal && signal.aborted) { controller.error(aborted(signal)); return; }
          if (piece && piece.error) { done = true; controller.error(failed()); return; }
          if (piece && piece.chunk) controller.enqueue(decode(piece.chunk));
          if (!piece || piece.done) { done = true; controller.close(); }
        }, () => { done = true; controller.error(failed()); }),
        cancel,
      });
      const response = new Response(body, { status: head.status, statusText: head.statusText || "", headers: new Headers(head.headers || []) });
      for (const [key, value] of [["url", head.url], ["redirected", !!head.redirected], ["type", "cors"]]) {
        try { Object.defineProperty(response, key, { value, enumerable: true }); } catch (e) {}
      }
      return response;
    };
    const credentials = (input, init) => init && init.credentials !== undefined ? init.credentials : (input instanceof Request ? input.credentials : "same-origin");
    const fetch = function fetch(input, init) {
      let address;
      try { address = credentials(input, init) !== "omit" && site(input instanceof Request ? input.url : String(input)); } catch (e) { address = null; }
      if (!address) return nativeFetch.apply(root, arguments);
      let request;
      try { request = new Request(input, init); } catch (e) { return nativeFetch.apply(root, arguments); }
      // Another redirect mode wants the redirect itself, not followed.
      if (request.redirect !== "follow") return nativeFetch.call(root, request);
      return viaBrowser(request).then((response) => response || nativeFetch.call(root, request));
    };
    try { Object.defineProperty(root, "fetch", { value: fetch, configurable: true, writable: true, enumerable: true }); } catch (e) {}

    // The same for an XHR, in a page (a worker has none), with or without
    // withCredentials, as Chromium's carries cookies either way to such a
    // host: its answer is set on the request itself, over WebKit's.
    const XHR = root.XMLHttpRequest;
    if (typeof XHR === "function" && typeof document !== "undefined") {
      const proto = XHR.prototype, open = proto.open, send = proto.send, setHeader = proto.setRequestHeader;
      const asked = new WeakMap();
      const answered = ["readyState", "status", "statusText", "responseURL", "response", "responseText", "responseXML", "getResponseHeader", "getAllResponseHeaders", "abort"];
      put(proto, "open", function (method, url, async) {
        for (const key of answered) { try { delete this[key]; } catch (e) {} }
        asked.set(this, { method: String(method).toUpperCase(), url: String(url), async: arguments.length < 3 || !!async, headers: [] });
        return open.apply(this, arguments);
      });
      put(proto, "setRequestHeader", function (name, value) {
        const a = asked.get(this);
        if (a) a.headers.push([String(name), String(value)]);
        return setHeader.apply(this, arguments);
      });
      put(proto, "send", function (body) {
        const a = asked.get(this);
        const address = a && a.async && site(a.url);
        if (!address) return send.apply(this, arguments);
        const xhr = this, controller = new AbortController();
        let request;
        try {
          const payload = body === undefined || body === null || a.method === "GET" || a.method === "HEAD" ? undefined
            : (typeof Document === "function" && body instanceof Document ? new XMLSerializer().serializeToString(body) : body);
          request = new Request(address, { method: a.method, headers: a.headers, body: payload, credentials: "include", signal: controller.signal });
        } catch (e) { return send.apply(this, arguments); }
        let state = 1, status = 0, statusText = "", headers = null, url = "", value = null, text = "", over = false;
        const fire = (type, loaded, total) => {
          let event;
          try { event = type === "readystatechange" ? new Event(type) : new ProgressEvent(type, { loaded: loaded || 0, total: total || 0, lengthComputable: !!total }); }
          catch (e) { event = new Event(type); }
          const handler = xhr["on" + type];
          if (typeof handler === "function") { try { handler.call(xhr, event); } catch (e) { setTimeout(() => { throw e; }); } }
          xhr.dispatchEvent(event);
        };
        const move = (to) => { state = to; fire("readystatechange"); };
        const define = () => {
          const own = (key, get) => { try { Object.defineProperty(xhr, key, { get, configurable: true }); } catch (e) {} };
          own("readyState", () => state); own("status", () => status); own("statusText", () => statusText);
          own("responseURL", () => url); own("response", () => value); own("responseXML", () => xhr.responseType === "document" ? value : null);
          own("responseText", () => {
            if (xhr.responseType !== "" && xhr.responseType !== "text") throw new DOMException("responseText is only available if responseType is '' or 'text'.", "InvalidStateError");
            return text;
          });
          const put2 = (key, f) => { try { Object.defineProperty(xhr, key, { value: f, configurable: true, writable: true }); } catch (e) {} };
          put2("getResponseHeader", (name) => headers && state >= 2 ? headers.get(name) : null);
          put2("getAllResponseHeaders", () => {
            if (!headers || state < 2) return "";
            let all = ""; headers.forEach((v, k) => { all += k + ": " + v + "\r\n"; }); return all;
          });
          put2("abort", () => {
            if (over) return;
            over = true; controller.abort();
            status = 0; statusText = ""; value = null; text = "";
            if (state > 1) move(4);
            state = 0;
            fire("abort"); fire("loadend");
          });
        };
        const fail = (type) => {
          if (over) return;
          over = true; status = 0; statusText = ""; value = null; text = "";
          move(4); fire(type); fire("loadend");
        };
        define();
        const timer = xhr.timeout > 0 ? setTimeout(() => { controller.abort(); fail("timeout"); }, xhr.timeout) : null;
        viaBrowser(request).then(async (response) => {
          if (over) return;
          if (!response) {
            // Not a host of this extension's: WebKit's own, as before.
            clearTimeout(timer);
            for (const key of answered) { try { delete xhr[key]; } catch (e) {} }
            return send.call(xhr, body);
          }
          fire("loadstart");
          status = response.status; statusText = response.statusText; headers = response.headers; url = response.url;
          move(2);
          const bytes = new Uint8Array(await response.arrayBuffer());
          clearTimeout(timer);
          if (over) return;
          move(3);
          const type = xhr.responseType, mime = (headers.get("content-type") || "").split(";")[0].trim();
          if (type === "" || type === "text") { text = new TextDecoder().decode(bytes); value = text; }
          else if (type === "json") { try { value = JSON.parse(new TextDecoder().decode(bytes)); } catch (e) { value = null; } }
          else if (type === "arraybuffer") value = bytes.buffer;
          else if (type === "blob") value = new Blob([bytes], { type: mime });
          else if (type === "document") { try { value = new DOMParser().parseFromString(new TextDecoder().decode(bytes), /xml/.test(mime) ? mime : "text/html"); } catch (e) { value = null; } }
          fire("progress", bytes.length, bytes.length);
          over = true;
          move(4);
          fire("load", bytes.length, bytes.length); fire("loadend", bytes.length, bytes.length);
        }).catch(() => { clearTimeout(timer); fail("error"); });
      });
    }
  }
  // The same loss meets a worker's port to an app on the Mac: what it
  // posts in its first moments never reaches the app, and comes back to
  // the worker's own listeners instead. iCloud Passwords says hello to
  // its helper that way, and without the helper's answer asks for the
  // code again and again. So on such a port, what the extension posts
  // is held from its first message until the browser says the port has
  // arrived, asked on the same port, as the socket asks, and then sent
  // in order. WebKit won't let connectNative be replaced in a worker, so
  // this is done on what every port shares, found through a port to the
  // browser itself; the question and the answer are kept from the
  // extension's listeners, and never reach the app.
  if (worker && runtime && typeof runtime.connectNative === "function") {
    let found = null;
    try { found = runtime.connectNative("yab"); found.disconnect(); } catch (e) {}
    const portProto = found && Object.getPrototypeOf(found);
    const eventProto = found && found.onMessage && Object.getPrototypeOf(found.onMessage);
    if (portProto && eventProto && typeof portProto.postMessage === "function" && typeof eventProto.addListener === "function") {
      // Ports that go to the extension's own pages or tabs, not an app.
      const toPages = new WeakSet();
      for (const [space, name] of [[runtime, "connect"], [chrome.tabs, "connect"]]) {
        const connect = space && space[name];
        if (typeof connect !== "function") continue;
        put(space, name, (...args) => { const port = connect.apply(space, args); try { toPages.add(port); } catch (e) {} return port; });
      }
      const post = portProto.postMessage, add = eventProto.addListener, remove = eventProto.removeListener, has = eventProto.hasListener;
      const ours = (m) => !!m && typeof m === "object" && "__yabNative" in m;
      // Ports seen, each with what waits to be sent (null once it may go).
      const ports = new WeakMap();
      const start = (port) => {
        const state = { held: [] };
        let tries = 0;
        const flush = () => { const list = state.held; state.held = null; for (const m of list || []) post.call(port, m); };
        const again = () => {
          if (!state.held) return;
          // Unanswered, they go anyway: no worse than before.
          if (tries++ >= 20) { flush(); return; }
          try { post.call(port, { __yabNative: "here?" }); } catch (e) {}
          setTimeout(again, 100 * Math.min(tries, 5));
        };
        add.call(port.onMessage, (m) => {
          if (m && m.__yabNative === "here" && state.held) flush();
          // WebKit keeps a worker only while it has posted on an open
          // port in the last two minutes; what arrives on one doesn't
          // count. The browser's word now and then is answered on the
          // port, so a worker holding a port to an app stays, as in
          // Chrome, iCloud Passwords otherwise forgets it was paired.
          if (m && m.__yabNative === "alive") { try { post.call(port, { __yabNative: "beat" }); } catch (e) {} }
        });
        add.call(port.onDisconnect, () => { state.held = null; });
        again();
        return state;
      };
      put(portProto, "postMessage", function (message) {
        let state = ports.get(this);
        if (!state) {
          const native = !toPages.has(this) && this.sender == null && typeof this.name === "string" && !/^yab(\.|$)/.test(this.name);
          state = native ? start(this) : { held: null };
          ports.set(this, state);
        }
        if (state.held) { state.held.push(message); return; }
        return post.call(this, message);
      });
      // A port's listeners, and only a port's (the namespaces' own
      // events are kept as they are), each behind one that lets the
      // question and the answer pass by.
      const wrapped = new WeakMap();
      const gone = new WeakMap();
      // A port let go of from inside its own onMessage, as 1Password's
      // worker lets go of its app's port on the app's first word ("won't
      // talk to this browser"), takes the worker's whole process down on
      // macOS 26.4.1 and 26.5: WebKit's web process goes on with the port
      // it was handing the message to (WebExtensionContextProxy::
      // dispatchPortMessageEvent, SIGSEGV at 0x18). The next event starts
      // the worker again, it asks the app again, and so on, a new process
      // a second, the extension never up (feedback #140). So a disconnect
      // asked for while a message is being heard, or in what that listener
      // set going before it returned, waits for the next task.
      let hearing = 0;
      const heard = (call) => {
        hearing++;
        try { return call(); } finally { setTimeout(() => { hearing--; }, 0); }
      };
      const disconnect = portProto.disconnect;
      if (typeof disconnect === "function") {
        put(portProto, "disconnect", function (...args) {
          if (!hearing) return disconnect.apply(this, args);
          const port = this;
          setTimeout(() => { try { disconnect.apply(port, args); } catch (e) {} }, 0);
        });
      }
      const wrapper = (event, f, make) => {
        let byEvent = wrapped.get(event);
        if (!byEvent) { byEvent = new Map(); if (make) wrapped.set(event, byEvent); }
        let w = byEvent.get(f);
        if (!w && make) {
          w = function (m, ...rest) {
            if (ours(m)) {
              // Why the browser is about to let go of an app's port
              // (ExtensionNative.end), kept for its onDisconnect.
              if (m.__yabNative === "gone" && rest[0] && typeof rest[0] === "object") gone.set(rest[0], String(m.why || ""));
              return;
            }
            // A port to an app that isn't there: Chrome tells
            // onDisconnect why ("Specified native messaging host not
            // found."). WebKit carries no reason, and in a worker its
            // runtime.lastError can't be set from here, so the listener
            // is handed the port with an `error` that says it, as
            // Firefox's ports have and as Bitwarden reads after
            // lastError; everything else is the port's own.
            const why = m && typeof m === "object" && Object.getPrototypeOf(m) === portProto && !m.error && gone.get(m);
            if (!why) return heard(() => f.call(this, m, ...rest));
            const told = new Proxy(m, { get: (port, key) => {
              if (key === "error") return { message: why };
              const value = Reflect.get(port, key);
              return typeof value === "function" ? value.bind(port) : value;
            } });
            return heard(() => f.call(this, told, ...rest));
          };
          byEvent.set(f, w);
        }
        return w;
      };
      put(eventProto, "addListener", function (f) {
        if (kept.has(this) || typeof f !== "function") return add.call(this, f);
        return add.call(this, wrapper(this, f, true));
      });
      put(eventProto, "removeListener", function (f) {
        const w = !kept.has(this) && typeof f === "function" && wrapper(this, f, false);
        if (!w) return remove.call(this, f);
        wrapped.get(this).delete(f);
        return remove.call(this, w);
      });
      put(eventProto, "hasListener", function (f) {
        const w = !kept.has(this) && typeof f === "function" && wrapper(this, f, false);
        return has.call(this, w || f);
      });
    }
  }
  // WebKit gives a worker the user agent of the last web page that set
  // one, Safari's, as yab's tabs send, not the Chrome one the
  // extension's pages have. Code that picks its path by it then takes
  // the Safari one: Bitwarden's asks a Safari app for a reply thousands
  // of times a second and floods the browser.
  // Its pages too: an extension reads navigator.userAgent to pick a code
  // path, a download, a welcome page, and finds nothing it knows in
  // Safari's. (Not WebKit's setting: see Extensions.init.)
  if (!inContent && typeof navigator !== "undefined" && !/ Chrome\//.test(navigator.userAgent)) {
    const chromeUA = navigator.userAgent.replace(/ Version\/[\d.]+.*$/, "").replace(/ Safari\/[\d.]+$/, "") + " Chrome/__YAB_CHROME__ Safari/537.36";
    const proto = typeof WorkerNavigator !== "undefined" && worker ? WorkerNavigator.prototype : typeof Navigator !== "undefined" ? Navigator.prototype : null;
    try {
      if (proto) {
        Object.defineProperty(proto, "userAgent", { get: () => chromeUA, configurable: true });
        Object.defineProperty(proto, "appVersion", { get: () => chromeUA.replace(/^Mozilla\//, ""), configurable: true });
        Object.defineProperty(proto, "vendor", { get: () => "Google Inc.", configurable: true });
        // Chrome has it and WebKit doesn't; code that believes the
        // Chrome user agent reaches for it next (Vimium C does).
        if (!("userAgentData" in navigator)) {
          const major = "__YAB_CHROME__".split(".")[0];
          const brands = [{ brand: "Chromium", version: major }, { brand: "Google Chrome", version: major }, { brand: "Not.A/Brand", version: "99" }];
          const low = { brands, mobile: false, platform: "macOS" };
          const mac = (chromeUA.match(/Mac OS X (\d+)[_.](\d+)(?:[_.](\d+))?/) || []).slice(1).map((n) => n || "0").join(".") || "10.15.7";
          const high = {
            architecture: "arm", bitness: "64", model: "", platformVersion: mac, wow64: false,
            fullVersionList: brands.map((b) => ({ brand: b.brand, version: b.version === major ? "__YAB_CHROME__" : b.version + ".0.0.0" })),
            uaFullVersion: "__YAB_CHROME__",
          };
          const pick = (hints) => Object.assign({}, low, ...(Array.isArray(hints) ? hints : []).filter((h) => h in high).map((h) => ({ [h]: high[h] })));
          const data = Object.assign({}, low, { getHighEntropyValues: (hints) => Promise.resolve(pick(hints)), toJSON: () => low });
          Object.defineProperty(proto, "userAgentData", { get: () => data, configurable: true });
        }
      }
    } catch (e) {}
  }
  // A worker's importScripts runs nothing else in Chrome until the script
  // has run: the worker is one thread. WebKit runs an extension's worker
  // on its web process's main thread and, while it fetches the script,
  // hands the worker the events that arrive meanwhile. Rabby imports its
  // whole background on its first event and notes it has only once
  // importScripts returns, so each message its popup sent meanwhile
  // imported the background again, inside the first: started over each
  // time, before it had written anything down, it opened its welcome
  // page each time, eight tabs from one press. So the extension's
  // listeners hear what arrives during an import once it is over, in
  // order, as in Chromium (`afterImport`, and its use in gather and below).
  // A worker starting its code from an event rather than as it loads
  // (Rabby and MetaMask import their background on install, or on the
  // first message after a launch): until that code says it is up, by its
  // first word to the tabs (their "ready"), or ten seconds on, a content
  // script's port is turned away with a word to try again, and its
  // content script does, a quarter of a second later each time (see
  // `closable`). Taken while that code was still starting, its first
  // questions were refused ("The provider is disconnected"), and Rabby's
  // provider never answered the page after install or at a launch, as
  // Yab registers each worker afresh then and says install to it (#356,
  // evals/extensions/rabby_wallet_trace.py). In Chrome the page asks only
  // once the worker has said it is ready.
  let firstTurn = true;
  if (worker) queueMicrotask(() => { firstTurn = false; });
  let lateImports = 0, settlingUntil = 0;
  const refusedPorts = new WeakSet();
  const startingUp = () => lateImports > 0 || Date.now() < settlingUntil;
  const tabPort = (port) => {
    try {
      const sender = port && port.sender;
      return !!(sender && sender.tab) && !(String(sender.url) + "/").startsWith(chrome.runtime.getURL(""));
    } catch (e) { return false; }
  };
  const turnAway = (port) => {
    if (!worker || !port || !tabPort(port)) return false;
    if (refusedPorts.has(port)) return true;
    if (!startingUp()) return false;
    refusedPorts.add(port);
    try { port.postMessage({ __yabPortLater: true }); } catch (e) {}
    setTimeout(() => { try { port.disconnect(); } catch (e) {} }, 100);
    return true;
  };
  if (worker && chrome.tabs && typeof chrome.tabs.sendMessage === "function") {
    const send = chrome.tabs.sendMessage;
    put(chrome.tabs, "sendMessage", function (...args) {
      if (!lateImports) settlingUntil = 0;
      return send.apply(this, args);
    });
    // Or its look for every tab to say so to (MetaMask's and Rabby's
    // "ready" asks for {url: "<all_urls>"}), which finds none at a launch
    // before Yab has told it of them.
    const query = chrome.tabs.query;
    if (typeof query === "function") {
      put(chrome.tabs, "query", function (info, ...rest) {
        if (!lateImports && info && info.url === "<all_urls>") settlingUntil = 0;
        return query.call(this, info, ...rest);
      });
    }
  }
  let importing = 0;
  const heldEvents = [];
  const afterImport = (deliver) => {
    if (!importing) return false;
    heldEvents.push(deliver);
    return true;
  };
  const releaseHeld = () => {
    if (importing || !heldEvents.length) return;
    // After the caller's own next line: the code that imported notes it
    // has, as Rabby does, before an event can ask it to import again.
    setTimeout(() => {
      while (!importing && heldEvents.length) {
        try { heldEvents.shift()(); } catch (e) { setTimeout(() => { throw e; }); }
      }
    });
  };
  if (worker && typeof root.importScripts === "function") {
    const shipped = new Set(), empty = new Set();
    for (const p of __YAB_SCRIPTS__) p.startsWith("-") ? empty.add(p.slice(1)) : shipped.add(p);
    const bare = root.importScripts.bind(root);
    const load = (...urls) => {
      const late = !firstTurn;
      importing++;
      if (late) lateImports++;
      try { return bare(...urls); } catch (e) {
        // A test run says which import threw: the extension's own
        // try around its imports keeps it from anyone otherwise.
        if (__YAB_VERBOSE__) native("debug.error", ["importScripts: " + String(e && e.stack ? e + " " + e.stack : e).slice(0, 1900)]).catch(() => {});
        throw e;
      } finally {
        importing--;
        if (late) { lateImports--; settlingUntil = Math.max(settlingUntil, Date.now() + 10000); }
        releaseHeld();
      }
    };
    root.importScripts = (...urls) => {
      const wanted = [];
      for (const u of urls) {
        let url; try { url = new URL(u, location.href); } catch (e) { wanted.push(u); continue; }
        const path = decodeURIComponent(url.pathname);
        if (url.origin === location.origin && empty.has(path)) continue;
        if (url.origin === location.origin && !shipped.has(path)) {
          throw new DOMException("Failed to execute 'importScripts' on 'WorkerGlobalScope': The script at '" + url.href + "' failed to load.", "NetworkError");
        }
        wanted.push(u);
      }
      if (wanted.length) return load(...wanted);
    };
    // The worker's own install and activate, which WebKit can also hand
    // it in the middle of an import begun by a message: Rabby imports its
    // background on either. Held the same way, the event kept going
    // (waitUntil) until its listener has run, so the listener may still
    // extend it.
    const listen = root.addEventListener, unlisten = root.removeEventListener;
    const standIns = new WeakMap();
    const lifecycle = (type) => type === "install" || type === "activate";
    root.addEventListener = function (type, listener, ...rest) {
      if (!lifecycle(type) || typeof listener !== "function") return listen.call(this, type, listener, ...rest);
      let stand = standIns.get(listener);
      if (!stand) {
        stand = function (event) {
          if (!importing) return listener.call(this, event);
          let done;
          try { event.waitUntil(new Promise((resolve) => { done = resolve; })); } catch (e) {}
          afterImport(() => { try { listener.call(this, event); } finally { if (done) done(); } });
        };
        standIns.set(listener, stand);
      }
      return listen.call(this, type, stand, ...rest);
    };
    root.removeEventListener = function (type, listener, ...rest) {
      return unlisten.call(this, type, (lifecycle(type) && standIns.get(listener)) || listener, ...rest);
    };
  }
  // The tab an extension's framed page is in, asked once (see
  // __yabToFrame).
  let ownTab = null;
  // Who has something to say about a message, told between the
  // extension's worker and its own pages on a channel they share (one
  // origin): each says, as soon as its listeners have run, whether it
  // answers or lets the message pass, and the sender says so of what
  // it sends. A page with nothing to say can then stay silent only
  // as long as someone else may still answer (see the end of `dispatch`).
  // A page in a website's frame is on the website's side of the
  // channel and takes no part; it waits, as before.
  const channel = !inContent && !framed && typeof BroadcastChannel === "function" ? new BroadcastChannel("yab-messages") : null;
  const me = Math.random().toString(36).slice(2);
  const peers = new Set();
  const verdicts = new Map();
  const waiting = new Set();
  const present = new Set();
  // Pages that are there but didn't hear the last message sent to all:
  // WebKit doesn't bring every message to every page. Not waited for
  // until they say something about one they heard.
  const deaf = new Set();
  // WebKit can reorder object keys while delivering the same message.
  const keyOf = (message) => {
    try {
      const k = JSON.stringify(message, (_name, value) => {
        if (!value || typeof value !== "object" || Array.isArray(value)) return value;
        const ordered = Object.create(null);
        for (const name of Object.keys(value).sort()) ordered[name] = value[name];
        return ordered;
      });
      return k && k.length < 4000 ? k : null;
    } catch (e) { return null; }
  };
  const tell = (message, verdict, heard) => {
    const key = channel && keyOf(message);
    if (key) channel.postMessage({ key, from: background ? "worker" : me, verdict, heard, at: Date.now() });
  };
  // Only a page that listens for messages is waited for: one that
  // doesn't never hears them, so never says anything about them.
  let listening = false;
  const join = () => { if (channel && !background && !listening) { listening = true; channel.postMessage({ hello: true, from: me, where: location.pathname }); } };
  const leave = () => { if (channel && !background && listening) { listening = false; channel.postMessage({ bye: true, from: me }); } };
  if (channel) {
    channel.onmessage = ({ data }) => {
      if (!data || data.from === me) return;
      // The pages that listen, as they come and go.
      if (!background && data.hello) {
        const known = peers.has(data.from);
        peers.add(data.from);
        if (!known && listening) channel.postMessage({ hello: true, from: me, where: location.pathname });
        return;
      }
      if (data.bye) { peers.delete(data.from); waiting.forEach((check) => check()); return; }
      // A popup that closes is thrown away without a word; so a page
      // left waiting asks who is still there.
      if (data.roll) { if (listening && !background) channel.postMessage({ here: true, from: me, to: data.from }); return; }
      if (data.here) { if (data.to === me) present.forEach((hear) => hear(data.from)); return; }
      if (typeof data.key !== "string") return;
      const now = Date.now();
      for (const [k, v] of verdicts) { if (now - v.at > 30000) verdicts.delete(k); else break; }
      const entry = verdicts.get(data.key) || { at: now, worker: null, pages: new Map() };
      verdicts.delete(data.key);
      verdicts.set(data.key, entry);
      entry.at = now;
      if (data.from === "worker") entry.worker = data;
      else { peers.add(data.from); if (data.heard) deaf.delete(data.from); entry.pages.set(data.from, data); }
      waiting.forEach((check) => check());
    };
    if (!background) try { root.addEventListener("pagehide", () => leave()); } catch (e) {}
  }
  const gather = (event, told) => {
    if (!event || typeof event.addListener !== "function") return;
    const add = event.addListener.bind(event);
    const remove = event.removeListener.bind(event);
    const listeners = new Set();
    let attached = false;
    // The shim is WebKit's first listener. Extensions such as Bitwarden
    // register their real handlers after asynchronous startup. Keep a
    // waking message for those handlers instead of answering it empty.
    const startingUntil = Date.now() + 15000;
    const startingMessages = new Set();
    const dispatch = function (message, sender, respond) {
      // Arrived while the worker imports a script: heard once it has (see
      // `afterImport`). Nobody here taking it, the answer is nothing, as WebKit's
      // would have been, at once when no page of the extension is known
      // to listen, else once a page has had the time to answer it.
      if (importing) {
        let answered = false;
        const once = (value) => { if (!answered) { answered = true; respond(value); } };
        afterImport(() => {
          if (dispatch.call(this, message, sender, once) !== true && !answered) setTimeout(() => once(undefined), peers.size ? 10000 : 0);
        });
        return true;
      }
      let settled = false, keep = false;
      const sendResponse = (value) => { if (!settled) { settled = true; respond(value); } };
      // Only the worker answers; any other page stays out of it.
      if (message && message.__yabPing === true) {
        if (background) { sendResponse("pong"); return; }
        return true;
      }
      // A worker's client message, or a page's to the worker (see
      // `sendClients`): only the shim takes it, and only where it is for.
      if (message && message.__yabClients) {
        const route = root.__yabClientsMessage;
        if (route && route(message.__yabClients, sender)) { sendResponse(undefined); return; }
        return background ? undefined : true;
      }
      // Listening only for those: anything else isn't for this page, which
      // stays out of it as a page with no listener does.
      if (!background && listeners.size === 0) return true;
      if (message && message.__yabUserScript === true) {
        const route = root.__yabUserScriptMessage;
        return route && route(message.message, sender, sendResponse) && !settled ? true : undefined;
      }
      // A call one of the extension's pages in a website's frame can't
      // make itself (see `framed`), made here for it, and only for one
      // of its pages: a content script gets no more than Chrome gives it.
      if (message && message.__yabCall) {
        if (!background) return true;
        const { space, method, args } = message.__yabCall;
        const own = (() => { try { return new URL(sender.url).origin === location.origin; } catch (e) { return false; } })();
        if (!own) { sendResponse({ error: "chrome." + space + " isn't available to content scripts" }); return; }
        if (space === "tabs" && method === "getCurrent") { sendResponse({ value: sender.tab }); return; }
        let ns; try { ns = chrome[space]; } catch (e) {}
        if (!ns || typeof ns[method] !== "function") { sendResponse({ error: "chrome." + space + "." + method + " isn't available" }); return; }
        Promise.resolve().then(() => ns[method](...(args || [])))
          .then((value) => sendResponse({ value }), (e) => sendResponse({ error: String(e && e.message || e) }));
        return true;
      }
      // Words a content script, or one of the extension's pages in a
      // website's frame, copies after the click's moment has passed (see
      // "Copying in a website's tab"): put on the clipboard from here.
      // Only this extension's own scripts can send it.
      if (message && message.__yabClipboard) {
        if (!background) return true;
        native("clipboard.write", [String(message.__yabClipboard.text ?? "")])
          .then(() => sendResponse({ value: true }), (e) => sendResponse({ error: String(e && e.message || e) }));
        return true;
      }
      // A tab's message, handed on by the worker (see alsoFramed): taken
      // by the frame it names, in the tab it names; every other page lets
      // it pass without answering, as it would a message not for it.
      if (message && message.__yabToFrame) {
        const to = message.__yabToFrame;
        if (!framed || !(to.urls || []).includes(location.href)) return background ? undefined : true;
        if (!ownTab) ownTab = Promise.resolve(Object.getPrototypeOf(runtime).sendMessage.call(runtime, { __yabCall: { space: "tabs", method: "getCurrent", args: [] } }))
          .then((reply) => reply && reply.value ? reply.value.id : null, () => null);
        ownTab.then((id) => {
          if (id !== to.tabId) return;
          let kept = false;
          for (const listener of [...listeners]) {
            let result;
            try { result = listener(to.message, sender, sendResponse); } catch (e) { setTimeout(() => { throw e; }); continue; }
            if (result === true) kept = true;
            else if (result && typeof result.then === "function") { kept = true; result.then(sendResponse, () => sendResponse(undefined)); }
          }
          if (!kept) sendResponse(undefined);
        });
        return true;
      }
      for (const listener of [...listeners]) {
        let result;
        try { result = listener(message, sender, sendResponse); } catch (e) { setTimeout(() => { throw e; }); continue; }
        if (result === true) keep = true;
        else if (result && typeof result.then === "function") { keep = true; result.then(sendResponse, () => sendResponse(undefined)); }
      }
      // 1Password asks whether it should intercept before offering a
      // passkey. Its handler is registered after async worker startup too;
      // an empty early answer makes the page keep the native provider until
      // it reloads. Hold only these credential requests for the new handler.
      const wakingCredential = message && (/^fido2(Get|Register)CredentialRequest$/.test(message.command || "") ||
        /^(should-intercept-webauthn-request|get-credential|create-credential)$/.test(message.name || ""));
      // Vimium asks this before installing its keys. Keep the original
      // startup request until its worker registers a listener, not a retry.
      const wakingFrame = message && message.handler === "initializeFrame";
      // Zotero's options page reads its initial preferences while the
      // worker is still registering its async message handler. An empty
      // early answer aborts the page before it installs the pane controls.
      const wakingPreferences = Array.isArray(message) && message.length === 2 &&
        message[0] === "Prefs.getAll" && Array.isArray(message[1]) && message[1].length === 0;
      if (background && told && (wakingCredential || wakingFrame || wakingPreferences) && !keep && !settled && Date.now() < startingUntil) {
        const tried = new Set(listeners);
        let timer;
        const finish = () => { clearTimeout(timer); startingMessages.delete(deliver); };
        const deliver = () => {
          for (const listener of [...listeners]) {
            if (tried.has(listener)) continue;
            tried.add(listener);
            let result;
            try { result = listener(message, sender, sendResponse); } catch (e) { setTimeout(() => { throw e; }); continue; }
            if (result === true) keep = true;
            else if (result && typeof result.then === "function") { keep = true; result.then(sendResponse, () => sendResponse(undefined)); }
            if (settled) break;
          }
          if (keep || settled) { finish(); tell(message, "answers", true); }
        };
        timer = setTimeout(() => { finish(); tell(message, "passes", true); sendResponse(undefined); }, Math.max(0, startingUntil - Date.now()));
        startingMessages.add(deliver);
        tell(message, "answers", true);
        return true;
      }
      if (!inContent) tell(message, keep || settled ? "answers" : "passes", true);
      if (keep || settled) return keep && !settled ? true : undefined;
      // Nothing here answers it. In Chrome that leaves the question to
      // the extension's other pages and its worker; WebKit takes the
      // first reply from any of them, and an empty one from a page that
      // only listens for something else, an offscreen document, an
      // options page, would arrive before the worker's real answer. So
      // a page that has nothing to say steps aside, and says nothing
      // only once everyone else has had ample time, or as soon as the
      // worker and every other open page have said they let it pass too,
      // or the worker sent it itself. Bitwarden's offscreen document
      // keeps its storage and answers a save with nothing: ten seconds
      // on each one got in the way of signing in.
      if (!background && !inContent) {
        const received = Date.now();
        const key = channel && keyOf(message);
        let check = () => {}, roll = null;
        const done = () => { waiting.delete(check); clearTimeout(late); clearTimeout(roll); };
        const late = setTimeout(() => { done(); sendResponse(undefined); }, 10000);
        if (key) {
          // Only what was said about this message, not an identical one
          // a while ago.
          const fresh = (said) => said && said.at >= received - 2000;
          check = () => {
            const entry = verdicts.get(key);
            if (settled || !entry) return;
            const worker = entry.worker;
            if (fresh(worker) && worker.verdict === "answers") { done(); return; }
            const said = [...peers].filter((id) => !deaf.has(id) || entry.pages.has(id)).map((id) => entry.pages.get(id));
            if (said.some((p) => fresh(p) && p.verdict === "answers")) { done(); return; }
            if (!fresh(worker) || said.some((p) => !fresh(p))) return;
            done();
            sendResponse(undefined);
          };
          waiting.add(check);
          check();
          // Still waiting on someone after a moment: those who don't say
          // they are here within a second are gone, and those who do but
          // still have said nothing about this message didn't hear it.
          roll = setTimeout(() => {
            if (settled) return;
            const heard = new Set();
            const hear = (id) => heard.add(id);
            present.add(hear);
            channel.postMessage({ roll: true, from: me });
            setTimeout(() => {
              present.delete(hear);
              for (const id of [...peers]) if (!heard.has(id)) peers.delete(id);
              const entry = verdicts.get(key);
              for (const id of peers) { const p = entry && entry.pages.get(id); if (!p || p.at < received - 2000) deaf.add(id); }
              check();
            }, 1000);
          }, 200);
        }
        return true;
      }
      return undefined;
    };
    put(event, "addListener", (listener) => {
      listeners.add(listener);
      if (told) join();
      if (!attached) { attached = true; add(dispatch); }
      for (const deliver of [...startingMessages]) deliver();
    });
    put(event, "removeListener", (listener) => {
      listeners.delete(listener);
      if (told && listeners.size === 0) leave();
      if (!background && attached && listeners.size === 0 && !(told && root.__yabClientsMessage)) { attached = false; remove(dispatch); }
    });
    put(event, "hasListener", (listener) => listeners.has(listener));
    put(event, "hasListeners", () => listeners.size > 0);
    // A worker may only add listeners while it starts; one that adds its
    // first later would be refused. So in a worker the one listener is
    // WebKit's from the start.
    if (background) { attached = true; add(dispatch); }
    // The offscreen document hears the worker's client messages with no
    // listener of its own (`sendClients`).
    if (told && !inContent && !background) root.__yabClientsAttach = () => { if (!attached) { attached = true; add(dispatch); } };
    return listeners;
  };
  // Chrome's runtime functions work taken off their object
  // (`const connect = chrome.runtime.connect; connect()`); WebKit's
  // answered nothing called that way.
  if (runtime) {
    const names = new Set();
    for (let o = runtime; o && o !== Object.prototype; o = Object.getPrototypeOf(o)) Object.getOwnPropertyNames(o).forEach((k) => names.add(k));
    for (const name of names) {
      if (name === "constructor" || /^on[A-Z]/.test(name)) continue;
      let f; try { f = runtime[name]; } catch (e) { continue; }
      if (typeof f !== "function") continue;
      const bound = f.bind(runtime);
      put(runtime, name, bound);
      // WebKit can ignore this replacement and make a new function on
      // every read. Vimium C calls getPlatformInfo.apply(0, [callback]);
      // without its runtime receiver that callback never arrives.
      if (!inContent && name === "getPlatformInfo" && runtime[name] !== bound && f.name === name) {
        const proto = Function.prototype, invoke = Reflect.apply, source = proto.toString;
        const nativeSource = invoke(source, f, []);
        if (!/\{\s*\[native code\]\s*\}\s*$/.test(nativeSource)) continue;
        // Match the native signature, not function identity: only this
        // refused API gets a receiver. Ordinary functions keep theirs.
        const owner = (fn, receiver) => typeof fn === "function" && fn.name === name &&
          invoke(source, fn, []) === nativeSource ? runtime : receiver;
        const apply = proto.apply, call = proto.call, bind = proto.bind;
        const methods = {
          apply(receiver, args) { return invoke(apply, this, [owner(this, receiver), args]); },
          call(receiver, ...args) { return invoke(call, this, [owner(this, receiver), ...args]); },
          bind(receiver, ...args) { return invoke(bind, this, [owner(this, receiver), ...args]); },
        };
        for (const method of Object.keys(methods)) {
          Object.defineProperty(proto, method, { ...Object.getOwnPropertyDescriptor(proto, method), value: methods[method] });
        }
      }
    }
  }
  // A port a content script opens to its extension. Chrome tells the
  // content script when the other end goes, by port.disconnect() there
  // or with the worker when it stops; WebKit tells it neither, and the
  // script runs on as if still connected, beside the fresh copy the
  // extension puts into the tab when its worker starts again. Bitwarden's
  // passkey script was put in about once a minute, and the older copy
  // answered the newer one's request at once, with nothing: GitHub said
  // "Authentication failed" while Bitwarden's window was still asking
  // which passkey (a tester, Oct 9 2026). So the other end says a word
  // on the port as it lets go (`closing`, further down), a worker that
  // starts again says so to every content script (the end of the
  // script), and here either one is the disconnect.
  if (inContent && runtime && typeof runtime.connect === "function") {
    const set = (target, key, value) => { try { Object.defineProperty(target, key, { value, configurable: true, writable: true }); } catch (e) {} };
    // Each open port, by the close that ends it here, with the life of
    // the worker that answered it once it has said.
    const open = new Map();
    let listening = false;
    const listen = () => {
      const changed = chrome.storage && chrome.storage.onChanged;
      if (listening || !changed || typeof changed.addListener !== "function") return;
      listening = true;
      const hear = (changes, area) => {
        const life = area === "local" && changes && changes.__yabWorkerLife && changes.__yabWorkerLife.newValue;
        if (!life) return;
        for (const [close, was] of [...open]) if (was.life && was.life !== life) close(true);
      };
      // Yab's own listener: it hears Yab's word (see `ownWords`).
      ownListeners.add(hear);
      changed.addListener(hear);
    };
    // `again` makes the port afresh: a worker still starting turns a port
    // away with a word to try again (see `turnAway`), and the content
    // script, which never hears of it, is reconnected a quarter of a
    // second on, what it posted meanwhile posted again on the new one.
    const closable = (port, again) => {
      const onMessage = port && port.onMessage, onDisconnect = port && port.onDisconnect;
      if (!onMessage || !onDisconnect || typeof onMessage.addListener !== "function" || typeof onDisconnect.addListener !== "function") return port;
      const post = port.postMessage, disconnect = port.disconnect;
      const heard = new Set(), gone = new Set();
      let closed = false, cur = port, confirmed = false, later = false, tries = 0;
      const unconfirmed = [];
      const close = (hangUp) => {
        if (closed) return;
        closed = true;
        open.delete(close);
        for (const f of [...gone]) { try { f(port); } catch (e) { setTimeout(() => { throw e; }); } }
        gone.clear();
        heard.clear();
        if (hangUp) { try { disconnect.call(cur); } catch (e) {} }
      };
      const was = { life: null };
      open.set(close, was);
      listen();
      const hearOn = (p) => {
        const om = p.onMessage, od = p.onDisconnect;
        om.addListener.call(om, (message, ...rest) => {
          if (p !== cur) return;
          if (message && typeof message === "object" && message.__yabPortLater === true) { later = true; return; }
          confirmed = true;
          unconfirmed.length = 0;
          if (message && typeof message === "object" && message.__yabPortClosed === true) return close(true);
          if (message && typeof message === "object" && typeof message.__yabPortLife === "string" && Object.keys(message).length === 1) {
            was.life = message.__yabPortLife;
            return;
          }
          for (const f of [...heard]) { try { f(message, ...rest); } catch (e) { setTimeout(() => { throw e; }); } }
        });
        od.addListener.call(od, () => {
          if (p !== cur) return;
          if (later && !closed && again && tries < 120) {
            later = false;
            tries++;
            setTimeout(() => {
              if (closed) return;
              let next = null;
              try { next = again(); } catch (e) {}
              if (!next || !next.onMessage) return close(false);
              cur = next;
              hearOn(next);
              for (const m of unconfirmed) { try { post.call(next, m); } catch (e) {} }
            }, 250);
            return;
          }
          close(false);
        });
        // Held on the port: WebKit makes an event afresh once nothing holds
        // it, without what is set here.
        set(p, "onMessage", om);
        set(p, "onDisconnect", od);
      };
      hearOn(port);
      set(onMessage, "addListener", (f) => { if (typeof f === "function") heard.add(f); });
      set(onMessage, "removeListener", (f) => { heard.delete(f); });
      set(onMessage, "hasListener", (f) => heard.has(f));
      set(onMessage, "hasListeners", () => heard.size > 0);
      set(onDisconnect, "addListener", (f) => { if (typeof f === "function") gone.add(f); });
      set(onDisconnect, "removeListener", (f) => { gone.delete(f); });
      set(onDisconnect, "hasListener", (f) => gone.has(f));
      set(onDisconnect, "hasListeners", () => gone.size > 0);
      // Its own disconnect doesn't call its own listeners, as in Chromium.
      set(port, "disconnect", () => { closed = true; open.delete(close); heard.clear(); gone.clear(); try { disconnect.call(cur); } catch (e) {} });
      set(port, "postMessage", (message) => {
        if (closed) throw new Error("Attempting to use a disconnected port object");
        if (!confirmed && unconfirmed.length < 500) unconfirmed.push(message);
        return post.call(cur, message);
      });
      return port;
    };
    const connect = runtime.connect;
    // Only a port to the extension itself, whose other end says the word.
    put(runtime, "connect", (...args) => {
      const port = connect.apply(runtime, args);
      return typeof args[0] === "string" && args[0] !== runtime.id ? port : closable(port, () => connect.apply(runtime, args));
    });
  }
  // YAB_PORT_TRACE=1 (a diagnosis): every runtime.connect, onConnect,
  // disconnect and onDisconnect counted by port name, with where a
  // disconnect was called from. A content script writes its counts on the
  // page (data-yab-port-trace), an extension's page or worker tells the
  // browser (debug.error), every 3 s while anything happened.
  if (__YAB_PORT_TRACE__ && runtime && typeof runtime.connect === "function") {
    const counts = {}, stacks = {};
    let dirty = false;
    const count = (k) => { counts[k] = (counts[k] || 0) + 1; dirty = true; };
    const where = () => String(new Error().stack || "").split("\n").slice(2, 6).map((l) => l.replace(/chrome-extension:\/\/[a-p]{32}\//, "").trim().slice(0, 90)).join(" < ");
    const watch = (port, side) => {
      const name = port && typeof port.name === "string" ? port.name.slice(0, 40) : "?";
      const born = Date.now();
      try {
        const disconnect = port.disconnect;
        Object.defineProperty(port, "disconnect", { configurable: true, writable: true, value: function (...args) {
          const k = side + " disconnect() " + name;
          count(k);
          const at = where();
          stacks[k] = stacks[k] || {};
          stacks[k][at] = (stacks[k][at] || 0) + 1;
          return disconnect.apply(this, args);
        } });
        port.onDisconnect.addListener(() => {
          const age = Date.now() - born;
          let why = "";
          try { why = String(port.error && port.error.message || runtime.lastError && runtime.lastError.message || "").slice(0, 80); } catch (e) {}
          count(side + " onDisconnect " + name + (age < 50 ? " <50ms" : age < 1000 ? " <1s" : " later") + (why ? " (" + why + ")" : ""));
        });
      } catch (e) { count("trace failed " + name); }
      return port;
    };
    // Through `chrome` and `browser` both, WebKit's are namespaces of
    // their own (NordPass calls through `browser`).
    for (const api of new Set([chrome, root.browser].filter((a) => a && typeof a === "object"))) {
      let rt; try { rt = api.runtime; } catch (e) { continue; }
      if (!rt || typeof rt.connect !== "function") continue;
      try { Object.defineProperty(api, "runtime", { value: rt, configurable: true, writable: true, enumerable: true }); } catch (e) {}
      const tag = api === chrome ? "chrome." : "browser.";
      const connect = rt.connect;
      put(rt, "connect", (...args) => {
        const port = connect.apply(rt, args);
        const name = (args.find((a) => a && typeof a === "object" && typeof a.name === "string") || {}).name || "";
        const to = typeof args[0] === "string" ? " to " + (args[0] === rt.id ? "self" : args[0].slice(0, 40)) : "";
        count(tag + "connect " + name.slice(0, 40) + to);
        return watch(port, "mine");
      });
      const sendMessage = rt.sendMessage;
      if (typeof sendMessage === "function") put(rt, "sendMessage", (...args) => {
        const m = args.find((a) => a && typeof a === "object");
        count(tag + "sendMessage " + String(m && (m.type || m.action || m.command) || "").slice(0, 40) + (typeof args[0] === "string" ? " to " + args[0].slice(0, 40) : ""));
        return sendMessage.apply(rt, args);
      });
      if (rt.onConnect && typeof rt.onConnect.addListener === "function") {
        const onConnect = rt.onConnect, add = onConnect.addListener, remove = onConnect.removeListener;
        const wrapped = new WeakMap();
        put(onConnect, "addListener", (listener, ...rest) => {
          if (typeof listener !== "function") return add.call(onConnect, listener, ...rest);
          let w = wrapped.get(listener);
          if (!w) {
            w = (port, ...more) => {
              count(tag + "onConnect " + (port && port.name || "").slice(0, 40) + (port && port.sender && port.sender.tab ? " from tab" : " from own"));
              return listener(watch(port, "theirs"), ...more);
            };
            wrapped.set(listener, w);
          }
          return add.call(onConnect, w, ...rest);
        });
        put(onConnect, "removeListener", (listener) => remove.call(onConnect, wrapped.get(listener) || listener));
      }
    }
    const started = Date.now();
    setInterval(() => {
      if (!dirty) return;
      dirty = false;
      const text = JSON.stringify({ s: Math.round((Date.now() - started) / 1000), where: inContent ? "content" : worker ? "worker" : String(location.pathname), counts, stacks });
      if (inContent) { try { document.documentElement.setAttribute("data-yab-port-trace", text); } catch (e) {} }
      else { try { native("debug.error", ["port trace: " + text.slice(0, 1900)]).catch(() => {}); } catch (e) {} }
    }, 3000);
  }

  // A content script WebKit put into a page that was already open when
  // the extension loaded (installed, turned on, updated) can't open a
  // port: WebKit doesn't find the tab of that page, and every
  // runtime.connect there ends at once ("Tab not found"), while
  // scripting and tabs.sendMessage reach the tab. Chrome never puts a
  // Manifest V3 extension's scripts into a page already open. NordPass's
  // store, never signed in, connects again on every disconnect: 5,000
  // times a second in each such tab, 190-700% CPU with a few tabs open
  // (evals/extensions/nordpass_idle.py). So a port that ends that way is
  // said to have ended a little later, 50 ms the first time and twice as
  // long each time after, up to a minute: a new tab WebKit is told of a
  // moment late connects again soon, a page that never will goes quiet.
  // A port that opens resets the wait. YAB_PORT_SLOW=0: told at once.
  if (__YAB_PORT_SLOW__ && inContent && runtime) {
    let failed = 0;
    const deadEnd = (port) => {
      try { return !!port.error && /tab not found/i.test(String(port.error.message || "")); } catch (e) { return false; }
    };
    const slowed = (port) => {
      const event = port && port.onDisconnect;
      if (!event || typeof event.addListener !== "function") return port;
      const add = event.addListener, remove = event.removeListener, has = event.hasListener;
      const mine = new Map();
      let opened = false;
      if (port.onMessage && typeof port.onMessage.addListener === "function") {
        try { port.onMessage.addListener.call(port.onMessage, () => { if (!opened) { opened = true; failed = 0; } }); } catch (e) {}
      }
      const set = (target, key, value) => { try { Object.defineProperty(target, key, { value, configurable: true, writable: true }); } catch (e) {} };
      set(port, "onDisconnect", event);
      set(event, "addListener", (f, ...rest) => {
        if (typeof f !== "function" || mine.has(f)) return add.call(event, f, ...rest);
        const g = function (...args) {
          if (!deadEnd(port)) return f.apply(this, args);
          const wait = Math.min(60000, 50 * 2 ** Math.min(failed, 11));
          failed++;
          setTimeout(() => f.apply(this, args), wait);
        };
        mine.set(f, g);
        return add.call(event, g, ...rest);
      });
      set(event, "removeListener", (f) => remove.call(event, mine.get(f) || f));
      if (typeof has === "function") set(event, "hasListener", (f) => has.call(event, mine.get(f) || f));
      return port;
    };
    // Through `chrome` and `browser` both: NordPass connects through
    // `browser`, a namespace of its own in WebKit.
    for (const api of new Set([chrome, root.browser].filter((a) => a && typeof a === "object"))) {
      let rt; try { rt = api.runtime; } catch (e) { continue; }
      if (!rt || typeof rt.connect !== "function") continue;
      if (api !== chrome) { try { Object.defineProperty(api, "runtime", { value: rt, configurable: true, writable: true, enumerable: true }); } catch (e) {} }
      const connect = rt.connect;
      put(rt, "connect", (...args) => slowed(connect.apply(rt, args)));
    }
  }
  // Yab's own words in an extension's storage, a worker's start told to
  // its content scripts (`__yabWorkerLife`, at the end), are Yab's: the
  // extension neither reads them nor hears them change, as nothing of
  // the browser's is in its storage in Chrome. Rabby opens its welcome
  // page as its worker first starts only while its storage holds
  // nothing, and found Yab's word there: no welcome page, as Chromium
  // shows one.
  const ownWords = new Set(["__yabWorkerLife"]);
  const ownListeners = new WeakSet();
  if (chrome.storage) {
    const unsaid = (items) => {
      if (!items || typeof items !== "object" || ![...ownWords].some((k) => k in items)) return items;
      const copy = Object.assign({}, items);
      for (const k of ownWords) delete copy[k];
      return copy;
    };
    const quiet = (event) => {
      if (!event || typeof event.addListener !== "function" || event.listeners) return;
      const add = event.addListener.bind(event), remove = event.removeListener.bind(event);
      const has = typeof event.hasListener === "function" ? event.hasListener.bind(event) : null;
      const stands = new WeakMap();
      const standFor = (listener) => {
        if (typeof listener !== "function" || ownListeners.has(listener)) return listener;
        let stand = stands.get(listener);
        if (!stand) {
          stand = function (changes, ...rest) {
            const left = unsaid(changes);
            if (left !== changes && !Object.keys(left).length) return undefined;
            return listener.call(this, left, ...rest);
          };
          stands.set(listener, stand);
        }
        return stand;
      };
      put(event, "addListener", (listener, ...rest) => add(standFor(listener), ...rest));
      put(event, "removeListener", (listener, ...rest) => remove(stands.get(listener) || listener, ...rest));
      if (has) put(event, "hasListener", (listener) => has(stands.get(listener) || listener));
    };
    quiet(chrome.storage.onChanged);
    const local = chrome.storage.local;
    if (local) {
      quiet(local.onChanged);
      if (typeof local.get === "function") {
        const get = local.get.bind(local);
        put(local, "get", (...args) => {
          const callback = args.length && typeof args[args.length - 1] === "function" ? args.pop() : null;
          const answer = Promise.resolve(get(...args)).then(unsaid);
          if (!callback) return answer;
          answer.then((value) => callback(value), (error) => withLastError(error, callback));
        });
      }
      if (typeof local.getKeys === "function") {
        const getKeys = local.getKeys.bind(local);
        put(local, "getKeys", (...args) => {
          const callback = args.length && typeof args[args.length - 1] === "function" ? args.pop() : null;
          const answer = Promise.resolve(getKeys(...args)).then((keys) => Array.isArray(keys) ? keys.filter((k) => !ownWords.has(k)) : keys);
          if (!callback) return answer;
          answer.then((value) => callback(value), (error) => withLastError(error, callback));
        });
      }
      if (typeof local.getBytesInUse === "function" && (typeof local.getKeys === "function" || typeof local.get === "function")) {
        const bytes = local.getBytesInUse.bind(local);
        const visible = (keys) => Array.isArray(keys) ? keys.filter((key) => !ownWords.has(key))
          : typeof keys === "string" && ownWords.has(keys) ? [] : keys;
        put(local, "getBytesInUse", (...args) => {
          const callback = args.length && typeof args[args.length - 1] === "function" ? args.pop() : null;
          const answer = Promise.resolve().then(() => {
            if (args[0] != null) return args[0];
            return typeof local.getKeys === "function" ? local.getKeys()
              : Promise.resolve(local.get(null)).then((items) => Object.keys(items));
          }).then((keys) => bytes(visible(keys), ...args.slice(1)));
          if (!callback) return answer;
          answer.then((value) => callback(value), (error) => withLastError(error, callback));
        });
      }
    }
  }
  // Copying in a website's tab. Chrome lets an extension that asked for
  // clipboardWrite copy from its content scripts and from its pages in a
  // site's frame at any time; WebKit gives those the site's own rule, a
  // copy only in the moment of a click. A manager's copy comes after it
  // has asked its worker for the secret, so the moment has passed, and
  // NordPass's copied password or email never reached the clipboard
  // (register 1019). Its own pages, popup, tabs and offscreen document,
  // WebKit lets copy only while it holds clipboardWrite from its manifest;
  // one given later (NordPass asks for it, an optional permission, before
  // each copy) and its offscreen document, where no click ever comes, still
  // can't. Real NordPass copies there, execCommand('copy') on a selected
  // textarea. Here WebKit tries first; only what it refuses goes to the
  // worker, which puts the words on the clipboard through the browser
  // (`clipboard.write`, which checks the permission as it stands now).
  if (!worker && typeof document !== "undefined" && typeof navigator !== "undefined") {
    // WebKit gives a content script no getManifest; then the browser
    // alone decides, and refuses one that never asked.
    const asked = (() => {
      try {
        if (typeof runtime.getManifest !== "function") return true;
        const m = runtime.getManifest();
        return [...(m.permissions || []), ...(m.optional_permissions || [])].includes("clipboardWrite");
      } catch (e) { return true; }
    })();
    const apply = Reflect.apply;
    const send = Object.getPrototypeOf(runtime).sendMessage;
    const viaWorker = (text) => Promise.resolve(send.call(runtime, { __yabClipboard: { text: String(text) } })).then((reply) => {
      if (!reply || reply.error) throw new DOMException((reply && reply.error) || "The clipboard could not be written", "NotAllowedError");
    });
    const refused = (e) => e && e.name === "NotAllowedError";
    const clip = asked ? navigator.clipboard : null;
    if (clip && typeof clip.writeText === "function") {
      const writeText = clip.writeText;
      put(clip, "writeText", function (text) {
        return apply(writeText, this, [text]).catch((e) => { if (refused(e)) return viaWorker(text); throw e; });
      });
    }
    if (clip && typeof clip.write === "function") {
      const write = clip.write;
      put(clip, "write", function (items) {
        return apply(write, this, [items]).catch(async (e) => {
          if (!refused(e)) throw e;
          const item = [...(items || [])].find((i) => i && [...(i.types || [])].includes("text/plain"));
          if (!item) throw e;
          const blob = await item.getType("text/plain");
          return viaWorker(typeof blob === "string" ? blob : await blob.text());
        });
      });
    }
    const Doc = typeof Document !== "undefined" ? Document : null;
    const exec = asked && Doc && Doc.prototype.execCommand;
    if (typeof exec === "function") {
      // What a copy takes with nothing given: a field's selected words,
      // else the page's selection.
      // A field's select() leaves it unfocused in WebKit, so the last one
      // selected here is remembered too.
      let lastField = null;
      for (const Field of [root.HTMLTextAreaElement, root.HTMLInputElement]) {
        const select = Field && Field.prototype && Field.prototype.select;
        if (typeof select !== "function") continue;
        put(Field.prototype, "select", function (...args) { lastField = this; return apply(select, this, args); });
      }
      const selected = () => {
        for (const field of [document.activeElement, lastField]) {
          try {
            if (field && field.isConnected && typeof field.selectionStart === "number" && typeof field.value === "string" && field.selectionEnd > field.selectionStart) {
              return field.value.slice(field.selectionStart, field.selectionEnd);
            }
          } catch (e) {}
        }
        try { return String(document.getSelection() || ""); } catch (e) { return ""; }
      };
      put(Doc.prototype, "execCommand", function (command, ...rest) {
        const done = apply(exec, this, [command, ...rest]);
        if (done || this !== document || String(command).toLowerCase() !== "copy") return done;
        // Refused: the copy event this would have sent, so a script that
        // fills the clipboard itself in it still can, then what it took.
        let data, event;
        try {
          data = new DataTransfer();
          event = new ClipboardEvent("copy", { clipboardData: data, bubbles: true, cancelable: true, composed: true });
        } catch (e) { return done; }
        const target = document.activeElement && document.activeElement !== document.body ? document.activeElement : (document.body || document.documentElement);
        target.dispatchEvent(event);
        const text = event.defaultPrevented ? data.getData("text/plain") : selected();
        if (!text) return done;
        viaWorker(text).catch(() => {});
        return true;
      });
    }
  }
  if (inContent) return;

  // In a website's frame, everything WebKit keeps to the extension's own
  // process goes through the worker instead. What stays direct is what
  // WebKit lets a content script call too. Namespaces the shim adds
  // itself further down answer through the browser, which is allowed.
  if (framed) {
    const direct = new Set(["runtime", "storage", "i18n", "extension", "permissions", "dom", "test"]);
    const ask = (space, method, args) => {
      while (args.length && args[args.length - 1] === undefined) args.pop();
      let payload;
      try { payload = JSON.parse(JSON.stringify(args)); } catch (e) { return Promise.reject(e); }
      return Promise.resolve(Object.getPrototypeOf(runtime).sendMessage.call(runtime, { __yabCall: { space, method, args: payload } })).then((reply) => {
        if (!reply) throw new Error("chrome." + space + "." + method + " had no answer from the extension's background");
        if (reply.error) throw new Error(reply.error);
        return reply.value;
      });
    };
    for (const space of spaces) {
      if (direct.has(space)) continue;
      let ns; try { ns = chrome[space]; } catch (e) { continue; }
      if (!ns || typeof ns !== "object") continue;
      const names = new Set();
      for (let o = ns; o && o !== Object.prototype; o = Object.getPrototypeOf(o)) Object.getOwnPropertyNames(o).forEach((k) => names.add(k));
      for (const name of names) {
        if (name === "constructor" || /^on[A-Z]/.test(name)) continue;
        let f; try { f = ns[name]; } catch (e) { continue; }
        if (typeof f !== "function") continue;
        // A port can't be carried over: one that closes at once, as
        // Chrome's does when nothing answers, rather than a dead process.
        if (name === "connect") {
          put(ns, name, (...args) => {
            const port = { name: (args.find((a) => a && typeof a === "object") || {}).name || "", sender: undefined,
              postMessage: () => {}, disconnect: () => {}, onMessage: event(), onDisconnect: event() };
            setTimeout(() => {
              put(runtime, "lastError", { message: "Could not establish connection. Receiving end does not exist." });
              try { for (const f of [...port.onDisconnect.listeners]) f(port); } finally { try { delete runtime.lastError; } catch (e) {} }
            });
            return port;
          });
          continue;
        }
        put(ns, name, (...args) => {
          const callback = args.length && typeof args[args.length - 1] === "function" ? args.pop() : null;
          const answer = ask(space, name, args);
          if (!callback) return answer;
          answer.then((value) => callback(value), (error) => withLastError(error, callback));
        });
      }
    }
  }

  // WebKit unloads an extension's worker after half a minute idle, and
  // starts it again for an event only if it remembers a listener for
  // it, which it does for messages, the worker's listener being in
  // place from its first line (see gather).
  //
  // A reply that never came is answered Chrome's way: in callback
  // form, with lastError set, WebKit calls back with nothing and no
  // error, and code that pings a tab to see if its script is there
  // waits for ever.
  const replied = (promise, callback, gone) => {
    if (typeof callback !== "function") return promise;
    promise.then((r) => r === undefined ? withLastError(new Error(gone), callback) : callback(r),
      (e) => withLastError(e, callback));
  };
  let checkWorker = () => {};
  // When the worker was last heard from, a reply, a port message.
  let heard = 0;
  if (runtime && typeof runtime.sendMessage === "function") {
    const page = typeof document !== "undefined";
    // WebKit's own, looked up at each call, not held from the page's
    // first moment, when the page isn't yet the tab or popup it will be.
    const original = Object.getPrototypeOf(runtime).sendMessage;
    const send = (...args) => original.apply(chrome.runtime, args);
    // WebKit can also lose a worker without knowing, its process
    // stopped along with a tab's, and then answers every message with
    // nothing, for good. So after waking it, a page asks the worker
    // itself (its shim answers) at most every few seconds; no answer,
    // and the browser takes the extension up afresh.
    const hasWorker = (() => { try { const b = runtime.getManifest().background || {}; return !!(b.service_worker || b.scripts || b.page); } catch (e) { return false; } })();
    // The message itself doesn't wait on the answer: a worker busy
    // starting up can take seconds. An empty reply means gone; silence
    // for a quarter of a minute does too.
    let asking = false;
    const check = () => {
      if (!hasWorker || asking || Date.now() - heard < 5000) return;
      asking = true;
      // Asked three times, a second apart, then once more after waking
      // it, only then taken for gone: a restart has consequences
      // (welcome pages, a popup loading again), and a question can go
      // unanswered for reasons that pass. Waking a worker that runs
      // starts it over, so that is kept for last.
      const ping = Object.getPrototypeOf(runtime).sendMessage;
      const ask = () => Promise.race([ping.call(runtime, { __yabPing: true }), new Promise((r) => setTimeout(() => r("late"), 15000))]).catch(() => undefined);
      const pause = (ms) => new Promise((w) => setTimeout(w, ms));
      const tries = [() => ask(), () => pause(1000).then(ask), () => pause(1000).then(ask),
        () => native("background.wake", []).catch(() => {}).then(() => pause(1000)).then(ask)];
      const attempt = (i, last) => i >= tries.length || last === "pong" ? Promise.resolve(last) : tries[i]().then((r) => attempt(i + 1, r));
      const started = Date.now();
      attempt(0).then((r) => {
        // Any real answer from the worker meanwhile says it runs, too:
        // the question alone can go unheard from a page that listens.
        if (r === "pong" || heard >= started) heard = Math.max(heard, Date.now());
        else {
          if (__YAB_VERBOSE__) native("debug.error", ["worker check: " + String(r) + " from " + location.pathname]).catch(() => {});
          native("background.revive", []).catch(() => {});
        }
      }).finally(() => { asking = false; });
    };
    checkWorker = page ? check : () => {};
    put(runtime, "sendMessage", (...args) => {
      const callback = typeof args[args.length - 1] === "function" ? args.pop() : null;
      // Never heard back by the one that sends it, so said for it.
      if (!inContent) tell(typeof args[0] === "string" && args.length > 1 && typeof args[1] !== "function" ? args[1] : args[0], "passes");
      checkWorker();
      const answer = send(...args).then((r) => { if (r !== undefined) heard = Date.now(); return r; });
      return replied(answer, callback, "The message port closed before a response was received.");
    });
  }
  // A message for a tab reaches only its content scripts in WebKit. In
  // Chrome it reaches the extension's own pages framed in that tab too:
  // 1Password's sign-in banner is one, told this way to offer a passkey
  // instead of a password, and without it the site's request failed. So
  // the worker hands it to those frames as well, and the first answer
  // from either wins.
  const alsoFramed = (answer, tabId, message, options) => {
    const nav = chrome.webNavigation;
    if (!nav || typeof nav.getAllFrames !== "function" || typeof tabId !== "number") return answer;
    const own = runtime.getURL("");
    const wanted = options && typeof options.frameId === "number" ? options.frameId : null;
    const inFrames = Promise.resolve(nav.getAllFrames({ tabId })).then((frames) => {
      const urls = (frames || []).filter((f) => f.url && f.url.startsWith(own) && f.frameId !== 0 && (wanted === null || f.frameId === wanted)).map((f) => f.url);
      if (!urls.length) return undefined;
      // Unanswered, a frame that isn't there any more, it gives up.
      return Promise.race([
        Object.getPrototypeOf(runtime).sendMessage.call(runtime, { __yabToFrame: { tabId, urls, message } }),
        new Promise((resolve) => setTimeout(() => resolve(undefined), 10000)),
      ]);
    }, () => undefined);
    return new Promise((resolve, reject) => {
      let left = 2, failure = null;
      const none = () => { if (--left === 0) failure ? reject(failure) : resolve(undefined); };
      answer.then((v) => v !== undefined ? resolve(v) : none(), (e) => { failure = e; none(); });
      inFrames.then((v) => v !== undefined ? resolve(v) : none(), () => none());
    });
  };
  if (chrome.tabs && typeof chrome.tabs.sendMessage === "function") {
    const send = chrome.tabs.sendMessage.bind(chrome.tabs);
    put(chrome.tabs, "sendMessage", (tabId, message, options, callback) => {
      if (typeof options === "function") { callback = options; options = undefined; }
      const p = options === undefined ? send(tabId, message) : send(tabId, message, options);
      return replied(background ? alsoFramed(p, tabId, message, options) : p, callback, "Could not establish connection. Receiving end does not exist.");
    });
  }
  if (typeof document !== "undefined" && runtime && typeof runtime.connect === "function") {
    const connect = runtime.connect.bind(runtime);
    put(runtime, "connect", (...args) => {
      checkWorker();
      const port = connect(...args);
      try { port.onMessage.addListener(() => { heard = Date.now(); }); } catch (e) {}
      return port;
    });
  }

  gather(runtime && runtime.onMessage, true);
  const externalListeners = gather(runtime && runtime.onMessageExternal);

  // Web pages an extension's externally_connectable lets in. WebKit has
  // nothing for them, so Yab carries what such a page sends
  // (ExtensionExternal.swift, extension-external-page.js) over a port the
  // worker opens to it, and it arrives here as Chromium delivers it:
  // runtime.onMessageExternal, or onConnectExternal with a port. The port
  // posts nothing by itself, so the worker still sleeps when idle; Yab
  // wakes it for the next page message and it opens the port again.
  if (background && runtime && typeof runtime.connectNative === "function") {
    let matches = [];
    try { matches = ((runtime.getManifest().externally_connectable || {}).matches || []); } catch (e) {}
    if (Array.isArray(matches) && matches.length) {
      const event = (target, name) => {
        const listeners = new Set();
        let wk = null; try { wk = target && target[name]; } catch (e) {}
        const own = wk && typeof wk.addListener === "function" ? wk : {};
        const add = typeof own.addListener === "function" ? own.addListener.bind(own) : null;
        const remove = typeof own.removeListener === "function" ? own.removeListener.bind(own) : null;
        put(own, "addListener", (f) => { if (typeof f !== "function") return; listeners.add(f); if (add) try { add(f); } catch (e) {} });
        put(own, "removeListener", (f) => { listeners.delete(f); if (remove) try { remove(f); } catch (e) {} });
        put(own, "hasListener", (f) => listeners.has(f));
        put(own, "hasListeners", () => listeners.size > 0);
        if (!wk && target) put(target, name, own);
        return listeners;
      };
      const connectListeners = event(runtime, "onConnectExternal");
      const simple = () => {
        const listeners = new Set();
        return { listeners, api: { addListener: (f) => { if (typeof f === "function") listeners.add(f); }, removeListener: (f) => listeners.delete(f),
          hasListener: (f) => listeners.has(f), hasListeners: () => listeners.size > 0 } };
      };
      const fire = (listeners, ...args) => { for (const f of [...listeners]) { try { f(...args); } catch (e) { setTimeout(() => { throw e; }); } } };
      const pagePorts = new Map(), opening = new Map();
      let link = null;
      // The tab the page is in, as the extension's own tabs API knows it:
      // asked by its place, which WebKit checks before anything dearer, so
      // a page that talks all the time costs one tab per message, not every
      // tab (feedback #1039). Only a place that finds nothing asks for all.
      const tabOf = async (sender) => {
        const said = sender.tab || {};
        try {
          const at = Number.isInteger(said.index) && said.index >= 0 ? await chrome.tabs.query({ index: said.index }) : [];
          let hit = at.find((t) => t.url === said.url) || (at.length === 1 ? at[0] : null);
          if (!hit) {
            const all = await chrome.tabs.query({});
            hit = all.find((t) => t.url === said.url) || at.find((t) => t.active);
          }
          if (hit) return hit;
        } catch (e) {}
        return { id: -1, index: said.index, url: said.url, active: true };
      };
      const sending = (sender) => tabOf(sender || {}).then((tab) => ({ origin: sender.origin, url: sender.url, frameId: sender.frameId, tab }));
      // A worker woken for the message adds its listeners as it starts,
      // some only after reading its storage: what comes before them waits,
      // through the worker's first 15 s.
      const startedAt = Date.now();
      const hear = (m) => {
        const word = m && m.__yabExternal;
        if (!word) return;
        if (afterImport(() => hear(m))) return;
        const none = word === "message" ? !(externalListeners && externalListeners.size) : word === "connect" ? !connectListeners.size : false;
        if (none && Date.now() - startedAt < 15000) { setTimeout(() => hear(m), 100); return; }
        if (word === "message") {
          sending(m.sender).then((sender) => {
            let settled = false, keep = false;
            const respond = (value) => {
              if (settled) return;
              settled = true;
              try { link.postMessage({ __yabExternal: "reply", n: m.n, value: value === undefined ? null : value }); } catch (e) {}
            };
            for (const f of [...(externalListeners || [])]) {
              let result;
              try { result = f(m.message, sender, respond); } catch (e) { setTimeout(() => { throw e; }); continue; }
              if (result === true) keep = true;
              else if (result && typeof result.then === "function") { keep = true; result.then(respond, () => respond(undefined)); }
            }
            if (!keep && !settled) { settled = true; try { link.postMessage({ __yabExternal: "reply", n: m.n, none: true }); } catch (e) {} }
          });
        } else if (word === "connect") {
          opening.set(m.port, sending(m.sender).then((sender) => {
            const onMessage = simple(), onDisconnect = simple();
            let gone = false;
            const port = {
              name: m.name || "", sender, onMessage: onMessage.api, onDisconnect: onDisconnect.api,
              postMessage: (message) => {
                if (gone) throw new Error("Attempting to use a disconnected port object");
                try { link.postMessage({ __yabExternal: "post", port: m.port, message: message === undefined ? null : JSON.parse(JSON.stringify(message)) }); } catch (e) {}
              },
              disconnect: () => {
                if (gone) return;
                gone = true;
                pagePorts.delete(m.port);
                try { link.postMessage({ __yabExternal: "disconnect", port: m.port }); } catch (e) {}
              },
            };
            pagePorts.set(m.port, { port, onMessage, onDisconnect, end: () => { if (gone) return; gone = true; pagePorts.delete(m.port); fire(onDisconnect.listeners, port); } });
            fire(connectListeners, port);
          }).finally(() => opening.delete(m.port)));
        } else if (word === "post" || word === "disconnect") {
          // After the port's connect, which may still be finding its tab.
          Promise.resolve(opening.get(m.port)).then(() => {
            const open = pagePorts.get(m.port);
            if (!open) return;
            if (word === "post") fire(open.onMessage.listeners, m.message, open.port);
            else open.end();
          });
        }
      };
      try {
        link = runtime.connectNative("yab.external");
        link.onMessage.addListener(hear);
        link.onDisconnect.addListener(() => {
          link = null;
          for (const open of [...pagePorts.values()]) open.end();
        });
      } catch (e) { link = null; }
    }
  }

  // The button of an extension without a popup, pressed while its worker
  // sleeps or is starting: WebKit wakes the worker and fires onClicked
  // once its script has run, and NordPass adds its listener only after
  // its stored state is read, a moment later. The press went nowhere
  // (twice in QA, farm a272666189904a0d), where Chrome's NordPass opens.
  // So the shim is WebKit's listener from the worker's first line, and
  // WebKit always knows to wake the worker for a press; one that comes
  // before the extension listens waits, through the worker's first
  // 15 s, and goes once to the listeners it adds then. An extension that
  // chooses a popup instead as it starts (NordPass, signed in) has the
  // waiting press open that popup (`popupChosen`, see setPopup).
  const holdClicks = (event, pressAgain) => {
    if (!event || typeof event.addListener !== "function") return null;
    const add = event.addListener.bind(event);
    const listeners = new Set();
    const startingUntil = Date.now() + 15000;
    let held = [], flushing = false, expiry = null;
    const hand = (listener, args) => { try { listener(...args); } catch (e) { setTimeout(() => { throw e; }); } };
    const drop = () => { held = []; clearTimeout(expiry); expiry = null; };
    // Every listener added in the same turn hears it, as at a dispatch.
    const flush = () => {
      flushing = false;
      if (!held.length || !listeners.size) return;
      const presses = held;
      drop();
      for (const args of presses) for (const listener of [...listeners]) hand(listener, args);
    };
    add(function press(...args) {
      // During an import, like every other event: once it is over (`afterImport`).
      if (afterImport(() => press(...args))) return;
      if (listeners.size) { for (const listener of [...listeners]) hand(listener, args); return; }
      if (Date.now() >= startingUntil) return;
      held.push(args);
      if (!expiry) {
        expiry = setTimeout(() => {
          const had = held.length > 0;
          drop();
          if (had && pressAgain) pressAgain();
        }, Math.max(0, startingUntil - Date.now()));
      }
    });
    put(event, "addListener", (listener) => {
      if (typeof listener !== "function") return;
      listeners.add(listener);
      if (held.length && !flushing) { flushing = true; Promise.resolve().then(flush); }
    });
    put(event, "removeListener", (listener) => { listeners.delete(listener); });
    put(event, "hasListener", (listener) => listeners.has(listener));
    put(event, "hasListeners", () => listeners.size > 0);
    return { event, popupChosen: () => { if (!held.length) return false; drop(); return true; } };
  };
  // End of holdClicks.
  const heldClicks = [];
  if (background) {
    // The browser presses it again: with a popup now, the popup opens.
    const pressAgain = () => { try { native("action.pressHeld", []).catch(() => {}); } catch (e) {} };
    const seen = new Set();
    for (const name of ["action", "browserAction"]) {
      let ev; try { ev = chrome[name] && chrome[name].onClicked; } catch (e) {}
      if (!ev || seen.has(ev)) continue;
      seen.add(ev);
      const held = holdClicks(ev, pressAgain);
      if (held) heldClicks.push(held);
    }
  }

  // Whole namespaces WebKit lacks, answered by the browser.
  const define = (name, methods, events = [], extra = {}) => {
    if (chrome[name]) return;
    const api = Object.assign({}, extra);
    for (const m of methods) api[m] = call(name + "." + m);
    for (const e of events) api[e] = event();
    put(chrome, name, api);
    if (root.browser && root.browser !== chrome && !root.browser[name]) put(root.browser, name, api);
  };
  define("bookmarks",
    ["get", "getChildren", "getRecent", "getSubTree", "getTree", "search", "create", "move", "update", "remove", "removeTree"],
    ["onCreated", "onRemoved", "onChanged", "onMoved", "onChildrenReordered", "onImportBegan", "onImportEnded"]);
  define("history",
    ["search", "getVisits", "addUrl", "deleteUrl", "deleteRange", "deleteAll"],
    ["onVisited", "onVisitRemoved"]);
  define("downloads",
    ["download", "search", "pause", "resume", "cancel", "open", "show", "showDefaultFolder", "erase", "removeFile", "getFileIcon",
     "setUiOptions", "setShelfEnabled", "acceptDanger"],
    ["onCreated", "onChanged", "onErased", "onDeterminingFilename"]);
  // Downloads' events come from the browser (ExtensionDownloads.swift): the
  // shim asks what happened since it last asked, and the answer waits until
  // something does, at most 25 s. Only while somebody here listens. A worker
  // asking first hears what it missed asleep; a download started here takes
  // a mark first, so its whole life is heard by listeners added after.
  if (chrome.downloads && chrome.downloads.onChanged?.listeners instanceof Set &&
      typeof chrome.downloads.download === "function") {
    const downloads = chrome.downloads;
    const names = ["onCreated", "onChanged", "onErased", "onDeterminingFilename"];
    const listening = () => names.some((name) => downloads[name].listeners.size > 0);
    let cursor = null, polling = false;
    let filenameRegistration = Promise.resolve();
    const starting = new Set(), notifications = [];
    const deliverNotifications = () => {
      if (starting.size) return;
      for (const { name, value } of notifications.splice(0)) {
        for (const listener of [...(downloads[name]?.listeners || [])]) {
          try { listener(value); } catch (error) { queueMicrotask(() => { throw error; }); }
        }
      }
    };
    const determineFilename = ({ request, item }) => {
      const listeners = [...downloads.onDeterminingFilename.listeners];
      let answered = false;
      const suggest = (suggestion) => {
        if (answered) return;
        answered = true;
        native("downloads.filenameSuggestion", [{ request, filename: suggestion?.filename }]).catch(() => {});
      };
      // Chrome permits one filename listener per extension. Returning true
      // holds its reply for an asynchronous suggest(); unload cancels natively.
      try {
        if (!listeners.length || listeners[0](item, suggest) !== true) suggest();
      } catch (error) { suggest(); queueMicrotask(() => { throw error; }); }
    };
    const poll = async () => {
      if (polling || !listening()) return;
      polling = true;
      let misses = 0;
      try {
        await filenameRegistration;
        while (listening()) {
          let reply;
          try {
            reply = await native("downloads.events", [cursor == null ? { worker: background } : { after: cursor, worker: background }]);
            misses = 0;
          } catch (e) {
            if (++misses > 5) break;
            await new Promise((resolve) => setTimeout(resolve, 1000));
            continue;
          }
          if (!reply) break;
          cursor = reply.seq;
          // Naming is part of download(), so it must be answered before
          // waiting for that download() promise to resolve.
          for (const entry of reply.events || []) {
            if (entry.name === "onDeterminingFilename") determineFilename(entry.value);
          }
          // Keep ordinary notifications until download() has supplied its
          // id, while continuing to receive the naming requests it depends on.
          notifications.push(...(reply.events || []).filter(entry => entry.name !== "onDeterminingFilename"));
          deliverNotifications();
        }
      } finally { polling = false; }
      if (background && !listening()) native("downloads.events", [{ stop: true }]).catch(() => {});
    };
    for (const name of names) {
      const target = downloads[name], add = target.addListener, remove = target.removeListener;
      put(target, "addListener", (listener) => {
        if (name === "onDeterminingFilename") {
          if (target.listeners.size && !target.listeners.has(listener)) throw new Error("Only one onDeterminingFilename listener is allowed");
          filenameRegistration = native("downloads.filenameListening", [true]);
        }
        add(listener); Promise.resolve().then(poll);
      });
      if (name === "onDeterminingFilename") put(target, "removeListener", (listener) => {
        remove(listener);
        if (!target.listeners.size) filenameRegistration = native("downloads.filenameListening", [false]);
      });
    }
    const start = downloads.download;
    put(downloads, "download", (...args) => {
      const callback = args.length > 1 && typeof args[args.length - 1] === "function" ? args.pop() : null;
      const pending = (async () => {
        await filenameRegistration;
        if (cursor == null) {
          try { cursor = (await native("downloads.events", [{ now: true }])).seq; } catch (e) {}
        }
        const id = await start(...args);
        poll();
        return id;
      })();
      const settled = pending.catch(() => {}).finally(() => { starting.delete(settled); deliverNotifications(); });
      starting.add(settled);
      if (!callback) return pending;
      pending.then((id) => callback(id), (error) => withLastError(error, callback));
    });
  }
  define("sidePanel", ["open", "setOptions", "getOptions", "setPanelBehavior", "getPanelBehavior", "getLayout"]);
  try {
    if (!Object.keys(runtime.getManifest().commands || {}).length) {
      define("commands", [], ["onCommand"], {
        getAll: (callback) => {
          if (typeof callback === "function") { setTimeout(() => callback([])); return; }
          return Promise.resolve([]);
        }
      });
    }
  } catch (e) {}
  define("offscreen", ["createDocument", "closeDocument", "hasDocument"], [],
    { Reason: new Proxy({}, { get: (_, key) => String(key) }) });
  sendClients.installClose();
  // Tab groups are Yab's folders (ExtensionGroups.swift). The groups'
  // windowId is the window the extension is told it is in; which group
  // each tab is in comes over a port to the worker of an extension with
  // the permission, and is asked for afresh on a page.
  const groupsAllowed = (() => { try { return (runtime.getManifest().permissions || []).includes("tabGroups"); } catch (e) { return false; } })();
  // Asked for only as optional, the API is there once it is granted, as in
  // Chrome, where chrome.tabGroups is undefined until then. Always there,
  // OneTab, which asks for it at its button's first press and guards every
  // use with `chrome.tabGroups &&`, had each send from its right-click menu
  // before that press fail on "never asked for tabGroups" (feedback #156).
  // A grant made in another of its pages is learned at the next look.
  const groupsOptional = !groupsAllowed && (() => { try { return (runtime.getManifest().optional_permissions || []).includes("tabGroups"); } catch (e) { return false; } })();
  let groupsGranted = false, groupsAsked = 0;
  const groupsShown = () => {
    if (!groupsGranted && Date.now() - groupsAsked > 1000) {
      groupsAsked = Date.now();
      native("permissions.granted", []).then((list) => { groupsGranted = Array.isArray(list) && list.includes("tabGroups"); }, () => {});
    }
    return groupsGranted;
  };
  let groupMembers = null, groupsLive = false;
  // tabs.onUpdated's listeners, kept by the tabs part below, to be told a
  // tab's {groupId} change: WebKit knows no groups and tells nothing.
  let tabUpdatedListeners = null;
  // The events of the groups' last change, told: a change of the
  // extension's own answers after them, as Chromium tells them before its
  // call returns. Their word comes over the port just before the answer.
  let groupsTold = Promise.resolve();
  const groupsSettled = () => new Promise((resolve) => setTimeout(resolve, 0)).then(() => groupsTold);
  // After a change of the extension's own, which group each tab is in is
  // asked at once: the port's word may come after the answer.
  const regroup = () => groupsAllowed && groupsLive
    ? native("tabGroups.membership", []).then((v) => { if (v && Array.isArray(v.members)) groupMembers = v.members; }, () => {})
    : Promise.resolve();
  {
    const api = { onCreated: event(), onRemoved: event(), onUpdated: event(), onMoved: event(),
      TAB_GROUP_ID_NONE: -1,
      // Read at load by some (Claude's, for the color of its group):
      // without it their worker never starts.
      Color: { GREY: "grey", BLUE: "blue", RED: "red", YELLOW: "yellow", GREEN: "green",
               PINK: "pink", PURPLE: "purple", CYAN: "cyan", ORANGE: "orange" } };
    let windowId = null;
    const placed = async (group) => {
      if (!group || typeof group !== "object") return group;
      if (windowId === null) { try { windowId = (await chrome.windows.getCurrent()).id; } catch (e) { windowId = -1; } }
      return Object.assign({}, group, { windowId });
    };
    for (const name of ["get", "query", "update", "move"]) {
      api[name] = (...args) => {
        const callback = args.length && typeof args[args.length - 1] === "function" ? args.pop() : null;
        const p = native("tabGroups." + name, args)
          .then((v) => name === "update" || name === "move" ? groupsSettled().then(() => v) : v)
          .then((v) => Array.isArray(v) ? Promise.all(v.map(placed)) : placed(v));
        if (!callback) return p;
        p.then((v) => callback(v), (e) => withLastError(e, callback));
      };
    }
    if (!chrome.tabGroups && groupsOptional) {
      groupsShown();
      for (const target of [chrome, root.browser]) {
        if (!target || (target !== chrome && target.tabGroups)) continue;
        kept.add(target);
        try { Object.defineProperty(target, "tabGroups", { configurable: true, enumerable: true, get: () => groupsShown() ? api : undefined }); } catch (e) {}
      }
    } else if (!chrome.tabGroups) {
      put(chrome, "tabGroups", api);
      if (root.browser && root.browser !== chrome && !root.browser.tabGroups) put(root.browser, "tabGroups", api);
    }
    if (groupsAllowed && chrome.tabGroups === api && typeof runtime.connectNative === "function") {
      let port = null;
      try { port = runtime.connectNative("yab.groups"); } catch (e) {}
      if (port) {
        let heard = false, tries = 0;
        const ready = () => {
          if (heard || tries++ >= 20) return;
          try { port.postMessage({ ready: true }); } catch (e) {}
          setTimeout(ready, 100 * Math.min(tries, 5));
        };
        // One message after another, each in Chrome's order: the tabs whose
        // group changed (tabs.onUpdated with {groupId}), then the groups'.
        let told = Promise.resolve();
        const tell = (listeners, ...args) => {
          for (const f of [...listeners]) { try { f(...args); } catch (e) { setTimeout(() => { throw e; }); } }
        };
        port.onMessage.addListener((m) => {
          if (!m) return;
          if (m.heard) { heard = true; return; }
          if (m.s && Array.isArray(m.s.members)) { groupMembers = m.s.members; groupsLive = true; }
          const changes = Array.isArray(m.t) ? m.t : [], events = Array.isArray(m.e) ? m.e : [];
          if (!changes.length && !events.length) return;
          told = groupsTold = told.then(async () => {
            if (changes.length && tabUpdatedListeners && tabUpdatedListeners.size && chrome.tabs) {
              const own = (await placed({})).windowId;
              // Each tab by its place, not every tab for each change: a
              // window of thousands made each fold cost the square of them.
              const at = await Promise.all(changes.map(([index]) => chrome.tabs.query({ index }).catch(() => [])));
              for (const [i, [index, groupId]] of changes.entries()) {
                const tabs = at[i];
                const tab = tabs.find((t) => t.windowId === own) || tabs[0];
                if (!tab) continue;
                try { tab.groupId = groupId; } catch (e) {}
                tell(tabUpdatedListeners.keys(), tab.id, { groupId }, tab);
              }
            }
            for (const [name, group] of events) {
              if (api[name]) tell(api[name].listeners, await placed(group));
            }
          }).catch(() => {});
        });
        port.onDisconnect.addListener(() => { groupsLive = false; groupMembers = null; });
        setTimeout(ready, 0);
      }
    }
  }
  define("fontSettings",
    ["getFontList", "getFont", "setFont", "clearFont", "getDefaultFontSize", "setDefaultFontSize",
     "clearDefaultFontSize", "getDefaultFixedFontSize", "setDefaultFixedFontSize", "clearDefaultFixedFontSize",
     "getMinimumFontSize", "setMinimumFontSize", "clearMinimumFontSize"],
    ["onFontChanged", "onDefaultFontSizeChanged", "onDefaultFixedFontSizeChanged", "onMinimumFontSizeChanged"]);
  define("management", ["getSelf", "getAll", "get", "setEnabled", "uninstallSelf"],
    ["onInstalled", "onUninstalled", "onEnabled", "onDisabled"]);
  define("notifications", ["create", "update", "clear", "getAll", "getPermissionLevel"],
    ["onClicked", "onClosed", "onButtonClicked", "onPermissionLevelChanged", "onShowSettings"]);
  define("tts", ["speak", "stop", "pause", "resume", "isSpeaking", "getVoices"], ["onVoicesChanged"]);
  define("identity",
    ["launchWebAuthFlow", "getAuthToken", "getProfileUserInfo", "removeCachedAuthToken", "clearAllCachedAuthTokens"],
    ["onSignInChanged"],
    { getRedirectURL: (path = "") => "https://" + runtime.id + ".chromiumapp.org/" + String(path).replace(/^\//, "") });

  // Chrome's settings objects: get, set and clear, and an event.
  const setting = (name) => ({
    get: call("setting.get:" + name), set: call("setting.set:" + name),
    clear: call("setting.clear:" + name), onChange: event(),
  });
  const settings = (prefix, names) =>
    Object.fromEntries(names.map((n) => [n, setting(prefix + "." + n)]));
  const put2 = (name, api) => {
    if (chrome[name]) return;
    put(chrome, name, api);
    if (root.browser && root.browser !== chrome && !root.browser[name]) put(root.browser, name, api);
  };
  // Something only Chrome can do, answered the way Chromium answers when
  // it can't: a rejection, or lastError for a callback.
  const refuse = (what) => (...args) => {
    const callback = args.length && typeof args[args.length - 1] === "function" ? args.pop() : null;
    const error = new Error(what + " isn't available in Pane");
    if (!callback) return Promise.reject(error);
    withLastError(error, callback);
  };

  define("search", ["query"]);
  define("idle", ["queryState", "getAutoLockDelay"], [],
    { IdleState: { ACTIVE: "active", IDLE: "idle", LOCKED: "locked" } });
  if (chrome.idle && !chrome.idle.onStateChanged) {
    // Asked every so often while anyone listens, the way Chromium
    // notices on its own.
    const changed = event(), add = changed.addListener, remove = changed.removeListener;
    let every = 60, state = "active", timer = null, generation = 0;
    changed.addListener = (f) => {
      add(f);
      if (timer !== null) return;
      const current = generation;
      timer = setInterval(() => native("idle.queryState", [every]).then((now) => {
        // A reply to a subscription that ended cannot change the cached
        // state or notify listeners of a later subscription.
        if (current !== generation) return;
        if (now === state) return;
        state = now;
        for (const g of changed.listeners) try { g(now); } catch (e) { setTimeout(() => { throw e; }); }
      }).catch(() => {}), 15000);
    };
    changed.removeListener = (f) => {
      const removed = remove(f);
      if (!changed.listeners.size && timer !== null) {
        clearInterval(timer);
        timer = null;
        generation += 1;
      }
      return removed;
    };
    put(chrome.idle, "onStateChanged", changed);
    put(chrome.idle, "setDetectionInterval", (seconds) => { every = Math.max(15, Number(seconds) || 60); });
  }
  define("power", ["requestKeepAwake", "releaseKeepAwake", "reportActivity"]);
  define("browsingData",
    ["remove", "removeAppcache", "removeCache", "removeCacheStorage", "removeCookies", "removeDownloads",
     "removeFileSystems", "removeFormData", "removeHistory", "removeIndexedDB", "removeLocalStorage",
     "removePasswords", "removeServiceWorkers", "removeWebSQL", "settings"]);
  define("sessions", ["getRecentlyClosed", "getDevices", "restore"], ["onChanged"], { MAX_SESSION_RESULTS: 25 });
  define("topSites", ["get"]);
  define("readingList", ["query", "addEntry", "removeEntry", "updateEntry"],
    ["onEntryAdded", "onEntryRemoved", "onEntryUpdated"]);
  // Its events come from the browser (ExtensionReadingList.swift) over a
  // port opened at the first listener only, so a context that never
  // listens costs nothing.
  if (chrome.readingList && chrome.readingList.onEntryAdded?.listeners instanceof Set &&
      typeof runtime.connectNative === "function" &&
      (() => { try { return (runtime.getManifest().permissions || []).includes("readingList"); } catch (e) { return false; } })()) {
    const list = chrome.readingList, names = ["onEntryAdded", "onEntryRemoved", "onEntryUpdated"];
    let port = null;
    const open = () => {
      if (port) return;
      try { port = runtime.connectNative("yab.readinglist"); } catch (e) { port = null; return; }
      port.onMessage.addListener((m) => {
        for (const [name, entry] of Array.isArray(m && m.e) ? m.e : []) {
          if (!names.includes(name)) continue;
          for (const f of [...list[name].listeners]) { try { f(entry); } catch (e) { setTimeout(() => { throw e; }); } }
        }
      });
      port.onDisconnect.addListener(() => { port = null; });
    };
    for (const name of names) {
      const ev = list[name], add = ev.addListener;
      ev.addListener = (f) => { add(f); open(); };
    }
  }
  put2("system", {
    cpu: { getInfo: call("system.cpu.getInfo") },
    memory: { getInfo: call("system.memory.getInfo") },
    storage: { getInfo: call("system.storage.getInfo"), ejectDevice: refuse("system.storage.ejectDevice"),
               getAvailableCapacity: refuse("system.storage.getAvailableCapacity"), onAttached: event(), onDetached: event() },
    display: { getInfo: call("system.display.getInfo"), onDisplayChanged: event() },
  });
  put2("privacy", {
    services: settings("privacy.services", ["alternateErrorPagesEnabled", "autofillAddressEnabled",
      "autofillCreditCardEnabled", "autofillEnabled", "passwordSavingEnabled", "safeBrowsingEnabled",
      "safeBrowsingExtendedReportingEnabled", "searchSuggestEnabled", "spellingServiceEnabled", "translationServiceEnabled"]),
    network: settings("privacy.network", ["networkPredictionEnabled", "webRTCIPHandlingPolicy"]),
    websites: settings("privacy.websites", ["adMeasurementEnabled", "doNotTrackEnabled", "fledgeEnabled",
      "hyperlinkAuditingEnabled", "protectedContentEnabled", "referrersEnabled", "relatedWebsiteSetsEnabled",
      "thirdPartyCookiesAllowed", "topicsEnabled"]),
    IPHandlingPolicy: { DEFAULT: "default", DEFAULT_PUBLIC_AND_PRIVATE_INTERFACES: "default_public_and_private_interfaces",
      DEFAULT_PUBLIC_INTERFACE_ONLY: "default_public_interface_only", DISABLE_NON_PROXIED_UDP: "disable_non_proxied_udp" },
  });
  // Yab's own per-site answers (ExtensionContentSettings.swift).
  const contentSetting = (name) => ({
    get: call("contentSettings." + name + ".get"), set: call("contentSettings." + name + ".set"),
    clear: call("contentSettings." + name + ".clear"),
    getResourceIdentifiers: call("contentSettings." + name + ".getResourceIdentifiers"),
  });
  put2("contentSettings", Object.fromEntries(["automaticDownloads", "autoVerify", "camera", "clipboard", "cookies",
    "images", "javascript", "location", "microphone", "notifications", "plugins", "popups", "sound"]
    .map((n) => [n, contentSetting(n)])));
  put2("proxy", { settings: setting("proxy.settings"), onProxyError: event() });
  // The extension's keyword in the field (ExtensionOmnibox.swift). The
  // worker of an extension with a keyword opens a port for the field's
  // events and says when it is listening; the browser holds what comes
  // before. onInputChanged's `suggest` answers the words it was given,
  // by the request's number, so a late answer to old words is dropped.
  {
    const api = { onInputStarted: event(), onInputChanged: event(), onInputEntered: event(),
      onInputCancelled: event(), onDeleteSuggestion: event(),
      setDefaultSuggestion: (suggestion) => { native("omnibox.setDefaultSuggestion", [suggestion || {}]).catch(() => {}); },
      OnInputEnteredDisposition: { CURRENT_TAB: "currentTab", NEW_FOREGROUND_TAB: "newForegroundTab", NEW_BACKGROUND_TAB: "newBackgroundTab" },
      DescriptionStyleType: { URL: "url", MATCH: "match", DIM: "dim" } };
    put2("omnibox", api);
    let keyword = false;
    try { keyword = !!(runtime.getManifest().omnibox || {}).keyword; } catch (e) {}
    if (keyword && background && typeof runtime.connectNative === "function" && chrome.omnibox === api) {
      const hand = (listeners, args) => {
        for (const f of [...listeners]) { try { f(...args); } catch (e) { setTimeout(() => { throw e; }); } }
      };
      const open = () => {
        let port;
        try { port = runtime.connectNative("yab.omnibox"); } catch (e) { return; }
        // WebKit drops what a worker posts on a port it has only just
        // opened: "ready" is said again until the browser has heard it.
        let heard = false, tries = 0;
        const ready = () => {
          if (heard || tries++ >= 20) return;
          try { port.postMessage({ ready: true }); } catch (e) {}
          setTimeout(ready, 100 * Math.min(tries, 5));
        };
        port.onMessage.addListener((m) => {
          if (m && m.heard) { heard = true; return; }
          if (!m || !api[m.e]) return;
          const args = Array.isArray(m.a) ? m.a.slice() : [];
          if (m.e === "onInputChanged") {
            const request = m.r;
            args.push((list) => { native("omnibox.suggest", [request, Array.isArray(list) ? list : []]).catch(() => {}); });
          }
          hand(api[m.e].listeners, args);
        });
        // After the worker's first turn, once its listeners are added.
        setTimeout(ready, 0);
      };
      open();
    }
  }
  // Capture through Yab's own share (ExtensionCapture.swift). A stream id
  // is Yab's token for what was picked in its box (chooseDesktopMedia) or
  // for a tab the extension was invoked on (getMediaStreamId); the page's
  // getUserMedia with {chromeMediaSource, chromeMediaSourceId} turns it
  // into a track (below), as in Chromium.
  const captureTab = async (tabId) => {
    let id = tabId;
    if (id == null) { const [t] = await chrome.tabs.query({ active: true, lastFocusedWindow: true }); id = t && t.id; }
    if (id == null) throw new Error("No tab to capture");
    return native("tabCapture.streamId", [(await chrome.tabs.get(id)).index]);
  };
  put2("tabCapture", {
    getMediaStreamId: (...args) => {
      const callback = args.length && typeof args[args.length - 1] === "function" ? args.pop() : null;
      const p = captureTab((args[0] || {}).targetTabId);
      if (!callback) return p;
      p.then((v) => callback(v), (e) => withLastError(e, callback));
    },
    // The MV2 way: a stream for the tab in front, at once.
    capture: (options, callback) => {
      const v = (options && options.videoConstraints && (options.videoConstraints.mandatory || options.videoConstraints)) || {};
      const picture = !!(options && options.video), sound = !!(options && options.audio);
      captureTab(null).then((id) => {
        if (!picture && !sound) throw new Error("Capture failed. No audio or video requested.");
        return navigator.mediaDevices.getUserMedia({
          video: picture && { mandatory: { chromeMediaSource: "tab", chromeMediaSourceId: id, maxWidth: v.maxWidth, maxHeight: v.maxHeight } },
          audio: sound && { mandatory: { chromeMediaSource: "tab", chromeMediaSourceId: id } } });
      }).then((stream) => { if (callback) callback(stream); }, (e) => withLastError(e, callback || (() => {})));
    },
    getCapturedTabs: (cb) => { if (cb) cb([]); else return Promise.resolve([]); }, onStatusChanged: event() });
  put2("desktopCapture", {
    chooseDesktopMedia: (sources, tab, cb) => {
      const callback = typeof tab === "function" ? tab : cb;
      const target = tab && typeof tab === "object" ? tab : null;
      const request = 1 + Math.floor(Math.random() * 2147483000);
      (async () => {
        const tabIndex = target && target.id != null ? (await chrome.tabs.get(target.id)).index : null;
        const answer = await native("desktopCapture.choose", [{ sources: Array.isArray(sources) ? sources : [], tabIndex, request }]);
        if (callback) callback((answer && answer.id) || "", { canRequestAudioTrack: !!(answer && answer.canRequestAudioTrack) });
      })().catch((e) => { if (callback) withLastError(e, callback); });
      return request;
    },
    cancelChooseDesktopMedia: (request) => { native("desktopCapture.cancel", [request]).catch(() => {}); },
    DesktopCaptureSourceType: { SCREEN: "screen", WINDOW: "window", TAB: "tab", AUDIO: "audio" } });
  // In the extension's own pages: getUserMedia for a stream id goes to
  // Yab's share (share-page.js `stream`); anything else is WebKit's. A page
  // without Yab's share in it (an offscreen document) is told so.
  if (!inContent && typeof document !== "undefined" && typeof navigator !== "undefined" && navigator.mediaDevices) {
    const media = navigator.mediaDevices;
    const own = typeof media.getUserMedia === "function" ? media.getUserMedia.bind(media) : null;
    const wanted = (constraints) => {
      const video = constraints && constraints.video;
      if (!video || typeof video !== "object") return null;
      const m = video.mandatory || video;
      const source = m.chromeMediaSource, id = m.chromeMediaSourceId;
      if (!id || (source !== "desktop" && source !== "tab" && source !== "screen")) return null;
      const most = (x) => typeof x === "number" ? x : x && (x.max || x.exact || x.ideal) || 0;
      return { id: String(id), width: most(m.maxWidth || video.width), height: most(m.maxHeight || video.height) };
    };
    // The tab's sound, asked for as Chromium's audio constraint with the
    // same kind of stream id (Loom, Volume Master, Transpose's tab mode).
    const heard = (constraints) => {
      const audio = constraints && constraints.audio;
      if (!audio || typeof audio !== "object") return null;
      const m = audio.mandatory || audio;
      const source = m.chromeMediaSource, id = m.chromeMediaSourceId;
      return id && (source === "tab" || source === "desktop") ? String(id) : null;
    };
    const ask = async (constraints) => {
      const want = wanted(constraints), sound = heard(constraints);
      if (!want && !sound) {
        if (own) return own(constraints);
        throw new DOMException("getUserMedia is not available", "NotSupportedError");
      }
      const share = typeof MediaDevices !== "undefined" && MediaDevices.prototype[Symbol.for("yab.share")];
      if (!share || typeof share.stream !== "function") {
        throw new DOMException("Capturing a tab or a screen works in Pane from an extension's own tab, not from this page", "NotSupportedError");
      }
      if (!want) return share.sound(sound);
      const picture = await share.stream(want.id, want.width, want.height);
      if (!sound) return picture;
      try {
        const audio = await share.sound(sound);
        return new MediaStream([...picture.getVideoTracks(), ...audio.getAudioTracks()]);
      } catch (e) {
        picture.getTracks().forEach((track) => track.stop());
        throw e;
      }
    };
    put(media, "getUserMedia", (constraints) => ask(constraints));
    const legacy = (constraints, ok, fail) => { ask(constraints).then(ok, (e) => { if (typeof fail === "function") fail(e); }); };
    put(navigator, "getUserMedia", legacy);
    put(navigator, "webkitGetUserMedia", legacy);
  }
  // The tab as one MHTML file (ExtensionPageCapture.swift), a Blob as
  // Chrome hands it.
  put2("pageCapture", { saveAsMHTML: (details, callback) => {
    const p = (async () => {
      const tab = await chrome.tabs.get(details && details.tabId);
      const text = await native("pageCapture.save", [tab.index]);
      const raw = atob(text), bytes = new Uint8Array(raw.length);
      for (let i = 0; i < raw.length; i++) bytes[i] = raw.charCodeAt(i);
      return new Blob([bytes], { type: "multipart/related" });
    })();
    if (typeof callback !== "function") return p;
    p.then((blob) => callback(blob), (e) => withLastError(e, callback));
  } });
  // The Chrome DevTools Protocol for a tab, translated by the browser
  // (ExtensionDebugger.swift). A tab is named to it by where it stands in
  // the row and its address, as for tabs.move; Chrome's tab id stays the
  // extension's own. Events come back over a port of their own, opened
  // with the first attach, so nothing listens for an extension that
  // never attaches.
  {
    const onEvent = event(), onDetach = event();
    let port = null;
    const hand = (listeners, args) => {
      for (const f of [...listeners]) { try { f(...args); } catch (e) { setTimeout(() => { throw e; }); } }
    };
    const listen = () => {
      if (port || !runtime || typeof runtime.connectNative !== "function") return;
      try {
        port = runtime.connectNative("yab.debugger");
        port.onMessage.addListener((m) => {
          if (m && Array.isArray(m.e)) hand(onEvent.listeners, m.e);
          if (m && Array.isArray(m.d)) hand(onDetach.listeners, m.d);
        });
        port.onDisconnect.addListener(() => { port = null; });
      } catch (e) { port = null; }
    };
    const withCallback = (f) => (...args) => {
      const callback = args.length && typeof args[args.length - 1] === "function" ? args.pop() : null;
      const p = f(...args);
      if (!callback) return p;
      p.then((v) => callback(v), (e) => withLastError(e, callback));
    };
    const tabOf = (target) => {
      if (target && typeof target.tabId === "number") return target.tabId;
      throw new Error(target && (target.targetId || target.extensionId) ? "Only tabs can be debugged in Pane." : "Either tab id or extension id must be specified.");
    };
    put2("debugger", {
      attach: withCallback(async (target, version) => {
        const tabId = tabOf(target);
        let tab;
        try { tab = await chrome.tabs.get(tabId); } catch (e) { throw new Error("No tab with given id " + tabId + "."); }
        listen();
        await native("debugger.attach", [{ tabId, index: tab.index, url: tab.url || tab.pendingUrl || "", version: version || "1.3" }]);
      }),
      detach: withCallback(async (target) => { await native("debugger.detach", [{ tabId: tabOf(target) }]); }),
      sendCommand: withCallback(async (target, method, params) =>
        native("debugger.send", [{ tabId: tabOf(target), method: String(method), params: params || {} }])),
      getTargets: withCallback(async () => {
        const [tabs, held] = await Promise.all([chrome.tabs.query({}), native("debugger.attached", []).catch(() => [])]);
        const ours = new Map((held || []).map((h) => [h.tabId, h.targetId]));
        return tabs.map((tab) => ({ type: "page", id: ours.get(tab.id) || "YAB" + tab.id, title: tab.title || "", url: tab.url || "",
          attached: ours.has(tab.id), tabId: tab.id, faviconUrl: tab.favIconUrl }));
      }),
      onEvent, onDetach,
      DetachReason: { CANCELED_BY_USER: "canceled_by_user", TARGET_CLOSED: "target_closed" },
      TargetInfoType: { BACKGROUND_PAGE: "background_page", OTHER: "other", PAGE: "page", WORKER: "worker" },
    });
  }
  put2("gcm", { register: refuse("gcm.register"), unregister: refuse("gcm.unregister"), send: refuse("gcm.send"),
    onMessage: event(), onMessagesDeleted: event(), onSendError: event() });
  put2("instanceID", { getID: refuse("instanceID.getID"), getToken: refuse("instanceID.getToken"),
    deleteID: refuse("instanceID.deleteID"), deleteToken: refuse("instanceID.deleteToken"),
    getCreationTime: refuse("instanceID.getCreationTime"), onTokenRefresh: event() });
  // Rules that show a button on matching pages: every button is always
  // shown in yab, so there is nothing for them to do.
  const rules = () => ({ addRules: (r, cb) => { if (cb) cb(r || []); }, removeRules: (i, cb) => { if (cb) cb(); },
    getRules: (i, cb) => { const f = typeof i === "function" ? i : cb; if (f) f([]); } });
  put2("declarativeContent", { onPageChanged: rules(),
    PageStateMatcher: function (o) { Object.assign(this, o); }, ShowAction: function () {}, ShowPageAction: function () {},
    SetIcon: function (o) { Object.assign(this, o); }, RequestContentScript: function (o) { Object.assign(this, o); } });

  // On macOS 26.4 and 26.5 WebKit ends an extension's process as soon as
  // one of its pages or its worker asks for a Web Lock: the browser side
  // takes WebLockRegistryProxy::RequestLock from an extension's origin for
  // an invalid message and terminates the sender. 1Password's worker holds
  // its fill sessions under navigator.locks, so every tab it looked at
  // took its worker down; WebKit started another for the next event, a
  // new process each time, over and over, its WASM core never ready for
  // the calls that came first ("WASM is not initialized"), its button
  // opening nothing and its card filling with warnings (feedback #140).
  // There, the extension's own pages and worker get a LockManager of
  // Yab's, each its own: the same requests, modes, ifAvailable, steal and
  // signal, held within the page or worker that asked. (Not between them:
  // what one holds, another doesn't wait for. 1Password's lock names are
  // its own context's.) Content scripts keep the page's, which works.
  if (__YAB_LOCKS__ && root.navigator && root.navigator.locks) {
    const abortError = () => new DOMException("The request was aborted.", "AbortError");
    const held = new Map(), waiting = new Map();
    const list = (map, name) => { let l = map.get(name); if (!l) map.set(name, l = []); return l; };
    // Free for this mode now: nothing held, or shared beside shared.
    const fits = (name, mode) => {
      const now = held.get(name) || [];
      return !now.length || mode === "shared" && now.every((h) => h.mode === "shared");
    };
    // A new request waits behind those already waiting, as in the spec.
    const grantable = (name, mode) => !(waiting.get(name) || []).length && fits(name, mode);
    const release = (entry) => {
      const now = held.get(entry.name) || [];
      const at = now.indexOf(entry);
      if (at >= 0) now.splice(at, 1);
      if (!now.length) held.delete(entry.name);
      pump(entry.name);
    };
    const grant = (entry) => {
      list(held, entry.name).push(entry);
      const lock = Object.freeze({ name: entry.name, mode: entry.mode });
      // Called a moment later, as a granted lock's callback is.
      Promise.resolve().then(() => entry.callback(lock)).then((v) => { if (!entry.stolen) { release(entry); entry.resolve(v); } },
        (e) => { if (!entry.stolen) { release(entry); entry.reject(e); } });
    };
    const pump = (name) => {
      const queue = waiting.get(name);
      while (queue && queue.length && fits(name, queue[0].mode)) grant(queue.shift());
      if (queue && !queue.length) waiting.delete(name);
    };
    const request = function (name, options, callback) {
      if (typeof options === "function") { callback = options; options = {}; }
      options = options || {};
      name = String(name);
      const mode = options.mode === "shared" ? "shared" : "exclusive";
      if (typeof callback !== "function") return Promise.reject(new TypeError("The callback is not a function."));
      if (name.startsWith("-")) return Promise.reject(new DOMException("Names starting with '-' are reserved.", "NotSupportedError"));
      if (options.steal && (options.ifAvailable || mode !== "exclusive")) return Promise.reject(new DOMException("steal needs an exclusive lock without ifAvailable.", "NotSupportedError"));
      if (options.signal && options.signal.aborted) return Promise.reject(options.signal.reason || abortError());
      return new Promise((resolve, reject) => {
        const entry = { name, mode, callback, resolve, reject, stolen: false };
        if (options.steal) {
          for (const old of held.get(name) || []) { old.stolen = true; old.reject(abortError()); }
          held.delete(name);
          grant(entry);
          return;
        }
        if (grantable(name, mode)) { grant(entry); return; }
        if (options.ifAvailable) {
          Promise.resolve().then(() => callback(null)).then(resolve, reject);
          return;
        }
        list(waiting, name).push(entry);
        if (options.signal) {
          options.signal.addEventListener("abort", () => {
            const queue = waiting.get(name) || [];
            const at = queue.indexOf(entry);
            if (at < 0) return;
            queue.splice(at, 1);
            if (!queue.length) waiting.delete(name);
            reject(options.signal.reason || abortError());
            pump(name);
          }, { once: true });
        }
      });
    };
    const query = function () {
      const out = (map) => [...map.values()].flat().map((e) => ({ name: e.name, mode: e.mode, clientId: "" }));
      return Promise.resolve({ held: out(held), pending: out(waiting) });
    };
    try {
      const manager = Object.create(Object.getPrototypeOf(root.navigator.locks));
      Object.defineProperty(manager, "request", { value: request, configurable: true, writable: true });
      Object.defineProperty(manager, "query", { value: query, configurable: true, writable: true });
      Object.defineProperty(root.navigator, "locks", { get: () => manager, configurable: true });
    } catch (e) {}
  }

  // WebKit serves extension .wasm files without application/wasm. Read
  // the response stream before compiling: response.arrayBuffer() can stall
  // on large extension assets even when every chunk is available.
  if (root.WebAssembly && typeof WebAssembly.instantiateStreaming === "function") {
    const own = (r) => r && typeof r.url === "string" && /^(chrome|webkit)-extension:/.test(r.url);
    const bytesOf = async (response) => {
      if (!response.body) return response.arrayBuffer();
      const reader = response.body.getReader();
      const chunks = [];
      let size = 0;
      for (;;) {
        const part = await reader.read();
        if (part.done) break;
        chunks.push(part.value);
        size += part.value.byteLength;
      }
      const bytes = new Uint8Array(size);
      let offset = 0;
      for (const chunk of chunks) { bytes.set(chunk, offset); offset += chunk.byteLength; }
      return bytes;
    };
    const instantiate = WebAssembly.instantiateStreaming.bind(WebAssembly);
    WebAssembly.instantiateStreaming = async (source, imports) => {
      const response = await source;
      return own(response) ? WebAssembly.instantiate(await bytesOf(response), imports) : instantiate(response, imports);
    };
    if (typeof WebAssembly.compileStreaming === "function") {
      const compile = WebAssembly.compileStreaming.bind(WebAssembly);
      WebAssembly.compileStreaming = async (source) => {
        const response = await source;
        return own(response) ? WebAssembly.compile(await bytesOf(response)) : compile(response);
      };
    }
  }

  // Members Chrome has on the namespaces WebKit has too, that WebKit
  // leaves out. Plenty are read at the top of a worker, an enum, an
  // event to listen to, where one missing member is a TypeError that
  // stops the whole worker before it has done anything.
  const fill = (name, members) => {
    const target = chrome[name];
    if (!target) return;
    for (const [key, value] of Object.entries(members)) {
      let there;
      try { there = target[key]; } catch (e) {}
      if (there === undefined) put(target, key, value);
    }
  };
  const resolve = (value) => (...args) => {
    const callback = args.length && typeof args[args.length - 1] === "function" ? args.pop() : null;
    const v = typeof value === "function" ? value(...args) : value;
    if (!callback) return Promise.resolve(v);
    setTimeout(() => callback(v));
  };
  const enumOf = (...values) => Object.fromEntries(values.map((v) => [v.toUpperCase().replace(/[-.]/g, "_").replace(/([a-z])([A-Z])/g, "$1_$2").toUpperCase(), v]));
  const resourceTypes = enumOf("main_frame", "sub_frame", "stylesheet", "script", "image", "font", "object",
    "xmlhttprequest", "ping", "csp_report", "media", "websocket", "webtransport", "webbundle", "other");
  fill("runtime", {
    onUpdateAvailable: event(), onRestartRequired: event(), onSuspend: event(), onSuspendCanceled: event(),
    onBrowserUpdateAvailable: event(), onConnectNative: event(), onUserScriptConnect: event(), onUserScriptMessage: event(),
    requestUpdateCheck: (callback) => {
      if (typeof callback === "function") { setTimeout(() => callback("no_update", {})); return; }
      return Promise.resolve({ status: "no_update" });
    },
    restart: () => {}, restartAfterDelay: resolve(undefined),
    getPackageDirectoryEntry: refuse("runtime.getPackageDirectoryEntry"),
    OnInstalledReason: enumOf("install", "update", "chrome_update", "shared_module_update"),
    OnRestartRequiredReason: enumOf("app_update", "os_update", "periodic"),
    PlatformArch: { ARM: "arm", ARM64: "arm64", X86_32: "x86-32", X86_64: "x86-64", MIPS: "mips", MIPS64: "mips64" },
    PlatformNaclArch: { ARM: "arm", X86_32: "x86-32", X86_64: "x86-64", MIPS: "mips", MIPS64: "mips64" },
    PlatformOs: { MAC: "mac", WIN: "win", ANDROID: "android", CROS: "cros", LINUX: "linux", OPENBSD: "openbsd", FUCHSIA: "fuchsia" },
    RequestUpdateCheckStatus: enumOf("throttled", "no_update", "update_available"),
    ContextType: { TAB: "TAB", POPUP: "POPUP", BACKGROUND: "BACKGROUND", OFFSCREEN_DOCUMENT: "OFFSCREEN_DOCUMENT",
      SIDE_PANEL: "SIDE_PANEL", DEVELOPER_TOOLS: "DEVELOPER_TOOLS" },
  });
  // The popup yab shows is a page of its own, known to WebKit as a
  // tab with no place in the row (no index). Chrome has no current
  // tab in a popup, and lists it among the popup views; extensions lay
  // themselves out by that (Bitwarden, Proton Pass: or else they fill
  // the window as if in a tab).
  if (typeof document !== "undefined") {
    // Known at once for the manifest's popup page, pages lay themselves
    // out before any answer can come back, and settled by what WebKit
    // says of the tab.
    let popup = (() => {
      try {
        const m = runtime.getManifest(), a = m.action || m.browser_action || {};
        return !!a.default_popup && new URL(a.default_popup, location.origin + "/").pathname === location.pathname;
      } catch (e) { return false; }
    })();
    // Not in a website's frame: never the popup, and asking costs the
    // worker a message for every frame the extension opens.
    if (!framed && chrome.tabs && typeof chrome.tabs.getCurrent === "function") {
      const getCurrent = chrome.tabs.getCurrent.bind(chrome.tabs);
      const current = () => Promise.resolve(getCurrent()).then((t) => {
        if (t && !(t.index >= 0 && t.index < 1e6)) { popup = true; return undefined; }
        if (t) popup = false;
        return t;
      });
      current().catch(() => {});
      put(chrome.tabs, "getCurrent", (callback) => {
        const p = current();
        if (typeof callback !== "function") return p;
        p.then((t) => callback(t), (e) => withLastError(e, callback));
      });
    }
    if (chrome.extension && typeof chrome.extension.getViews === "function") {
      const extension = chrome.extension;
      const getViews = extension.getViews.bind(extension);
      const views = (properties = {}) => {
        let list = [...(getViews(properties) || [])];
        if (popup && properties.type === "tab") list = list.filter((v) => v !== root);
        if (popup && (!properties.type || properties.type === "popup") && !list.includes(root)) list.push(root);
        return list;
      };
      put(extension, "getViews", views);
      // WebKit's getViews is read-only, and so is chrome.extension: both
      // ignore any redefinition without a word. The popup page's code
      // is then handed a `chrome` of its own, built on WebKit's, whose
      // extension namespace answers getViews and passes everything else
      // on (Malwarebytes lays itself out as a tab otherwise).
      if (popup && extension.getViews !== views) {
        const bound = new Map();
        const ownExtension = Object.create(extension);
        for (const key of Object.getOwnPropertyNames(extension)) {
          if (key === "getViews") continue;
          Object.defineProperty(ownExtension, key, { configurable: true, enumerable: true, get: () => {
            const v = extension[key];
            if (typeof v !== "function") return v;
            if (!bound.has(key)) bound.set(key, v.bind(extension));
            return bound.get(key);
          } });
        }
        Object.defineProperty(ownExtension, "getViews", { value: views, configurable: true, writable: true, enumerable: true });
        const ownChrome = Object.create(chrome);
        Object.defineProperty(ownChrome, "extension", { value: ownExtension, configurable: true, writable: true, enumerable: true });
        for (const key of ["chrome", "browser"]) {
          try { if (root[key] === chrome) root[key] = ownChrome; } catch (e) {}
        }
      }
    }
  }
  fill("extension", {
    getURL: (path) => runtime.getURL(path), ViewType: { TAB: "tab", POPUP: "popup" },
    sendRequest: (...args) => runtime.sendMessage(...args), onRequest: event(), onRequestExternal: event(),
    getExtensionTabs: () => [], setUpdateUrlData: () => {},
  });
  fill("tabs", {
    TabStatus: enumOf("unloaded", "loading", "complete"), MutedInfoReason: enumOf("user", "capture", "extension"),
    WindowType: enumOf("normal", "popup", "panel", "app", "devtools"),
    ZoomSettingsMode: enumOf("automatic", "manual", "disabled"),
    ZoomSettingsScope: { PER_ORIGIN: "per-origin", PER_TAB: "per-tab" },
    MAX_CAPTURE_VISIBLE_TAB_CALLS_PER_SECOND: 2, TAB_INDEX_NONE: -1,
    getZoomSettings: resolve({ mode: "automatic", scope: "per-origin", defaultZoomFactor: 1 }),
    setZoomSettings: resolve(undefined), onZoomChange: event(),
    onSelectionChanged: event(), onActiveChanged: event(), onHighlightChanged: event(),
    // group and ungroup: below, into Yab's folders.
    getSelected: (windowId, callback) => {
      const f = typeof windowId === "function" ? windowId : callback;
      chrome.tabs.query({ active: true, currentWindow: true }).then((t) => f && f(t[0]));
    },
    getAllInWindow: (windowId, callback) => {
      const f = typeof windowId === "function" ? windowId : callback;
      chrome.tabs.query({ currentWindow: true }).then((t) => f && f(t));
    },
  });
  if (chrome.tabs) {
    // Moving, sleeping and bringing forward tabs, by where they are in
    // the row, the one thing both sides agree on.
    const settle = () => new Promise((r) => setTimeout(r, 60));
    const byIndex = (api) => async (ids, extra) => {
      const out = [];
      for (const id of Array.isArray(ids) ? ids : [ids]) {
        const tab = await chrome.tabs.get(id);
        await native(api, [tab.index, extra]);
        await settle();
        out.push(await chrome.tabs.get(id).catch(() => tab));
      }
      return Array.isArray(ids) ? out : out[0];
    };
    const withCallback = (f) => (...args) => {
      const callback = args.length && typeof args[args.length - 1] === "function" ? args.pop() : null;
      const p = f(...args);
      if (!callback) return p;
      p.then((v) => callback(v), (e) => withLastError(e, callback));
    };
    fill("tabs", {
      // Into a folder (ExtensionGroups.swift), a new one or the one named.
      group: withCallback(async (options = {}) => {
        const ids = Array.isArray(options.tabIds) ? options.tabIds : [options.tabIds];
        const indices = [];
        for (const id of ids) indices.push((await chrome.tabs.get(id)).index);
        const id = await native("tabGroups.group", [{ indices, groupId: options.groupId }]);
        await regroup();
        await groupsSettled();
        return id;
      }),
      ungroup: withCallback(async (tabIds) => {
        const indices = [];
        for (const id of Array.isArray(tabIds) ? tabIds : [tabIds]) indices.push((await chrome.tabs.get(id)).index);
        await native("tabGroups.ungroup", [{ indices }]);
        await regroup();
        await groupsSettled();
      }),
      move: withCallback(async (ids, props = {}) => {
        const list = Array.isArray(ids) ? ids : [ids];
        const out = [];
        let at = props.index ?? -1;
        for (const id of list) {
          out.push(await byIndex("tabs.move")(id, at));
          if (at !== -1) at++;
        }
        return Array.isArray(ids) ? out : out[0];
      }),
      discard: withCallback((id) => id === undefined
        ? chrome.tabs.query({ active: false, currentWindow: true }).then((t) => t[0] && byIndex("tabs.discard")(t[0].id))
        : byIndex("tabs.discard")(id)),
      highlight: withCallback(async (info = {}) => {
        const first = Array.isArray(info.tabs) ? info.tabs[0] : info.tabs;
        await native("tabs.activate", [first]);
        await settle();
        return chrome.windows ? chrome.windows.getCurrent({ populate: true }) : undefined;
      }),
    });
  }
  fill("windows", {
    // Chrome's, and not WebKit's: Session Buddy subscribes to it at
    // start, inside a try, threw there and never reached its button's
    // listener. Never fired: a window's bounds are read when asked for.
    onBoundsChanged: event(),
    CreateType: enumOf("normal", "popup", "panel"), WindowType: enumOf("normal", "popup", "panel", "app", "devtools"),
    WindowState: { NORMAL: "normal", MINIMIZED: "minimized", MAXIMIZED: "maximized", FULLSCREEN: "fullscreen", LOCKED_FULLSCREEN: "locked-fullscreen" },
  });
  fill("storage", {
    managed: { get: resolve({}), getBytesInUse: resolve(0), onChanged: event() },
    AccessLevel: { TRUSTED_CONTEXTS: "TRUSTED_CONTEXTS", TRUSTED_AND_UNTRUSTED_CONTEXTS: "TRUSTED_AND_UNTRUSTED_CONTEXTS" },
  });
  // Items built with Object.create(null), Chrome stores them, WebKit
  // throws that an object is expected.
  for (const area of ["local", "sync", "session"]) {
    const store = chrome.storage && chrome.storage[area];
    if (!store || typeof store.set !== "function") continue;
    const set = store.set.bind(store);
    put(store, "set", (items, ...rest) => set(items && typeof items === "object" && Object.getPrototypeOf(items) !== Object.prototype ? Object.assign({}, items) : items, ...rest));
  }
  fill("scripting", {
    ExecutionWorld: { ISOLATED: "ISOLATED", MAIN: "MAIN", USER_SCRIPT: "USER_SCRIPT" },
    StyleOrigin: { AUTHOR: "AUTHOR", USER: "USER" },
  });
  // Older WebKit crashes when setIcon's null reset reaches actionSetIcon
  // without a JSON icon object (WebKit bug 299460, crash report 179).
  // Empty icon dictionaries reset it too, without that null pointer.
  // Leave real icons and invalid values to WebKit, including its errors.
  const iconAPIs = new Set();
  for (const api of [chrome, root.browser]) for (const name of ["action", "browserAction", "pageAction"]) {
    const action = api && api[name];
    if (!action || typeof action.setIcon !== "function" || iconAPIs.has(action)) continue;
    iconAPIs.add(action);
    const setIcon = action.setIcon.bind(action);
    put(action, "setIcon", (details, ...rest) => {
      if (details && typeof details === "object" && !Array.isArray(details) &&
          details.path == null && details.imageData == null && details.variants == null) {
        const safe = { ...details, path: {} };
        delete safe.variants;
        if ("imageData" in details) {
          safe.imageData = {};
          if (!("path" in details)) delete safe.path;
        }
        details = safe;
      }
      return setIcon(details, ...rest);
    });
  }
  // End of icon reset guard.
  // The popup an extension sets for its button, told to the browser too:
  // yab opens a popup itself (see Extensions.press), and has to know
  // which page it is now.
  // popup.html → popup.yab-action.html, for the extension's own pages
  // (ExtensionShims.standIn, the same name).
  const standIn = (path) => {
    if (typeof path !== "string" || !path || path.includes(".yab-action")) return path;
    let base = path, rest = "";
    const cut = path.search(/[?#]/);
    if (cut >= 0) { base = path.slice(0, cut); rest = path.slice(cut); }
    if (/^[a-z][a-z0-9+.-]*:/i.test(path)) {
      let u; try { u = new URL(path); } catch (e) { return path; }
      if (u.origin !== location.origin) return path;
      base = u.pathname; rest = u.search + u.hash;
    }
    const slash = base.lastIndexOf("/"), dot = base.lastIndexOf(".");
    return (dot > slash ? base.slice(0, dot) + ".yab-action" + base.slice(dot) : base + ".yab-action") + rest;
  };
  for (const name of ["action", "browserAction"]) {
    const a = chrome[name];
    if (!a || typeof a.setPopup !== "function") continue;
    const setPopup = a.setPopup.bind(a);
    put(a, "setPopup", (details = {}, callback) => {
      const tell = (index) => { try { return native("action.popup", [details.popup || "", index]).catch(() => {}); } catch (e) { return undefined; } };
      const told = typeof details.tabId === "number" && chrome.tabs
        ? chrome.tabs.get(details.tabId).then((t) => tell(t.index), () => {}) : tell(-1);
      // WebKit hears of a stand-in, so the page itself stays an
      // ordinary page (ExtensionShims.mendPopup), once the browser has
      // put the stand-in's file there.
      const p = Promise.resolve(told).then(() => setPopup(typeof details.popup === "string" ? { ...details, popup: standIn(details.popup) } : details));
      // A press that woke the worker, waiting for a listener that won't
      // come: the extension chose a popup for every tab, which opens.
      if (details.popup && typeof details.tabId !== "number") {
        p.then(() => { if (heldClicks.some((h) => h.popupChosen())) native("action.pressHeld", []).catch(() => {}); }, () => {});
      }
      if (typeof callback !== "function") return p;
      p.then(() => callback(), (e) => withLastError(e, callback));
    });
    if (typeof a.getPopup === "function") {
      const getPopup = a.getPopup.bind(a);
      put(a, "getPopup", (details, callback) => {
        const p = Promise.resolve(getPopup(details)).then((v) => typeof v === "string" ? v.split(".yab-action").join("") : v);
        if (typeof callback !== "function") return p;
        p.then((v) => callback(v), (e) => withLastError(e, callback));
      });
    }
  }
  fill("action", {
    getUserSettings: resolve({ isOnToolbar: true }), onUserSettingsChanged: event(),
    setBadgeTextColor: resolve(undefined), getBadgeTextColor: resolve([255, 255, 255, 255]),
  });
  fill("webNavigation", {
    onCreatedNavigationTarget: event(), onHistoryStateUpdated: event(), onReferenceFragmentUpdated: event(), onTabReplaced: event(),
    TransitionType: enumOf("link", "typed", "auto_bookmark", "auto_subframe", "manual_subframe", "generated",
      "start_page", "form_submit", "reload", "keyword", "keyword_generated"),
    TransitionQualifier: enumOf("client_redirect", "server_redirect", "forward_back", "from_address_bar"),
  });
  // Chrome hands a PDF to Adobe Acrobat through chrome.mimeHandler, an API
  // only Acrobat gets, and falls back to its own viewer when Acrobat lets go.
  // Without it Acrobat sends every PDF tab to its viewer.html, whose Adobe
  // frame never draws a page in WebKit: a spinner, for good (feedback #315,
  // evals/pdf/acrobat.py). With it there, Acrobat leaves the PDF to WebKit's
  // viewer and Fill & Sign, as Chromium's own viewer when it steps aside.
  if (!inContent && runtime && runtime.id === "efaidnbmnnnibpcajpcglclefindmkaj" && !chrome.mimeHandler) {
    put(chrome, "mimeHandler", {
      setMimeHandlerOptions: resolve(undefined), getStreamInfo: resolve(undefined),
      abortAndFallbackToNativeHandler: resolve(undefined),
    });
  }
  fill("webRequest", {
    OnBeforeRequestOptions: { BLOCKING: "blocking", REQUEST_BODY: "requestBody", EXTRA_HEADERS: "extraHeaders" },
    OnBeforeSendHeadersOptions: { REQUEST_HEADERS: "requestHeaders", BLOCKING: "blocking", EXTRA_HEADERS: "extraHeaders" },
    OnSendHeadersOptions: { REQUEST_HEADERS: "requestHeaders", EXTRA_HEADERS: "extraHeaders" },
    OnHeadersReceivedOptions: { BLOCKING: "blocking", RESPONSE_HEADERS: "responseHeaders", EXTRA_HEADERS: "extraHeaders" },
    OnAuthRequiredOptions: { RESPONSE_HEADERS: "responseHeaders", BLOCKING: "blocking", ASYNC_BLOCKING: "asyncBlocking", EXTRA_HEADERS: "extraHeaders" },
    OnResponseStartedOptions: { RESPONSE_HEADERS: "responseHeaders", EXTRA_HEADERS: "extraHeaders" },
    OnBeforeRedirectOptions: { RESPONSE_HEADERS: "responseHeaders", EXTRA_HEADERS: "extraHeaders" },
    OnCompletedOptions: { RESPONSE_HEADERS: "responseHeaders", EXTRA_HEADERS: "extraHeaders" },
    OnErrorOccurredOptions: { EXTRA_HEADERS: "extraHeaders" },
    ResourceType: resourceTypes, MAX_HANDLER_BEHAVIOR_CHANGED_CALLS_PER_10_MINUTES: 20,
    handlerBehaviorChanged: resolve(undefined), onActionIgnored: event(),
  });
  fill("declarativeNetRequest", {
    GUARANTEED_MINIMUM_STATIC_RULES: 30000, MAX_NUMBER_OF_REGEX_RULES: 1000, MAX_NUMBER_OF_SESSION_RULES: 5000,
    MAX_NUMBER_OF_UNSAFE_DYNAMIC_RULES: 5000, MAX_NUMBER_OF_UNSAFE_SESSION_RULES: 5000,
    MAX_GETMATCHEDRULES_CALLS_PER_INTERVAL: 20, GETMATCHEDRULES_QUOTA_INTERVAL: 10,
    DYNAMIC_RULESET_ID: "_dynamic", SESSION_RULESET_ID: "_session",
    getAvailableStaticRuleCount: resolve(30000), getDisabledRuleIds: resolve([]), updateStaticRules: resolve(undefined),
    testMatchOutcome: refuse("declarativeNetRequest.testMatchOutcome"), onRuleMatchedDebug: event(),
    RuleActionType: { BLOCK: "block", REDIRECT: "redirect", ALLOW: "allow", UPGRADE_SCHEME: "upgradeScheme",
      MODIFY_HEADERS: "modifyHeaders", ALLOW_ALL_REQUESTS: "allowAllRequests" },
    ResourceType: resourceTypes, HeaderOperation: enumOf("append", "set", "remove"),
    DomainType: { FIRST_PARTY: "firstParty", THIRD_PARTY: "thirdParty" },
    RequestMethod: enumOf("connect", "delete", "get", "head", "options", "patch", "post", "put", "other"),
    UnsupportedRegexReason: { SYNTAX_ERROR: "syntaxError", MEMORY_LIMIT_EXCEEDED: "memoryLimitExceeded" },
  });
  const contextTypes = enumOf("all", "page", "frame", "selection", "link", "editable", "image", "video", "audio",
    "launcher", "browser_action", "page_action", "action");
  fill("contextMenus", { ContextType: contextTypes, ItemType: enumOf("normal", "checkbox", "radio", "separator") });
  fill("menus", { ContextType: contextTypes, ItemType: enumOf("normal", "checkbox", "radio", "separator") });

  // Rules WebKit can't carry out, a header it doesn't know how to set,
  // say, are refused one by one, where Chrome would take them all. The
  // rest still go in: one rule yab can't honor shouldn't cost an
  // extension every other rule, or its startup.
  const dnr = chrome.declarativeNetRequest;
  // Before WebKit sees them, rules are put the way it takes them: a
  // redirect to one of the extension's own files by path rather than by
  // address, and without the resource types it has no name for: beside
  // one of those (csp_report among them), WebKit's translator also lost
  // sub_frame, xmlhttprequest, stylesheet and main_frame from the rule
  // (ExtensionRuleMends, which does the same to the rule sets it ships).
  const knownTypes = new Set(["main_frame", "sub_frame", "stylesheet", "script", "image", "font",
    "xmlhttprequest", "ping", "media", "websocket", "other"]);
  const unknownTypes = { has: (t) => !knownTypes.has(t) };
  const base = (() => { try { return runtime.getURL(""); } catch (e) { return ""; } })();
  const mendRule = (rule) => {
    if (!rule || typeof rule !== "object") return rule;
    const r = { ...rule, action: rule.action && { ...rule.action }, condition: rule.condition && { ...rule.condition } };
    const redirect = r.action && r.action.redirect;
    if (redirect && typeof redirect.url === "string" && base && redirect.url.startsWith(base)) {
      r.action.redirect = { extensionPath: "/" + redirect.url.slice(base.length) };
    }
    const c = r.condition;
    if (c && Array.isArray(c.resourceTypes)) {
      c.resourceTypes = c.resourceTypes.filter((t) => !unknownTypes.has(t));
      if (!c.resourceTypes.length) return null;
    }
    if (c && Array.isArray(c.excludedResourceTypes)) c.excludedResourceTypes = c.excludedResourceTypes.filter((t) => !unknownTypes.has(t));
    // WebKit can't compile a rule with requestMethods ("The request-method
    // string must be "get", …", for "get" itself), and a change holding one
    // compiles nothing: Tampermonkey's install redirects, all ["get"], never
    // applied. A GET-only condition is left out, near enough the same: a
    // navigation, what such rules are about, is a GET. Others are left to
    // WebKit, as leaving them out would widen the rule.
    if (c && Array.isArray(c.requestMethods) && c.requestMethods.length && c.requestMethods.every((m) => String(m).toLowerCase() === "get")) {
      delete c.requestMethods;
    }
    return r;
  };
  // Every change to an extension's rules has WebKit translate and compile
  // all of them again: 15 to 34 s of a core for AdBlock's 61,000 rules,
  // and WebKit answers only then. AdBlock changes its rules one call at a
  // time, a call for each filter list it updates, under a lock its popup
  // also waits on (so after "Pause on this site" its popup got no answer
  // for minutes and stayed blank), and WebKit compiled them one after
  // another for minutes after AdBlock was added, a core busy throughout
  // (the nightly stand's adblock profile idled at 99% CPU;
  // evals/extensions/adblock_dnr.py follows the compiled file).
  //
  // So the changes are gathered here, as Chromium's would be by then:
  // each call is answered at once, reading the rules back has it, and
  // once the calls stop for a moment (`quiet`), they go to WebKit as one
  // change for each kind of rule. Never while WebKit still compiles the
  // last one, unless that holds them back for `hold`: WebKit unloads an
  // extension's worker half a minute after its last event, and what is
  // only gathered here would go with it. A change that leaves the rules
  // as they are goes nowhere. A rule id used twice is refused at the call,
  // as Chromium and WebKit refuse it; anything else WebKit finds wrong with
  // a rule only as it takes the whole change costs that rule (`attempt`),
  // and is told to the browser rather than thrown.
  (() => {
    if (!dnr) return null;
    const quiet = 1000, hold = 8000;
    const actionTypes = new Set(["block", "redirect", "allow", "upgradeScheme", "modifyHeaders", "allowAllRequests"]);
    const report = (text) => { try { native("debug.error", ["declarativeNetRequest: " + text]).catch(() => {}); } catch (x) {} };
    // A rule as a string that doesn't depend on the order of its keys.
    const canon = (value) => JSON.stringify(value, (key, x) => x && typeof x === "object" && !Array.isArray(x)
      ? Object.keys(x).sort().reduce((o, k) => { o[k] = x[k]; return o; }, {}) : x);
    const overlay = (map, change) => {
      if (!change) return map;
      for (const id of change.remove) map.delete(id);
      for (const [id, rule] of change.add) map.set(id, rule);
      return map;
    };
    const rules = {};
    for (const [update, read] of [["updateSessionRules", "getSessionRules"], ["updateDynamicRules", "getDynamicRules"]]) {
      if (typeof dnr[update] !== "function" || typeof dnr[read] !== "function") continue;
      rules[update] = { name: update, update: dnr[update].bind(dnr), read: dnr[read].bind(dnr), getter: read, sent: null, pending: null };
    }
    const sets = typeof dnr.updateEnabledRulesets === "function" && typeof dnr.getEnabledRulesets === "function"
      ? { update: dnr.updateEnabledRulesets.bind(dnr), read: dnr.getEnabledRulesets.bind(dnr), sent: null, pending: null } : null;
    const shipped = (() => {
      try { return new Set(((runtime.getManifest().declarative_net_request || {}).rule_resources || []).map((r) => r && r.id)); }
      catch (e) { return new Set(); }
    })();
    // Calls and reads one at a time, in the order made.
    let chain = Promise.resolve();
    const serial = (work) => { const p = chain.then(work); chain = p.catch(() => {}); return p; };
    const realRules = async (kind) => new Map((await kind.read() || []).map((r) => [r.id, r]));
    const viewRules = async (kind) => overlay(overlay(await collapse(kind, await realRules(kind)), kind.sent), kind.pending);

    // universal: WebKit compiles an extension's enabled sets, dynamic and
    // session rules as one list, and traps, taking the browser down, when
    // more than 65,534 of its rules match every address (crash #39,
    // ExtensionRuleBudget in ExtensionRules.swift, which counts each
    // shipped set the same way). A set that would take the rest over is
    // kept off and told to the browser, for the extension's row; a dynamic
    // or session change that would is refused, as Chromium refuses one over
    // its rule limits.
    let budget = null;
    const ruleBudget = () => budget || (budget = new Promise((resolve) => resolve(native("dnr.budget", [])))
      .then((b) => b && typeof b.limit === "number" ? b : { limit: Infinity, sets: {} })
      .catch(() => { budget = null; return { limit: Infinity, sets: {} }; }));
    const everything = (c) => {
      if (typeof c.regexFilter === "string") return /^\^?(\.\*)*\$?$/.test(c.regexFilter);
      const url = c.urlFilter;
      if (typeof url !== "string" || !url.length) return true;
      return !url.startsWith("||") && /^[*|]*$/.test(url);
    };
    const universal = (rule) => {
      const c = (rule && rule.condition) || {}, type = rule && rule.action && rule.action.type;
      const domains = typeof c.regexFilter === "string" ? 0 : (Array.isArray(c.requestDomains) ? c.requestDomains.length : 0);
      const excluded = Array.isArray(c.excludedRequestDomains) ? c.excludedRequestDomains.length : 0;
      if (type === "allowAllRequests") return Math.max(domains, 1) + excluded;
      if (domains || !everything(c)) return 0;
      let made = Math.max(Array.isArray(c.requestMethods) ? c.requestMethods.length : 0, 1);
      if (c.initiatorDomains && c.excludedInitiatorDomains) made *= 2;
      if (type === "upgradeScheme") made *= 2;
      return made;
    };
    const universalOf = (map) => { let n = 0; for (const r of map.values()) n += universal(r); return n; };
    // Every kind's view but `except`, which the caller counts itself.
    const universalRules = async (except) => {
      let n = 0;
      for (const kind of Object.values(rules)) if (kind !== except) n += universalOf(await viewRules(kind));
      return n;
    };
    const universalSets = (on, b) => { let n = 0; for (const id of on) n += b.sets[id] || 0; return n; };
    // universal end

    // A regexFilter with alternatives ("a|b", "(a|b)"), which WebKit's
    // content rules can't express and refuse, is one rule per alternative:
    // Tampermonkey's install redirect, ^(?:https?|ftp)://…\.(?:user|tamper)
    // \.js…$, is four that WebKit takes. Each part's id is in a range of its own, SPLIT + id * PARTS +
    // n, and the extension's own rule is kept by the browser
    // (dnr.originals), so reading the rules back, a change, a removal and
    // getMatchedRules all speak the extension's ids, as in Chromium.
    // regex split: from here to its end, the browser runs it on static
    // rule sets too (ExtensionRuleMends.split).
    const SPLIT = 1073741824, PARTS = 16;
    // A regex as the plain ones its alternatives make: a(b|c)d is abd and
    // acd. A capturing group stays one in each, so \1 in a redirect means
    // the same text. Null when it can't be: an alternative under * or +,
    // a backreference, a lookaround, or more than PARTS.
    const alternatives = (source) => {
      let at = 0;
      const fail = () => { throw null; };
      const sequence = () => {
        let out = [""];
        const join = (parts) => {
          const next = [];
          for (const a of out) for (const b of parts) next.push(a + b);
          if (next.length > PARTS) fail();
          out = next;
        };
        while (at < source.length && source[at] !== ")" && source[at] !== "|") {
          const c = source[at];
          if (c === "\\") {
            if (/[1-9k]/.test(source[at + 1] || "")) fail();
            join([source.slice(at, at + 2)]); at += 2; continue;
          }
          if (c === "[") {
            let end = at + 1;
            if (source[end] === "^") end++;
            if (source[end] === "]") end++;
            while (end < source.length && source[end] !== "]") end += source[end] === "\\" ? 2 : 1;
            if (end >= source.length) fail();
            join([source.slice(at, end + 1)]); at = end + 1; continue;
          }
          if (c === "(") {
            at++;
            let capturing = true;
            if (source[at] === "?") {
              if (source[at + 1] !== ":") fail();
              capturing = false;
              at += 2;
            }
            const parts = choice();
            if (source[at] !== ")") fail();
            at++;
            const quant = /^(\*\??|\+\??|\?\??|\{\d+(,\d*)?\}\??)/.exec(source.slice(at));
            const wrap = (part) => (capturing ? "(" : "(?:") + part + ")";
            if (parts.length === 1) {
              join([wrap(parts[0]) + (quant ? quant[0] : "")]);
              if (quant) at += quant[0].length;
              continue;
            }
            if (quant && quant[0] !== "?") fail();
            if (quant) at += 1;
            const each = parts.map((part) => capturing ? wrap(part) : part);
            join(quant ? [...each, capturing ? "()" : ""] : each);
            continue;
          }
          join([c]); at++;
        }
        return out;
      };
      const choice = () => {
        let all = sequence();
        while (source[at] === "|") { at++; all = all.concat(sequence()); if (all.length > PARTS) fail(); }
        return all;
      };
      try {
        const all = choice();
        return at === source.length ? [...new Set(all)] : null;
      } catch (e) { if (e === null) return null; throw e; }
    };
    // The extension's rules for each kind, as the browser keeps them.
    const originals = {};
    const kept = async (kind) => {
      if (!originals[kind.name]) {
        let read = null;
        try { read = await native("dnr.originals", [{ kind: kind.name }]); } catch (e) {}
        originals[kind.name] = new Map(Object.entries(read || {}).map(([id, rule]) => [Number(id), rule]));
      }
      return originals[kind.name];
    };
    // WebKit's rules as the extension made them.
    // WebKit's rules as the extension made them: split parts as their
    // rule, and a rule WebKit could take nothing of still there, as in
    // Chrome, which takes it.
    const collapse = async (kind, real) => {
      const own = await kept(kind);
      // No part left in WebKit: what is kept went with them (session rules
      // die with the extension's context, reloaded as its permissions are
      // granted), and showing it would tell the extension its rules are
      // there when they are not, and it would never set them again.
      if (![...real.keys()].some((id) => id >= SPLIT)) {
        if (own.size && !kind.sent && !kind.pending) { own.clear(); await keep(kind); }
        return real;
      }
      const out = new Map();
      for (const [id, rule] of real) {
        if (id < SPLIT) { out.set(id, rule); continue; }
        const mine = Math.floor((id - SPLIT) / PARTS);
        if (!out.has(mine)) out.set(mine, own.get(mine) || { ...rule, id: mine });
      }
      for (const [id, rule] of own) if (!out.has(id)) out.set(id, rule);
      return out;
    };
    // A part as WebKit's content rules read it: no escape where none is
    // needed (\# and, in a class, \?: Tampermonkey's [^\#\?] was refused,
    // [^#?] is taken), and a group of one alternative that needs no group
    // left as its words. A capturing one stays, for regexSubstitution.
    const plain = (regex) => {
      let out = "", inClass = false;
      for (let i = 0; i < regex.length; i++) {
        const c = regex[i];
        if (c === "\\" && i + 1 < regex.length) {
          const n = regex[i + 1];
          const needed = inClass ? "\\]^-" : "\\.*+?()[]{}|^$/";
          if (/[A-Za-z0-9]/.test(n) || needed.includes(n)) out += c + n; else out += n;
          i++;
          continue;
        }
        if (c === "[" && !inClass) inClass = true;
        else if (c === "]" && inClass) inClass = false;
        out += c;
      }
      // (?:x) alone, with no quantifier after it: x.
      let before;
      do { before = out; out = out.replace(/\(\?:([^()|]*)\)(?![*+?{])/g, "$1"); } while (out !== before);
      return out;
    };
    // regex split end
    // What WebKit's rules take, as its isRegexSupported says ({1,9}, a
    // lazy +?, alternatives: no), asked once a regex. No answer is taken
    // as yes, and WebKit has the last word (`attempt`).
    const checkRegex = typeof dnr.isRegexSupported === "function" ? dnr.isRegexSupported.bind(dnr) : null;
    const supported = new Map();
    const regexOK = async (regex) => {
      if (!checkRegex) return true;
      if (!supported.has(regex)) {
        let ok = true;
        try { const r = await checkRegex({ regex }); if (r && r.isSupported === false) ok = false; } catch (e) {}
        supported.set(regex, ok);
      }
      return supported.get(regex);
    };
    // The extension's rules as WebKit can take them: a regex with
    // alternatives that splits is split, and a regex WebKit says it can't
    // take, whole or a part, is left out here and said, rather than sent
    // and refused: each refusal is a compile of every rule again, and
    // Tampermonkey's sites' {1,9} cost its install rule its place.
    //
    // Rules Chrome takes and WebKit refuses, AdBlock 6.49's among them;
    // WebKit refuses the whole change for one of them, taking nothing of
    // it. What WebKit can take of such a rule, written its way, goes to
    // WebKit as the rule's part, and a rule it can take nothing of stands
    // there as one that matches nothing (`standIn`): it reads back as the
    // extension made it, as in Chromium, and nothing is said, as the
    // extension did nothing wrong. A modifyHeaders header WebKit doesn't
    // know ("The header `x-acceptable-ads` is not recognized", Acceptable
    // Ads' $header filters; WebKit knows a fixed list of names) is left
    // out of the rule once WebKit refuses it (`unknownHeaders`), and a
    // rule left with no header stands in. A redirect to a data: address
    // (eyeo's $rewrite=abp-resource:blank-js and the like), which WebKit
    // refuses ("`redirect` specified a non-HTTP `url`"), goes to a file of
    // those bytes in the extension's folder (dnr.redirect), as a static
    // rule set's do (ExtensionRuleMends.mendRuleSets).
    const unknownHeaders = new Set(), refused = new Set(), redirects = new Map();
    const standIn = (rule) => ({ id: SPLIT + rule.id * PARTS, priority: 1, action: { type: "block" },
      condition: { urlFilter: "||left-out.yab.invalid^", resourceTypes: ["other"] } });
    const redirectFile = async (url) => {
      if (!redirects.has(url)) {
        let path = null;
        try { path = await native("dnr.redirect", [url]); } catch (e) {}
        redirects.set(url, typeof path === "string" && path ? path : null);
      }
      return redirects.get(url);
    };
    // The rule as WebKit takes it: itself, another rule, or null when
    // WebKit takes nothing of it.
    const translate = async (rule) => {
      const action = rule && rule.action;
      if (!action) return rule;
      if (action.type === "modifyHeaders") {
        const known = (list) => Array.isArray(list)
          ? list.filter((h) => !(h && typeof h.header === "string" && unknownHeaders.has(h.header.toLowerCase()))) : list;
        const request = known(action.requestHeaders), response = known(action.responseHeaders);
        const same = (a, b) => a === b || a.length === b.length;
        if (same(request, action.requestHeaders) && same(response, action.responseHeaders)) return rule;
        if (!(request && request.length) && !(response && response.length)) return null;
        const written = { ...action };
        for (const [key, list] of [["requestHeaders", request], ["responseHeaders", response]]) {
          if (list && list.length) written[key] = list; else delete written[key];
        }
        return { ...rule, action: written };
      }
      const redirect = action.type === "redirect" && action.redirect;
      if (redirect && typeof redirect.url === "string" && /^data:/i.test(redirect.url)) {
        const path = await redirectFile(redirect.url);
        return path ? { ...rule, action: { ...action, redirect: { extensionPath: path } } } : null;
      }
      return rule;
    };
    const expand = async (rule) => {
      const fits = Number.isInteger(rule.id) && rule.id >= 1 && rule.id < SPLIT / PARTS;
      const made = fits ? await translate(rule) : rule;
      const out = (await split(made, fits)).filter((part) => !refused.has(canon(part)));
      if (!fits || (out.length === 1 && out[0] === rule)) return out;
      if (!out.length) return [standIn(rule)];
      return out.map((part) => part.id === rule.id ? { ...part, id: SPLIT + rule.id * PARTS } : part);
    };
    const split = async (rule, fits) => {
      if (!rule) return [];
      const regex = rule.condition && rule.condition.regexFilter;
      if (typeof regex !== "string") return [rule];
      const parts = regex.includes("|") && fits ? alternatives(regex) : null;
      if (!parts || parts.length < 2) {
        if (await regexOK(regex)) return [rule];
        report("rule " + rule.id + " left out, WebKit can't take its regexFilter " + regex);
        return [];
      }
      const out = [];
      for (const [n, part] of parts.entries()) {
        const written = plain(part);
        if (await regexOK(written)) out.push({ ...rule, id: SPLIT + rule.id * PARTS + n, condition: { ...rule.condition, regexFilter: written } });
        else report("rule " + rule.id + ", part " + n + " left out, WebKit can't take its regexFilter " + written);
      }
      return out;
    };
    const toWebKit = async (kind, view, real) => {
      const out = new Map(), own = await kept(kind), before = JSON.stringify([...own]);
      for (const id of [...own.keys()]) if (!view.has(id)) own.delete(id);
      for (const rule of view.values()) {
        // Standing in already, as this worker's last life found: not sent
        // again for WebKit to refuse.
        const stand = Number.isInteger(rule.id) && real.get(SPLIT + rule.id * PARTS);
        if (stand && own.has(rule.id) && canon(own.get(rule.id)) === canon(rule) && canon(stand) === canon(standIn(rule))) {
          out.set(stand.id, stand);
          continue;
        }
        const made = await expand(rule);
        if (made.length === 1 && made[0] === rule) { own.delete(rule.id); out.set(rule.id, rule); continue; }
        // Kept as the extension made it, whatever WebKit could take of it.
        own.set(rule.id, rule);
        for (const part of made) out.set(part.id, part);
      }
      if (JSON.stringify([...own]) !== before) await keep(kind);
      return out;
    };
    const keep = async (kind) => {
      await native("dnr.originals", [{ kind: kind.name, set: Object.fromEntries(await kept(kind)) }]).catch(() => {});
    };
    const viewSets = async () => {
      const on = new Set(await sets.read() || []);
      for (const change of [sets.sent, sets.pending]) if (change) for (const [id, enabled] of change) enabled ? on.add(id) : on.delete(id);
      return on;
    };

    let timer = null, first = 0, flushing = null;
    const schedule = () => {
      const now = Date.now();
      if (!first) first = now;
      clearTimeout(timer);
      timer = setTimeout(flush, Math.max(0, Math.min(quiet, first + hold - now)));
    };
    const pendingAny = () => (sets && sets.pending) || Object.values(rules).some((k) => k.pending);
    const flush = () => {
      timer = null;
      if (!pendingAny()) { first = 0; return; }
      // WebKit still compiling the last change: wait for it, up to `hold`.
      if (flushing && Date.now() - first < hold) { flushing.then(() => { if (!timer) schedule(); }); return; }
      first = 0;
      const sending = [];
      if (sets && sets.pending) { sets.sent = sets.pending; sets.pending = null; sending.push(sendSets()); }
      for (const kind of Object.values(rules)) {
        if (!kind.pending) continue;
        kind.sent = kind.pending; kind.pending = null;
        sending.push(sendRules(kind));
      }
      const done = Promise.all(sending).then(() => {
        if (flushing === done) flushing = null;
        if (pendingAny() && !timer) schedule();
      });
      flushing = done;
    };
    const sendSets = async () => {
      const change = sets.sent;
      try {
        const on = new Set(await sets.read() || []);
        const enableRulesetIds = [], disableRulesetIds = [];
        for (const [id, enabled] of change) {
          if (enabled && !on.has(id)) enableRulesetIds.push(id);
          if (!enabled && on.has(id)) disableRulesetIds.push(id);
        }
        if (enableRulesetIds.length || disableRulesetIds.length) await sets.update({ enableRulesetIds, disableRulesetIds });
      } catch (e) { report("updateEnabledRulesets, as WebKit compiled: " + String(e && e.message || e)); }
      finally { if (sets.sent === change) sets.sent = null; }
    };
    const sendRules = async (kind) => {
      const change = kind.sent;
      try {
        const real = await realRules(kind);
        const view = overlay(await collapse(kind, new Map(real)), change);
        // WebKit takes a change whole or not at all: a rule it refuses is
        // learned from (a header it doesn't know) or stands in, and the
        // change is made again without it.
        for (let left = 100; ; left--) {
          const after = await toWebKit(kind, view, real);
          const removeRuleIds = [...real.keys()].filter((id) => !after.has(id) || canon(after.get(id)) !== canon(real.get(id)));
          const addRules = [...after.values()].filter((r) => !real.has(r.id) || canon(real.get(r.id)) !== canon(r));
          if (!removeRuleIds.length && !addRules.length) return;
          try {
            // Without an empty list: Safari's WebKit took one as an error
            // (AdBlock leaves them out for it too).
            await kind.update({ ...(removeRuleIds.length ? { removeRuleIds } : {}), ...(addRules.length ? { addRules } : {}) });
            return;
          } catch (e) {
            const message = String(e && e.message || e);
            const at = /rule at index (\d+)/.exec(message);
            const rule = at && addRules[Number(at[1])];
            if (!rule || left <= 0) throw e;
            const header = /The header `([^`]+)` is not recognized/.exec(message);
            if (header && !unknownHeaders.has(header[1].toLowerCase())) { unknownHeaders.add(header[1].toLowerCase()); continue; }
            refused.add(canon(rule));
            // Any other address is Chrome's to take: it stands in, unsaid.
            if (!/non-HTTP `url`/.test(message)) report("rule " + rule.id + " left out, " + message + " " + canon(rule).slice(0, 800));
          }
        }
      } catch (e) { report(kind.name + ", as WebKit compiled: " + String(e && e.message || e)); }
      finally { if (kind.sent === change) kind.sent = null; }
    };

    // Rule sets already as asked are left out, as Chromium passes over
    // them. WebKit counts a disabled set it is asked to disable as one
    // fewer enabled, so with none enabled the count went below zero and
    // it refused: "The number of enabled static rulesets exceeds the
    // limit" (AdBlock disables all of its sets as it starts).
    const enableSets = (options = {}) => serial(async () => {
      const off = (options && options.disableRulesetIds) || [];
      const on = (options && options.enableRulesetIds) || [];
      const unknown = [...off, ...on].find((id) => !shipped.has(id));
      if (unknown !== undefined) throw new Error("declarativeNetRequest.updateEnabledRulesets(): Invalid ruleset id '" + unknown + "'.");
      if (!off.length && !on.length) return undefined;
      // Validate the whole change before touching the queued one. Skipping
      // an oversized replacement while applying its disables would answer
      // success with every previously active filter turned off.
      const b = await ruleBudget();
      const enabled = await viewSets();
      for (const id of off) enabled.delete(id);
      let total = universalSets(enabled, b) + await universalRules(null);
      for (const id of on) {
        if (enabled.has(id)) continue;
        const cost = b.sets[id] || 0;
        if (total + cost > b.limit) {
          // Keep the existing warning, without clearing warnings for the
          // requested disables: those rules have not been turned off.
          try { native("dnr.leftOff", [[id], []]).catch(() => {}); } catch (x) {}
          throw new Error("declarativeNetRequest.updateEnabledRulesets(): With these rule sets there would be " + (total + cost)
            + " rules that match every address, more than the " + b.limit + " the browser can compile.");
        }
        total += cost;
        enabled.add(id);
      }
      const change = new Map(sets.pending || []);
      for (const id of off) change.set(id, false);
      for (const id of on) change.set(id, true);
      if (off.length) {
        try { native("dnr.leftOff", [[], off]).catch(() => {}); } catch (x) {}
      }
      sets.pending = change;
      schedule();
      return undefined;
    });
    const updateRules = (kind, options = {}) => serial(async () => {
      const remove = ((options && options.removeRuleIds) || []).filter((id) => typeof id === "number");
      // A rule WebKit couldn't take, as it refuses it when it reads a
      // change, is left out here, where WebKit would have refused it.
      const add = ((options && options.addRules) || []).map(mendRule).filter((rule) => {
        if (!rule) return false;
        const fault = !Number.isInteger(rule.id) || rule.id < 1 ? "an id that is not a positive integer"
          : !rule.action || !actionTypes.has(rule.action.type) ? "an action type WebKit doesn't know"
          : !rule.condition || typeof rule.condition !== "object" ? "no condition"
          : rule.priority !== undefined && !(Number.isInteger(rule.priority) && rule.priority >= 1) ? "a priority that is not a positive integer"
          : null;
        if (fault) report("rule " + rule.id + " left out, " + fault);
        return !fault;
      });
      if (!remove.length && !add.length) return undefined;
      const view = await viewRules(kind);
      for (const id of remove) view.delete(id);
      const seen = new Set();
      for (const rule of add) {
        const id = rule && rule.id;
        if (seen.has(id) || view.has(id)) throw new Error("Rule with id " + id + " does not have a unique ID.");
        seen.add(id);
      }
      // universal: a change that would take the list over WebKit's limit
      // is refused whole, as Chromium refuses one over its rule limits.
      const adding = add.reduce((n, rule) => n + universal(rule), 0);
      if (adding) {
        const b = await ruleBudget();
        const total = (sets ? universalSets(await viewSets(), b) : 0) + await universalRules(kind) + universalOf(view) + adding;
        if (total > b.limit) {
          throw new Error("declarativeNetRequest." + kind.name + "(): With these rules there would be " + total
            + " rules that match every address, more than the " + b.limit + " the browser can compile.");
        }
      }
      const change = kind.pending || { remove: new Set(), add: new Map() };
      for (const id of remove) { change.add.delete(id); change.remove.add(id); }
      for (const rule of add) change.add.set(rule.id, rule);
      kind.pending = change;
      schedule();
      return undefined;
    });
    const readRules = (kind, filter) => serial(async () => {
      const ids = filter && Array.isArray(filter.ruleIds) ? new Set(filter.ruleIds) : null;
      return [...(await viewRules(kind)).values()].filter((r) => !ids || ids.has(r.id));
    });
    const answer = (p, callback, ...value) => {
      if (typeof callback !== "function") return p;
      p.then((r) => callback(...(value.length ? [r] : [])), (e) => withLastError(e, callback));
    };
    if (sets) {
      put(dnr, "updateEnabledRulesets", (options, callback) => answer(enableSets(options), callback));
      put(dnr, "getEnabledRulesets", (callback) => answer(serial(async () => [...await viewSets()]), callback, true));
    }
    // A test run reads what WebKit itself holds (evals/extensions/
    // tampermonkey_redirect.py), not the extension's view of it.
    if (__YAB_VERBOSE__) put(root, "__yabRealRules", async (name) => rules[name] ? [...(await realRules(rules[name])).values()] : null);
    // Matches of a part are its rule's, in the extension's ids.
    if (typeof dnr.getMatchedRules === "function") {
      const matched = dnr.getMatchedRules.bind(dnr);
      put(dnr, "getMatchedRules", (filter, callback) => {
        if (typeof filter === "function") { callback = filter; filter = undefined; }
        const p = Promise.resolve(filter === undefined ? matched() : matched(filter)).then((r) => {
          if (!r || !Array.isArray(r.rulesMatchedInfo)) return r;
          return { ...r, rulesMatchedInfo: r.rulesMatchedInfo.map((info) => info && info.rule && info.rule.ruleId >= SPLIT
            ? { ...info, rule: { ...info.rule, ruleId: Math.floor((info.rule.ruleId - SPLIT) / PARTS) } } : info) };
        });
        return answer(p, callback, true);
      });
    }
    for (const kind of Object.values(rules)) {
      put(dnr, kind.name, (options, callback) => answer(updateRules(kind, options), callback));
      put(dnr, kind.getter, (filter, callback) => {
        if (typeof filter === "function") { callback = filter; filter = undefined; }
        return answer(readRules(kind, filter), callback, true);
      });
    }
  })();
  if (dnr && typeof dnr.isRegexSupported === "function") {
    const original = dnr.isRegexSupported.bind(dnr);
    put(dnr, "isRegexSupported", (options, callback) => {
      const p = Promise.resolve(original(options)).then((r) => r || { isSupported: false, reason: "syntaxError" },
        () => ({ isSupported: false, reason: "syntaxError" }));
      if (typeof callback !== "function") return p;
      p.then((r) => callback(r));
    });
  }

  // Only definitions from startup or an install listener survive a worker.
  // A later selection or tab event must never write its words to settings.
  const menuLifetime = { started: false, installing: 0, stopped: false };
  const installedMenus = (listener, details) => {
    menuLifetime.installing++;
    try { return listener(details); } finally { menuLifetime.installing--; }
  };
  if (background && typeof root.addEventListener === "function") {
    const add = root.addEventListener.bind(root), remove = root.removeEventListener.bind(root);
    const wrapped = new WeakMap();
    put(root, "addEventListener", (type, listener, options) => {
      if (!listener || (typeof listener !== "function" && typeof listener !== "object")) return add(type, listener, options);
      if (!wrapped.has(listener)) wrapped.set(listener, function (...args) {
        menuLifetime.started = true;
        return typeof listener === "function" ? listener.apply(this, args) : listener.handleEvent(...args);
      });
      return add(type, wrapped.get(listener), options);
    });
    put(root, "removeEventListener", (type, listener, options) => remove(type, wrapped.get(listener) || listener, options));
  }
  if (background) {
    const seen = new WeakSet();
    for (const space of Object.keys(chrome)) {
      let ns; try { ns = chrome[space]; } catch (e) { continue; }
      if (!ns || typeof ns !== "object") continue;
      const names = new Set();
      for (let o = ns; o && o !== Object.prototype; o = Object.getPrototypeOf(o)) Object.getOwnPropertyNames(o).forEach((k) => names.add(k));
      for (const key of names) {
        if (!/^on[A-Z]/.test(key)) continue;
        let target; try { target = ns[key]; } catch (e) { continue; }
        if (!target || typeof target.addListener !== "function" || seen.has(target)) continue;
        seen.add(target);
        const add = target.addListener.bind(target), wrapped = new WeakMap();
        put(target, "addListener", (listener, ...rest) => {
          if (typeof listener !== "function") return add(listener, ...rest);
          if (!wrapped.has(listener)) wrapped.set(listener, function (...args) {
            menuLifetime.started = true;
            return listener.apply(this, args);
          });
          return add(wrapped.get(listener), ...rest);
        });
        if (typeof target.removeListener === "function") {
          const remove = target.removeListener.bind(target);
          put(target, "removeListener", (listener) => remove(wrapped.get(listener) || listener));
        }
        if (typeof target.hasListener === "function") {
          const has = target.hasListener.bind(target);
          put(target, "hasListener", (listener) => has(wrapped.get(listener) || listener));
        }
      }
    }
  }

  // Context menu entries for places yab has no menu for, the old
  // toolbar button contexts are the button's menu now, and there is no
  // app launcher at all.
  const menuAPIs = new WeakSet();
  const menuState = { kept: new Map(), made: new Set(), removed: new Set(), cleared: false,
    replayed: false, revision: 0, timer: null, generation: null, dirty: false, loading: false };
  for (const name of ["contextMenus", "menus"]) {
    const menus = chrome[name];
    if (!menus || typeof menus.create !== "function" || menuAPIs.has(menus)) continue;
    menuAPIs.add(menus);
    // And ftp:// patterns: WebKit has no ftp and refuses the whole entry
    // for one (Chrono lists ftp://*/* beside http and https); Chrome takes
    // them. An entry left with none matches nowhere, as an ftp one would.
    const patterns = (list) => {
      if (!Array.isArray(list)) return list;
      const kept = list.filter((p) => typeof p !== "string" || !/^ftp:/i.test(p));
      return kept.length ? kept : ["https://yab.invalid/*"];
    };
    const mend = (props) => {
      if (!props || typeof props !== "object") return props;
      const out = { ...props };
      for (const key of ["documentUrlPatterns", "targetUrlPatterns"]) if (key in out) out[key] = patterns(out[key]);
      if (!Array.isArray(props.contexts)) return out;
      const contexts = [...new Set(props.contexts.map((c) => c === "browser_action" || c === "page_action" ? "action" : c).filter((c) => c !== "launcher"))];
      return { ...out, contexts: contexts.length ? contexts : ["page"] };
    };
    const create = menus.create.bind(menus), update = menus.update.bind(menus);
    put(menus, "create", (props, callback) => create(mend(props), callback));
    put(menus, "update", (id, props, callback) => update(id, mend(props), callback));

    // WebKit loses the worker's items. Keep at most 64 static definitions,
    // never later titles or ids made for a page, and replay after imports.
    if (background && typeof menus.remove === "function" && typeof menus.removeAll === "function") {
      const state = menuState, { kept, made, removed } = state;
      const eligible = () => !menuLifetime.started || menuLifetime.installing > 0;
      const definition = (props) => {
        const out = {};
        for (const key of ["id", "title", "type", "contexts", "parentId", "checked", "enabled", "visible", "documentUrlPatterns", "targetUrlPatterns"]) {
          if (key in props) out[key] = props[key];
        }
        return JSON.parse(JSON.stringify(out));
      };
      const save = () => {
        state.dirty = true;
        if (state.timer || !state.generation || menuLifetime.stopped) return;
        state.timer = setTimeout(() => {
          state.timer = null;
          if (menuLifetime.stopped) return;
          state.dirty = false;
          native("menus.save", [JSON.stringify([...kept]), state.generation]).catch(() => {});
        }, 300);
      };
      const forget = (id) => {
        if (!state.replayed) removed.add(id);
        kept.delete(id);
        for (const [key, props] of [...kept]) if (props.parentId === id) forget(key);
      };
      const make = menus.create, change = menus.update, drop = menus.remove, dropAll = menus.removeAll;
      put(menus, "create", function (props, callback) {
        const id = props && props.id, at = state.revision;
        const named = typeof id === "string" || typeof id === "number";
        const keep = named && eligible(), plain = keep ? definition(props) : null;
        if (named && !state.replayed) made.add(id);
        return make.call(menus, props, function (...args) {
          if (!runtime.lastError && keep && at === state.revision && (kept.has(id) || kept.size < 64)) {
            kept.set(id, plain); save();
          }
          if (typeof callback === "function") return callback.apply(this, args);
        });
      });
      put(menus, "update", function (id, props, callback) {
        const at = state.revision, plain = props && eligible() && kept.has(id) ? definition(props) : null;
        return change.call(menus, id, props, function (...args) {
          if (!runtime.lastError && plain && at === state.revision && kept.has(id)) {
            // Its creation title is the template, including a literal %s.
            delete plain.title; delete plain.id;
            kept.set(id, { ...kept.get(id), ...plain }); save();
          }
          if (typeof callback === "function") return callback.apply(this, args);
        });
      });
      put(menus, "remove", function (id, callback) {
        state.revision++; forget(id); save();
        return drop.call(menus, id, callback);
      });
      put(menus, "removeAll", function (callback) {
        state.revision++; state.cleared = true; kept.clear(); save();
        return dropAll.call(menus, callback);
      });
      if (!state.loading) {
        state.loading = true;
        native("menus.load", []).then((stored) => {
          if (!stored || typeof stored.generation !== "string" || menuLifetime.stopped) return;
          state.generation = stored.generation;
          const restore = () => {
            if (menuLifetime.stopped) return;
            let saved = [];
            try { saved = JSON.parse(stored.items); } catch (e) {}
            if (!Array.isArray(saved)) saved = [];
            const definitions = new Map(saved);
            const forgotten = (id, visited = new Set()) => {
              if (removed.has(id)) return true;
              if (visited.has(id)) return false;
              visited.add(id);
              const props = definitions.get(id);
              return !!props && props.parentId != null && forgotten(props.parentId, visited);
            };
            if (!state.cleared) for (const [id, props] of saved) {
              if (made.has(id) || forgotten(id) || kept.size >= 64) continue;
              kept.set(id, props);
              try { make.call(menus, { ...props, id }, () => { void runtime.lastError; }); } catch (e) {}
            }
            state.replayed = true; made.clear(); removed.clear();
            if (state.dirty) save();
          };
          setTimeout(() => { if (!afterImport(restore)) restore(); }, 0);
        }, () => {});
      }
    }
  }

  // webRequest listeners with options WebKit doesn't take, blocking
  // needs a policy-installed extension in Chrome's MV3 too; extra headers
  // WebKit reports anyway, are added with the options it does take.
  if (chrome.webRequest) for (const key of Object.keys(chrome.webRequest)) {
    const target = chrome.webRequest[key];
    if (!/^on[A-Z]/.test(key) || !target || typeof target.addListener !== "function") continue;
    const add = target.addListener.bind(target);
    const remove = typeof target.removeListener === "function" ? target.removeListener.bind(target) : null;
    const has = typeof target.hasListener === "function" ? target.hasListener.bind(target) : null;
    const wrapped = new WeakMap();
    put(target, "addListener", (listener, filter, spec) => {
      const wantedTypes = filter && Array.isArray(filter.types) ? new Set(filter.types) : null;
      if (typeof listener === "function" && !wrapped.has(listener)) {
        wrapped.set(listener, (details, ...rest) => {
          // WebKit 26 reports iframe documents as main_frame, and its
          // main_frame/sub_frame listener filters are reversed (bugs 304828,
          // 323979). Filtering both here also works once WebKit fixes them.
          const documentType = details && (details.type === "main_frame" || details.type === "sub_frame")
            ? (typeof details.frameId === "number" && details.frameId > 0 ? "sub_frame" : "main_frame")
            : details && details.type;
          if (wantedTypes && !wantedTypes.has(documentType)) return;
          return listener(details && documentType !== details.type ? { ...details, type: documentType } : details, ...rest);
        });
      }
      const callback = wrapped.get(listener) || listener;
      if (wantedTypes && (wantedTypes.has("main_frame") || wantedTypes.has("sub_frame"))) {
        filter = { ...filter, types: [...new Set([...filter.types, "main_frame", "sub_frame"])] };
      }
      // WebKit can't read ws:// and wss:// patterns, and refuses the
      // whole listener over one; Chrome watches sockets too. The
      // listener is kept for everything else.
      if (filter && Array.isArray(filter.urls)) {
        const urls = filter.urls.filter((u) => !/^wss?:/i.test(u));
        if (!urls.length) return;
        filter = { ...filter, urls };
      }
      // Added after a worker's startup, WebKit refuses it; Chrome takes
      // it. It isn't heard, but neither does it stop the code that added
      // it, a listener for every request can't join the late list
      // (it would wake the worker for all of them).
      const late = (e) => { if (!/startup/i.test(String(e && e.message))) throw e; };
      // A resource type WebKit doesn't know ("webtransport",
      // "webbundle") makes it refuse the whole listener, and AdBlock's
      // worker threw that as it started: it never ran, its popup had no
      // page to describe, and every start was another error (feedback
      // #100). Chrome's other types are kept; the unknown one is left
      // out, as it would never come from WebKit anyway.
      const typed = (f) => {
        for (let tries = 0; ; tries++) {
          try { return f(filter); } catch (e) {
            const unknown = /because '([^']+)' is an unknown resource type/.exec(String(e && e.message));
            if (!unknown || tries > 8 || !filter || !Array.isArray(filter.types)) throw e;
            const types = filter.types.filter((t) => t !== unknown[1]);
            if (!types.length) return;
            filter = { ...filter, types };
          }
        }
      };
      try {
        if (!Array.isArray(spec)) return typed((f) => add(callback, f));
        const kept = spec.filter((s) => s === "requestHeaders" || s === "responseHeaders" || s === "requestBody");
        try { return typed((f) => add(callback, f, kept)); } catch (e) { if (/startup/i.test(String(e && e.message))) throw e; return typed((f) => add(callback, f)); }
      } catch (e) { late(e); }
    });
    if (remove) put(target, "removeListener", (listener) => {
      const callback = wrapped.get(listener) || listener;
      wrapped.delete(listener);
      return remove(callback);
    });
    if (has) put(target, "hasListener", (listener) => has(wrapped.get(listener) || listener));
  }

  // A proxy's password (ExtensionProxy.swift). Chrome asks the extension's
  // webRequest.onAuthRequired when its proxy answers 407; Network takes the
  // password with the proxy instead, before any request. So the worker's
  // listeners are kept here and asked, as Chromium would ask them, as the
  // proxy is set, at each start of the worker with its proxy in force, and
  // every few minutes after (Proton VPN's change). WebKit's own event,
  // which can't wait for an answer, still gets the listener.
  if (background && chrome.proxy && chrome.proxy.settings && chrome.webRequest && chrome.webRequest.onAuthRequired) {
    const auth = chrome.webRequest.onAuthRequired, listeners = new Set();
    const addAuth = auth.addListener.bind(auth), removeAuth = auth.removeListener ? auth.removeListener.bind(auth) : null;
    put(auth, "addListener", (listener, ...rest) => {
      if (typeof listener === "function") listeners.add(listener);
      try { return addAuth(listener, ...rest); } catch (e) { /* kept here regardless */ }
    });
    if (removeAuth) put(auth, "removeListener", (listener) => { listeners.delete(listener); try { return removeAuth(listener); } catch (e) {} });
    const proxies = async (value) => {
      const out = [];
      if (!value || typeof value !== "object") return out;
      const rules = value.rules || {};
      for (const key of ["singleProxy", "proxyForHttps", "proxyForHttp", "proxyForFtp", "fallbackProxy"]) {
        const p = rules[key];
        if (p && p.host) out.push({ host: p.host, port: p.port || (p.scheme === "https" ? 443 : p.scheme && p.scheme.startsWith("socks") ? 1080 : 80) });
      }
      let data = value.pacScript && value.pacScript.data;
      // A script named by address (pacScript.url) read here too, for the
      // proxies it names.
      if (typeof data !== "string" && value.pacScript && typeof value.pacScript.url === "string") {
        try { data = await (await fetch(value.pacScript.url, { cache: "no-store" })).text(); } catch (e) {}
      }
      if (typeof data === "string") {
        for (const m of data.matchAll(/(?:PROXY|HTTPS|SOCKS5?)\s+([A-Za-z0-9.-]+):(\d+)/g)) out.push({ host: m[1], port: Number(m[2]) });
      }
      const seen = new Set();
      return out.filter((p) => !seen.has(p.host + ":" + p.port) && seen.add(p.host + ":" + p.port));
    };
    const askOne = (listener, details) => new Promise((resolve) => {
      let done = false;
      const finish = (answer) => { if (!done) { done = true; resolve(answer); } };
      setTimeout(() => finish(null), 20000);
      try {
        const answer = listener(details, finish);
        if (answer && typeof answer.then === "function") answer.then(finish, () => finish(null));
        else if (answer !== undefined) finish(answer);
      } catch (e) { finish(null); }
    });
    const ask = async (value) => {
      for (const proxy of await proxies(value)) {
        const details = { requestId: "yab-proxy", url: "https://www.example.com/", method: "GET", frameId: 0, parentFrameId: -1,
          tabId: -1, type: "main_frame", timeStamp: Date.now(), isProxy: true, challenger: { host: proxy.host, port: proxy.port },
          scheme: "basic", realm: "", statusCode: 407, statusLine: "HTTP/1.1 407 Proxy Authentication Required", responseHeaders: [] };
        for (const listener of [...listeners]) {
          const answer = await askOne(listener, details);
          const creds = answer && answer.authCredentials;
          if (creds && typeof creds.username === "string") {
            await native("proxy.credentials", [{ host: proxy.host, port: proxy.port, username: creds.username, password: String(creds.password || "") }]).catch(() => {});
            break;
          }
        }
      }
    };
    const settings = chrome.proxy.settings, set = settings.set.bind(settings);
    let current = null, timer = null;
    const keep = (value) => {
      current = value;
      clearInterval(timer);
      if (!value || (value.mode !== "fixed_servers" && value.mode !== "pac_script")) return;
      setTimeout(() => ask(value).catch(() => {}), 0);
      timer = setInterval(() => ask(current).catch(() => {}), 5 * 60 * 1000);
    };
    put(settings, "set", (details, callback) => {
      const p = Promise.resolve(set(details)).then((r) => { keep(details && details.value); return r; });
      if (typeof callback !== "function") return p;
      p.then(() => callback(), (e) => withLastError(e, callback));
    });
    // A worker woken with its proxy in force asks again, its listeners
    // added by then.
    setTimeout(() => {
      Promise.resolve(settings.get({})).then((r) => {
        if (r && r.levelOfControl === "controlled_by_this_extension") keep(r.value);
      }).catch(() => {});
    }, 1500);
  }

  // A tab that is gone: Chrome answers webNavigation.getAllFrames and
  // getFrame with null, WebKit refuses ("Tab not found"). AdBlock asks
  // for a tab it remembers as its worker starts, and the refusal, never
  // caught, stopped the worker at every launch.
  if (chrome.webNavigation) {
    for (const name of ["getAllFrames", "getFrame"]) {
      const f = chrome.webNavigation[name];
      if (typeof f !== "function") continue;
      put(chrome.webNavigation, name, (details, callback) => {
        const p = Promise.resolve().then(() => f.call(chrome.webNavigation, details))
          .catch((e) => { if (/not found/i.test(String(e && e.message))) return null; throw e; });
        if (typeof callback !== "function") return p;
        p.then((v) => callback(v), (e) => withLastError(e, callback));
      });
    }
  }

  // Tabs as Chromium describes them. Every tab has a groupId (-1 when in
  // no group, yab has none), which code tests before anything else;
  // and with the "tabs" permission an extension sees every tab's address
  // and title, where WebKit shows them only for sites it has host
  // access to.
  if (chrome.tabs) {
    const seesTabs = (() => { try { return (runtime.getManifest().permissions || []).includes("tabs"); } catch (e) { return false; } })();
    const isTab = (t) => t && typeof t === "object" && typeof t.id === "number";
    // Mends in place; a promise only when the browser has to be asked.
    const grouped = (tabs, members) => {
      for (const t of tabs) try { t.groupId = members && t.index >= 0 && members[t.index] !== undefined ? members[t.index] : -1; } catch (e) {}
    };
    const mend = (list) => {
      const tabs = list.filter(isTab);
      grouped(tabs, groupMembers);
      const waits = [];
      // The port reports group events asynchronously. Its index snapshot can
      // still precede a tab insertion when query() completes. Read membership
      // for this result before exposing group IDs to the extension.
      if (groupsAllowed && tabs.length) {
        waits.push(native("tabGroups.membership", []).then((v) => grouped(tabs, v && v.members), () => {}));
      }
      const blind = seesTabs ? tabs.filter((t) => !t.url && t.index >= 0) : [];
      if (blind.length) {
        waits.push(native("tabs.describe", [blind.map((t) => t.index)]).then((info) => {
          blind.forEach((t, i) => {
            const d = info && info[i];
            if (!d) return;
            try { if (d.url) t.url = d.url; if (d.title && !t.title) t.title = d.title; } catch (e) {}
          });
        }, () => {}));
      }
      return waits.length ? Promise.all(waits) : null;
    };
    const tabsIn = (value) => Array.isArray(value) ? value.flatMap(tabsIn)
      : isTab(value) ? [value] : value && Array.isArray(value.tabs) ? value.tabs : [];
    const mendResult = (target, name) => {
      if (!target || typeof target[name] !== "function") return;
      const original = target[name].bind(target);
      put(target, name, (...args) => {
        const callback = typeof args[args.length - 1] === "function" ? args.pop() : null;
        // tabs.query({groupId}): WebKit knows no groups, the shim filters.
        let inGroup;
        if (name === "query" && args[0] && typeof args[0] === "object" && "groupId" in args[0]) {
          inGroup = args[0].groupId;
          args[0] = Object.assign({}, args[0]);
          delete args[0].groupId;
        }
        const p = Promise.resolve(original(...args)).then(async (r) => {
          await mend(tabsIn(r));
          return inGroup === undefined || !Array.isArray(r) ? r : r.filter((t) => t.groupId === inGroup);
        });
        if (!callback) return p;
        p.then((r) => callback(r), (e) => withLastError(e, callback));
      });
    };
    for (const name of ["query", "get", "getCurrent", "create", "update", "duplicate", "move", "reload"]) mendResult(chrome.tabs, name);
    for (const name of ["get", "getAll", "getCurrent", "getLastFocused", "create"]) mendResult(chrome.windows, name);
    // Listeners given a tab: the tab is mended before they see it.
    const mendArgs = (target, positions, after = null) => {
      if (!target || typeof target.addListener !== "function") return;
      const add = target.addListener.bind(target), remove = target.removeListener.bind(target);
      const wrapped = new Map();
      put(target, "addListener", (listener, ...rest) => {
        const w = function (...args) {
          const pending = mend(positions.map((i) => args[i]));
          const deliver = () => {
            if (after) after(args);
            return listener.apply(this, args);
          };
          if (!pending) return deliver();
          pending.then(deliver);
        };
        wrapped.set(listener, w);
        return add(w, ...rest);
      });
      put(target, "removeListener", (listener) => { const w = wrapped.get(listener); wrapped.delete(listener); return remove(w || listener); });
      put(target, "hasListener", (listener) => wrapped.has(listener));
      return wrapped;
    };
    mendArgs(chrome.tabs.onCreated, [0]);
    tabUpdatedListeners = mendArgs(chrome.tabs.onUpdated, [2], (args) => {
      // WebKit blanks changeInfo.url too without host access. Restoring
      // only tab.url left Figma's real OAuth listener waiting forever: it
      // reads changeInfo.url, not the tab. A present, empty field means a
      // URL change; never add one to a status/title-only notification.
      const info = args[1], tab = args[2];
      if (seesTabs && info && info.url === "" && tab && tab.url)
        args[1] = Object.assign({}, info, { url: tab.url });
    }) || null;
    mendArgs(chrome.action && chrome.action.onClicked, [0]);
    mendArgs(chrome.contextMenus && chrome.contextMenus.onClicked, [1]);
    mendArgs(chrome.menus && chrome.menus.onClicked, [1]);
    mendArgs(chrome.commands && chrome.commands.onCommand, [1]);
  }

  // Permissions. WebKit knows its own and throws on any other name,
  // where Chrome answers false. The ones yab answers itself are
  // yab's to grant: those a manifest names are granted, optional
  // ones are asked for.
  // chrome.alarms.create has returned a Promise since Chrome 111.
  // Older WebKit returns void: Jam 5.96 chains .then() during startup,
  // throws, and never updates the site-access state its popup reads (#1526).
  // Keep native scheduling and errors. A read queued after the void call
  // waits for the native creation before resolving, without scheduling twice.
  if (chrome.alarms && typeof chrome.alarms.create === "function") {
    const alarms = chrome.alarms, create = alarms.create.bind(alarms);
    put(alarms, "create", function (...args) {
      const result = create(...args);
      if (typeof args[args.length - 1] === "function" || (result && typeof result.then === "function")) return result;
      const name = typeof args[0] === "string" ? args[0] : "";
      return alarms.get(name).then(() => undefined);
    });
  }

  if (chrome.permissions) {
    const webkit = new Set(["activeTab", "alarms", "clipboardWrite", "contextMenus", "cookies", "declarativeNetRequest",
      "declarativeNetRequestFeedback", "declarativeNetRequestWithHostAccess", "menus", "nativeMessaging", "scripting",
      "storage", "tabs", "unlimitedStorage", "webNavigation", "webRequest"]);
    const ours = new Set(["bookmarks", "history", "downloads", "downloads.open", "downloads.shelf", "downloads.ui",
      "tabGroups", "sidePanel", "offscreen", "notifications", "tts", "fontSettings", "management", "identity",
      "identity.email", "idle", "power", "privacy", "browsingData", "sessions", "topSites", "search", "system.cpu",
      "system.memory", "system.storage", "system.display", "readingList", "contentSettings", "proxy", "favicon",
      // Figma requests pageCapture together with scripting and clipboardWrite.
      // Its MHTML API is answered by yab; treating it as unknown refuses the
      // entire request before the extension can ask for consent.
      "clipboardRead", "geolocation", "userScripts", "pageCapture"]);
    const manifest = (() => { try { return runtime.getManifest() || {}; } catch (e) { return {}; } })();
    const declared = new Set(manifest.permissions || []);
    const split = (list = []) => ({
      theirs: list.filter((p) => webkit.has(p)), mine: list.filter((p) => ours.has(p)),
      unknown: list.filter((p) => !webkit.has(p) && !ours.has(p)),
    });
    // A site with a port, as Chromium takes it ("http://127.0.0.1:8080/*"),
    // WebKit refuses as no pattern at all and throws: 1Password asks
    // contains() for the page in front, and threw on every page with a
    // port. WebKit's patterns match every port of a host anyway, so the
    // port is left out.
    //
    // And schemes WebKit can't match, which make it refuse the whole call
    // where Chrome takes them. Proton VPN asks contains() and request()
    // for http, https, ftp, ws and wss in one list: both failed over ftp,
    // its popup stayed on "Allow VPN permissions", and its Next button did
    // nothing (feedback #161, #166). Yab opens no ftp (or urn) address, so
    // there is nothing there to hold and they are left out; a socket's
    // site is its page's, ws:// as http:// and wss:// as https://, so
    // they are held exactly when those are.
    const portless = (list) => [...new Set((Array.isArray(list) ? list : []).flatMap((o) => {
      if (typeof o !== "string") return [o];
      if (/^(ftp|urn):/i.test(o)) return [];
      return [o.replace(/^ws(s?):\/\//i, "http$1://").replace(/^([a-z*][a-z0-9+.*-]*:\/\/[^/:]*):(\d+|\*)(?=\/)/i, "$1")];
    }))];
    const p = chrome.permissions;
    const contains = p.contains.bind(p), getAll = p.getAll.bind(p), remove = p.remove.bind(p);
    const granted = () => native("permissions.granted", []).then((list) => new Set([...declared, ...(list || [])]));
    const withCb = (f) => (arg, callback) => {
      const pr = f(arg || {});
      if (typeof callback !== "function") return pr;
      pr.then((v) => callback(v), (e) => withLastError(e, callback));
    };
    put(p, "contains", withCb(async ({ permissions = [], origins: asked = [] }) => {
      const origins = portless(asked);
      const { theirs, mine, unknown } = split(permissions);
      if (unknown.length) return false;
      if (mine.length) { const have = await granted(); if (!mine.every((m) => have.has(m))) return false; }
      return theirs.length || origins.length ? contains({ permissions: theirs, origins }) : true;
    }));
    put(p, "request", withCb(async ({ permissions = [], origins: asked = [] }) => {
      const origins = portless(asked);
      const { theirs, mine, unknown } = split(permissions);
      if (unknown.length) return false;
      // Sites it doesn't hold yet are asked for by yab, not through
      // WebKit's request: WebKit counts every site as held once one of
      // them is, github.com under every site, and says yes to that
      // without asking or giving anything.
      // Asked all at once: a popup that closes itself 200 ms after asking
      // (Proton VPN's) is gone before a slower answer comes.
      const held = await Promise.all(origins.map((origin) => contains({ origins: [origin] })));
      const wanting = origins.filter((origin, i) => !held[i]);
      const have = mine.length ? await granted() : new Set();
      const missing = mine.filter((m) => !have.has(m));
      const lacking = theirs.length && !(await contains({ permissions: theirs })) ? theirs : [];
      // Then one card for all of it, as Chromium asks: Figma's sites and its
      // pageCapture came as two cards in a row. WebKit's own permissions
      // are given by yab too, never through WebKit's request: that asked
      // in a card of its own, and threw outside a click's moment, where
      // Chrome carries the click with a message (NordPass's every copy
      // button has its worker ask for clipboardWrite, register 1019).
      if ((wanting.length || missing.length || lacking.length) &&
          !(await native("permissions.ask", [wanting, missing, lacking]))) return false;
      if (mine.includes("tabGroups")) groupsGranted = true;
      return true;
    }));
    put(p, "getAll", (callback) => {
      const pr = (async () => {
        const all = await getAll();
        const have = await granted();
        return { ...all, permissions: [...new Set([...(all.permissions || []), ...[...have].filter((m) => ours.has(m))])] };
      })();
      if (typeof callback !== "function") return pr;
      pr.then((v) => callback(v), (e) => withLastError(e, callback));
    });
    put(p, "remove", withCb(async ({ permissions = [], origins: asked = [] }) => {
      const origins = portless(asked);
      const { theirs, mine } = split(permissions);
      if (mine.length) await native("permissions.remove", [mine]);
      if (mine.includes("tabGroups")) groupsGranted = false;
      return theirs.length || origins.length ? remove({ permissions: theirs, origins }) : true;
    }));
    // A press of its button lends it the site in front (activeTab), and
    // WebKit tells onAdded of the lent site, and onRemoved as it goes
    // back. Chrome tells neither: the site was never the extension's, and
    // getAll leaves it out. Transpose reloads the tab in front on any
    // onAdded with sites, so each press started the video over (feedback
    // #271). The sites told are kept to those getAll holds now and didn't
    // before (onRemoved: held before, not now); an event left with nothing
    // isn't told.
    const covers = (pattern, origin) => {
      if (pattern === "<all_urls>" || pattern === origin) return true;
      const a = /^([^:]+):\/\/([^/]*)/.exec(pattern), b = /^([^:]+):\/\/([^/]*)/.exec(origin);
      if (!a || !b) return false;
      const schemes = a[1] === "*" ? ["*", "http", "https", "ws", "wss"] : [a[1]];
      if (!schemes.includes(b[1])) return false;
      const host = b[2].replace(/^\*\./, "");
      return a[2] === "*" || a[2] === b[2] || a[2] === host ||
        (a[2].startsWith("*.") && (host === a[2].slice(2) || host.endsWith(a[2].slice(1))));
    };
    const held = (list, origin) => list.some((pattern) => covers(pattern, origin));
    let before = null;
    const look = () => getAll().then((all) => all.origins || [], () => null);
    look().then((list) => { if (before === null) before = list; });
    let queue = Promise.resolve();
    const told = (added, details) => queue = queue.then(async () => {
      const now = await look();
      const was = before;
      if (now) before = now;
      if (!details || !Array.isArray(details.origins) || !details.origins.length || !now) return details;
      const origins = details.origins.filter((o) => added ? held(now, o) && !(was && held(was, o)) : !held(now, o) && (!was || held(was, o)));
      if (origins.length === details.origins.length) return details;
      if (!origins.length && !(details.permissions || []).length) return null;
      return { ...details, origins };
    });
    for (const [name, added] of [["onAdded", true], ["onRemoved", false]]) {
      const event = p[name];
      if (!event || typeof event.addListener !== "function") continue;
      const add = event.addListener.bind(event), drop = event.removeListener.bind(event);
      const has = typeof event.hasListener === "function" ? event.hasListener.bind(event) : null;
      const stands = new WeakMap();
      // Each event is looked at once, for every listener of this context
      // (each may be handed its own copy of it).
      const looked = new Map();
      const filtered = (details) => {
        let key; try { key = JSON.stringify(details); } catch (e) { key = String(details); }
        if (!looked.has(key)) {
          looked.set(key, told(added, details));
          setTimeout(() => looked.delete(key), 1000);
        }
        return looked.get(key);
      };
      put(event, "addListener", (listener, ...rest) => {
        if (typeof listener !== "function") return add(listener, ...rest);
        let stand = stands.get(listener);
        if (!stand) {
          stand = function (details) {
            filtered(details).then((kept) => { if (kept) listener.call(this, kept); }, () => listener.call(this, details));
          };
          stands.set(listener, stand);
        }
        return add(stand, ...rest);
      });
      put(event, "removeListener", (listener) => drop(stands.get(listener) || listener));
      if (has) put(event, "hasListener", (listener) => has(stands.get(listener) || listener));
    }
  }

  // chrome.userScripts, what Tampermonkey, Violentmonkey and the
  // advanced rules of the ad blockers run on, carried out through
  // WebKit's registered content scripts. The browser writes each script
  // into a file of the extension's (content scripts come from files),
  // wrapped so the globs Chrome takes are honored and, for Chrome's
  // USER_SCRIPT world, so its messages reach onUserScriptMessage rather
  // than the extension's own onMessage. The list lives with the browser,
  // and is registered again whenever the worker starts.
  const scripting = chrome.scripting;
  // YAB_PORT_TRACE=1 (a diagnosis, evals/feedback-283): every scripting
  // call the worker makes, counted by what it names, told every 3 s.
  if (__YAB_PORT_TRACE__ && scripting && background) {
    const counts = {};
    let dirty = false;
    for (const name of ["registerContentScripts", "unregisterContentScripts", "updateContentScripts", "getRegisteredContentScripts", "executeScript", "insertCSS", "removeCSS"]) {
      const f = scripting[name];
      if (typeof f !== "function") continue;
      put(scripting, name, function (...args) {
        const a = args[0];
        const what = Array.isArray(a) ? a.map((s) => s && s.id) : a && a.ids ? a.ids : a && a.files ? a.files : a && a.func ? "func" : "";
        const k = name + " " + JSON.stringify(what).slice(0, 80);
        counts[k] = (counts[k] || 0) + 1;
        dirty = true;
        return f.apply(scripting, args);
      });
    }
    const started = Date.now();
    setInterval(() => {
      if (!dirty) return;
      dirty = false;
      try { native("debug.error", ["scripting trace: " + JSON.stringify({ s: Math.round((Date.now() - started) / 1000), counts }).slice(0, 1900)]).catch(() => {}); } catch (e) {}
    }, 3000);
  }
  // What an extension registers for a page's own world has yab's
  // passkey patch before it, as its manifest's do (see prepare): a
  // password manager keeps a reference to navigator.credentials as it
  // finds it, and falls back to that. An update that names no world gets
  // it too; in any other world the patch does nothing.
  if (scripting) {
    // Chrome accepts its own chrome-extension:// URL in files; WebKit
    // looks it up as a package-relative path and silently injects nothing.
    const ownRoot = runtime.getURL("");
    const ownFiles = (files) => files.map((file) => typeof file === "string" && ownRoot && file.startsWith(ownRoot)
      ? file.slice(ownRoot.length) : file);
    // WebKit takes no file: pattern in a registered script, "file:///*"
    // nor Chrome's "file://*/*", and refuses the whole call over one.
    // Rabby Wallet registers its page provider, the window.ethereum
    // every dapp looks for, for file, http and https pages, and in Yab
    // no site found the wallet (feedback #107). The file patterns are
    // left out of what it matches when others remain, and out of what
    // it excludes.
    const noFiles = (list) => list.filter((p) => typeof p !== "string" || !/^file:/i.test(p));
    const fileHost = (list) => Array.isArray(list) && noFiles(list).length ? noFiles(list) : list;
    const idleCallers = new Set(__YAB_IDLE__);
    const callsIdle = (files) => files.some((f) => typeof f === "string" && idleCallers.has(f.replace(/^\/+/, "")));
    // And one that makes an AudioContext (Transpose's player-main.js) has
    // yab-audio.js first (ExtensionShims.audio): its sound starts with the
    // page's next click, as Chromium starts it in a page clicked before.
    const audioCallers = new Set(__YAB_AUDIO__);
    const callsAudio = (files) => files.some((f) => typeof f === "string" && audioCallers.has(f.replace(/^\/+/, "")));
    const helpers = (files) => [...(callsAudio(files) && !files.includes("yab-audio.js") ? ["yab-audio.js"] : []),
                                ...(callsIdle(files) && !files.includes("yab-idle.js") ? ["yab-idle.js"] : [])];
    const first = (scripts, updating) => Array.isArray(scripts) ? scripts.map((s) => {
      if (s && (Array.isArray(s.matches) || Array.isArray(s.excludeMatches))) {
        s = { ...s };
        if (s.matches) s.matches = fileHost(s.matches);
        if (Array.isArray(s.excludeMatches)) { s.excludeMatches = noFiles(s.excludeMatches); if (!s.excludeMatches.length) delete s.excludeMatches; }
      }
      // Registered while yab was Fast, and kept by WebKit since: the
      // patch under its old name, a file gone now.
      if (s && Array.isArray(s.js)) s = { ...s, js: s.js.filter((f) => f !== "fast-passkeys.js") };
      if (!s || !Array.isArray(s.js)) return s;
      const world = String(s.world || "").toUpperCase();
      if (!s.js.includes("yab-passkeys.js") && (world === "MAIN" || (updating && !world))) s = { ...s, js: ["yab-passkeys.js", ...s.js] };
      if (world === "MAIN" && helpers(s.js).length) s = { ...s, js: [...helpers(s.js), ...s.js] };
      return s;
    }) : scripts;
    // A file put into a page's own world that calls requestIdleCallback
    // (Proton Pass's elements.js) has it put there first (yab-idle.js,
    // see ExtensionShims.idle); in its own world the shim has it already.
    const execute = scripting.executeScript;
    // A worker's injection into a tab whose page is still loading waits for
    // the page to load, 500 ms at most: password managers inject their
    // autofill into every frame as it opens, and that landed before the
    // page's first frame (evals/stand/breakdown.py, 2026-10-12).
    const loaded = async (injection) => {
      const tabId = injection && injection.target && injection.target.tabId;
      if (typeof tabId !== "number" || !chrome.tabs || typeof chrome.tabs.get !== "function") return;
      const until = Date.now() + 500;
      while (Date.now() < until) {
        let tab;
        try { tab = await chrome.tabs.get(tabId); } catch (e) { return; }
        if (!tab || tab.status !== "loading") return;
        await new Promise((resolve) => setTimeout(resolve, 40));
      }
    };
    if (typeof execute === "function") {
      put(scripting, "executeScript", async function (injection, ...rest) {
        await loaded(injection);
        if (injection && Array.isArray(injection.files)) injection = { ...injection, files: ownFiles(injection.files) };
        if (injection && String(injection.world || "").toUpperCase() === "MAIN" && Array.isArray(injection.files) &&
            helpers(injection.files).length) {
          injection = { ...injection, files: [...helpers(injection.files), ...injection.files] };
        }
        // Its own world guarded first (yabStorageGuard), where no content
        // script of its own has put the shim (Fabric has none).
        if (injection && injection.target && String(injection.world || "ISOLATED").toUpperCase() !== "MAIN" &&
            (Array.isArray(injection.files) || typeof injection.func === "function")) {
          const guard = { target: injection.target, func: yabStorageGuard };
          if (injection.injectImmediately) guard.injectImmediately = true;
          try { await execute.call(scripting, guard); } catch (e) {}
        }
        return execute.call(scripting, injection, ...rest);
      });
    }
    for (const name of ["insertCSS", "removeCSS"]) {
      const original = scripting[name];
      if (typeof original !== "function") continue;
      put(scripting, name, function (injection, ...rest) {
        if (injection && Array.isArray(injection.files)) injection = { ...injection, files: ownFiles(injection.files) };
        return original.call(scripting, injection, ...rest);
      });
    }
    // What is registered, told to Yab after each change and as the worker
    // starts: a spare tab compiles the scripts that run at document_start
    // ahead of the page it will show (ContentWarm.swift).
    // YAB_CONTENT_WARM=0: none of it, as before (an A/B).
    const listRegistered = __YAB_WARM__ ? scripting.getRegisteredContentScripts : null;
    const tellRegistered = () => {
      if (typeof listRegistered !== "function") return;
      Promise.resolve().then(() => listRegistered.call(scripting)).then((list) => native("scripting.registered", [
        (list || []).map((s) => ({ js: s.js || [], runAt: s.runAt || "document_idle", world: s.world || "ISOLATED", matches: s.matches || [] }))]))
        .catch(() => {});
    };
    const told = (p) => { if (listRegistered && p && typeof p.then === "function") p.then(tellRegistered, () => {}); return p; };
    if (background && listRegistered) setTimeout(tellRegistered, 2000);
    const update = scripting.updateContentScripts;
    if (typeof update === "function") {
      put(scripting, "updateContentScripts", function (scripts, ...rest) { return told(update.call(scripting, first(scripts, true), ...rest)); });
    }
    if (listRegistered && typeof scripting.unregisterContentScripts === "function") {
      const bare = scripting.unregisterContentScripts;
      put(scripting, "unregisterContentScripts", function (...args) { return told(bare.apply(scripting, args)); });
    }
    // Registering an id that is already registered is refused, in Chrome
    // too. Registered scripts outlive the worker, so an extension that
    // registers at every start without looking first (Bitwarden's
    // passkey scripts, once signed in) is refused on each restart, and
    // the refusal is an error on its card. What it asked for is put in
    // place of what was there instead, which is what it wanted;
    // the same id twice in one call is still refused.
    const register = scripting.registerContentScripts;
    const unregister = scripting.unregisterContentScripts;
    const registered = scripting.getRegisteredContentScripts;
    if (typeof register === "function") {
      put(scripting, "registerContentScripts", function (scripts, callback) {
        const list = first(scripts, false);
        const p = register.call(scripting, list).catch(async (e) => {
          const ids = Array.isArray(list) ? list.map((s) => s && s.id) : [];
          if (!/Duplicate ID/i.test(String(e && e.message)) || !ids.length || new Set(ids).size !== ids.length ||
              typeof unregister !== "function" || typeof registered !== "function") throw e;
          const found = await registered.call(scripting, { ids });
          const there = found.map((s) => s.id);
          if (!there.length) throw e;
          // The same scripts asked for again: Chrome refuses and leaves
          // them, and so nothing is done. Put in again, WebKit would add
          // them to every open page they match at once, beside the copy
          // already running there (Bitwarden's passkey scripts, at each
          // start of its worker).
          const norm = (s) => JSON.stringify([
            (s.js || []).map((f) => String(f).replace(/^\//, "")), (s.css || []).map((f) => String(f).replace(/^\//, "")),
            [...(s.matches || [])].sort(), [...(s.excludeMatches || [])].sort(), !!s.allFrames,
            String(s.runAt || "document_idle").toLowerCase(), String(s.world || "ISOLATED").toUpperCase(), !!s.matchOriginAsFallback]);
          if (found.length === list.length && list.every((s) => found.some((f) => f.id === s.id && norm(f) === norm(s)))) return;
          await unregister.call(scripting, { ids: there });
          return register.call(scripting, list);
        });
        told(p);
        if (typeof callback !== "function") return p;
        p.then(() => callback(), (e) => withLastError(e, callback));
      });
    }
  }
  const wantsUserScripts = (() => { try { return (runtime.getManifest().permissions || []).includes("userScripts"); } catch (e) { return false; } })();
  if (!chrome.userScripts && wantsUserScripts && scripting && typeof scripting.registerContentScripts === "function") {
    const tag = "yab-us-";
    const content = async (script) => ({
      id: tag + script.id,
      matches: script.matches && script.matches.length ? script.matches : ["*://*/*"],
      excludeMatches: script.excludeMatches || [],
      js: [await native("userScripts.file", [script])],
      runAt: script.runAt || "document_idle",
      allFrames: !!script.allFrames,
      world: script.world === "MAIN" ? "MAIN" : "ISOLATED",
      persistAcrossSessions: false,
    });
    const registered = async () => (await scripting.getRegisteredContentScripts()).filter((s) => s.id.startsWith(tag));
    const list = () => native("userScripts.list", []).then((l) => l || []);
    const save = (l) => native("userScripts.save", [l]);
    const sync = async () => {
      const want = await list();
      const have = new Set((await registered()).map((s) => s.id));
      const missing = want.filter((s) => !have.has(tag + s.id));
      if (!missing.length) return;
      const scripts = await Promise.all(missing.map(content));
      // Two starts of the worker racing each other: the later one takes
      // the registration over.
      await scripting.registerContentScripts(scripts).catch(async (e) => {
        if (!/duplicate/i.test(String(e && e.message))) throw e;
        await scripting.unregisterContentScripts({ ids: scripts.map((s) => s.id) }).catch(() => {});
        await scripting.registerContentScripts(scripts);
      });
    };
    const pick = (filter, l) => filter && Array.isArray(filter.ids) ? l.filter((s) => filter.ids.includes(s.id)) : l;
    const api = {
      register: async (scripts) => {
        const l = await list();
        for (const s of scripts) if (l.some((o) => o.id === s.id)) throw new Error("Duplicate script id '" + s.id + "'");
        await scripting.registerContentScripts(await Promise.all(scripts.map(content)));
        await save([...l, ...scripts]);
      },
      update: async (scripts) => {
        const l = await list();
        const merged = scripts.map((s) => {
          const old = l.find((o) => o.id === s.id);
          if (!old) throw new Error("Script with id '" + s.id + "' does not exist");
          return { ...old, ...s };
        });
        await scripting.unregisterContentScripts({ ids: merged.map((s) => tag + s.id) }).catch(() => {});
        await scripting.registerContentScripts(await Promise.all(merged.map(content)));
        await save(l.map((o) => merged.find((m) => m.id === o.id) || o));
      },
      unregister: async (filter) => {
        const l = await list();
        const gone = pick(filter, l);
        const ids = (await registered()).map((s) => s.id).filter((id) => gone.some((g) => tag + g.id === id));
        if (ids.length) await scripting.unregisterContentScripts({ ids });
        await save(l.filter((o) => !gone.includes(o)));
      },
      getScripts: async (filter) => pick(filter, await list()),
      configureWorld: (properties) => native("userScripts.world", [properties || {}]),
      getWorldConfigurations: () => native("userScripts.worlds", []),
      resetWorldConfiguration: (worldId) => native("userScripts.world", [{ worldId, reset: true }]),
      execute: async (injection) => {
        const file = await native("userScripts.file", [{ id: "execute-" + Date.now(), js: injection.js || [], world: injection.world }]);
        return scripting.executeScript({ target: injection.target, files: [file], world: injection.world === "MAIN" ? "MAIN" : "ISOLATED",
          injectImmediately: !!injection.injectImmediately });
      },
    };
    const callbacks = Object.fromEntries(Object.entries(api).map(([k, f]) => [k, (...args) => {
      const callback = args.length && typeof args[args.length - 1] === "function" ? args.pop() : null;
      const p = f(...args);
      if (!callback) return p;
      p.then((v) => callback(v), (e) => withLastError(e, callback));
    }]));
    put2("userScripts", { ...callbacks, ExecutionWorld: { MAIN: "MAIN", USER_SCRIPT: "USER_SCRIPT" } });
    if (background) sync().catch((e) => { try { native("debug.error", ["userScripts: " + e.message]).catch(() => {}); } catch (x) {} });

    // Messages from the USER_SCRIPT world come tagged (see the file's
    // wrapper); they go to onUserScriptMessage and onUserScriptConnect.
    const onMessage = runtime.onUserScriptMessage, onConnect = runtime.onUserScriptConnect;
    root.__yabUserScriptMessage = (message, sender, respond) => {
      let keep = false;
      for (const f of [...onMessage.listeners]) {
        const r = f(message, sender, respond);
        if (r === true) keep = true;
        else if (r && typeof r.then === "function") { keep = true; r.then(respond); }
      }
      return keep;
    };
    if (runtime.onConnect && typeof runtime.onConnect.addListener === "function") {
      const marker = "yab-us:";
      const add = runtime.onConnect.addListener.bind(runtime.onConnect);
      const remove = runtime.onConnect.removeListener.bind(runtime.onConnect);
      const wrapped = new Map();
      try {
        add((port) => {
          if (!String(port.name).startsWith(marker)) return;
          const view = Object.create(port, { name: { value: port.name.slice(marker.length) } });
          for (const f of [...onConnect.listeners]) f(view);
        });
      } catch (e) {}
      put(runtime.onConnect, "addListener", (listener) => {
        const w = (port) => { if (!String(port.name).startsWith(marker)) return listener(port); };
        wrapped.set(listener, w);
        return add(w);
      });
      put(runtime.onConnect, "removeListener", (listener) => { const w = wrapped.get(listener); if (w) { wrapped.delete(listener); remove(w); } });
    }
  }

  // WebKit says "install" again whenever an extension is taken up afresh:
  // at a later launch, turned off and on, brought back, or after its own
  // runtime.reload(), where Chrome says nothing, or "update" when its
  // version changed. Extensions open their welcome page on "install", and
  // some their changelog on "update" (Tampermonkey, feedback #112), or
  // reload themselves on it (Surfshark, feedback #283: told "update" on
  // every load, it reloaded itself for ever). So Yab says what it is
  // (ExtensionInstallWord): the first one, for an extension installed in
  // this session, stays an install; one brought in from another browser,
  // installed there already, is an update (Claude's sign-in tab opened in
  // front on a first import, feedback #135), as is a later load at a new
  // version ("update:<the version before>") or of one loaded from a
  // folder ("reload"); the rest aren't told at all.
  if (background && runtime.onInstalled && typeof runtime.onInstalled.addListener === "function") {
    let decided = null;
    const seenBefore = () => decided || (decided = native("background.loadedBefore", []).then((v) => v || false, () => false));
    const add = runtime.onInstalled.addListener.bind(runtime.onInstalled);
    const remove = runtime.onInstalled.removeListener.bind(runtime.onInstalled);
    const wrapped = new Map();
    put(runtime.onInstalled, "addListener", (listener) => {
      const w = (details) => {
        if (!details || details.reason !== "install") return installedMenus(listener, details);
        seenBefore().then((seen) => {
          // At a later launch, or woken on its first use after a launch that
          // let it sleep: in Chrome nothing was said to it at all.
          if (seen === "launch" || seen === "quiet" || seen === "same") return;
          const was = typeof seen === "string" && seen.startsWith("update:") ? seen.slice(7) : null;
          installedMenus(listener, seen ? { ...details, reason: "update", previousVersion: was || runtime.getManifest().version } : details);
        });
      };
      wrapped.set(listener, w);
      return add(w);
    });
    put(runtime.onInstalled, "removeListener", (listener) => { const w = wrapped.get(listener); wrapped.delete(listener); return remove(w || listener); });
    put(runtime.onInstalled, "hasListener", (listener) => wrapped.has(listener));
  }
  // An extension that keeps reloading itself is let do it five times in a
  // row, as in Chromium (Extensions.mayReload, FastReloads): each reload puts
  // its content scripts into every open page again.
  if (background && runtime && typeof runtime.reload === "function") {
    const reload = runtime.reload;
    put(runtime, "reload", function () {
      menuLifetime.stopped = true;
      native("runtime.mayReload", []).then((ok) => {
        if (ok !== false) reload.call(runtime); else menuLifetime.stopped = false;
      }, () => reload.call(runtime));
    });
  }

  // A worker may add listeners only while it starts; WebKit throws for
  // one added later, where Chrome takes it. So for every event this
  // extension's code mentions, the worker has one listener of WebKit's
  // from the start, and a late one joins the list behind it. Events it
  // never mentions still take late listeners without throwing, they
  // just aren't heard. (Request events are left alone: a listener for
  // all of them would wake the worker for every request.)
  //
  // What the worker really listens for, its own listeners and not these,
  // is told to Yab a few seconds into each start and again later
  // (background.listeners): the registrations Yab keeps from its last run
  // to decide what a launch must start (ExtensionLaunch.swift). And once
  // the worker has settled, twenty seconds in and every twenty seconds
  // after, a stand-in nothing joined goes once it has been woken for
  // nothing (runtime's stay): WebKit wakes a worker for every event it has
  // a listener for, and a worker whose code merely mentions
  // storage.onChanged or cookies.onChanged was woken for every write and
  // every cookie, up to 37 times in a launch for MetaMask, with nobody to hear
  // them (docs/lazy-launch.md).
  if (background) {
    const mentioned = new Set(__YAB_EVENTS__);
    // Each listener is heard through a stand-in of its event's (see
    // `holding` below), so that what arrives during an import is kept for
    // after it (see `afterImport`).
    const heard = new Map(), idle = new Map(), standIns = [];
    // A port held for listeners still coming (the stand-in below): what
    // arrives on it is kept, and handed in order to each listener its
    // taker adds to its onMessage; nobody taking it, it is let go.
    const holdPort = (port) => {
      const event = port && port.onMessage;
      if (!event || typeof event.addListener !== "function") return null;
      const keep = (target, key, value) => { try { Object.defineProperty(target, key, { value, configurable: true, writable: true }); } catch (e) {} };
      keep(port, "onMessage", event);
      const queue = [];
      let holding = true;
      event.addListener((...a) => { if (holding) queue.push(a); });
      const own = Object.prototype.hasOwnProperty.call(event, "addListener"), add = event.addListener;
      keep(event, "addListener", function (f, ...rest) {
        const result = add.call(this, f, ...rest);
        if (typeof f === "function" && queue.length) {
          const kept = queue.slice();
          queueMicrotask(() => { for (const a of kept) { try { f(...a); } catch (e) { setTimeout(() => { throw e; }); } } });
        }
        return result;
      });
      return {
        done: (taken) => {
          holding = false;
          setTimeout(() => {
            queue.length = 0;
            if (own) keep(event, "addListener", add); else { try { delete event.addListener; } catch (e) {} }
          }, 0);
          if (!taken) { try { port.disconnect(); } catch (e) {} }
        },
      };
    };
    for (const space of Object.keys(chrome)) {
      if (space === "webRequest") continue;
      let ns; try { ns = chrome[space]; } catch (e) { continue; }
      if (!ns || typeof ns !== "object") continue;
      const names = new Set();
      for (let o = ns; o && o !== Object.prototype; o = Object.getPrototypeOf(o)) Object.getOwnPropertyNames(o).forEach((k) => names.add(k));
      for (const key of names) {
        if (!/^on[A-Z]/.test(key) || (space === "runtime" && /^onMessage/.test(key))) continue;
        let target; try { target = ns[key]; } catch (e) { continue; }
        if (!target || typeof target.addListener !== "function" || target.listeners) continue;
        // The button's click keeps its listeners itself (holdClicks).
        const name = space + "." + key;
        if (heldClicks.some((h) => h.event === target)) {
          heard.set(name, () => (target.hasListeners() ? 1 : 0));
          continue;
        }
        const add = target.addListener.bind(target), remove = target.removeListener.bind(target);
        const late = new Set();
        // What arrives during an import goes, once it is over, to the
        // listeners there then, as Chromium would dispatch it: those WebKit
        // called with it, and those added since, which it couldn't. One
        // removed meanwhile doesn't hear it: MetaMask's buffering listener
        // for runtime.onInstalled gives way to its real one as its
        // background loads, and the install told to the first one late was
        // lost, its onboarding never opened. WebKit calls each listener
        // once an event, so a listener called again starts the next one.
        const current = new Map();
        let added = 0, arriving = null;
        const stands = new WeakMap();
        const holding = (listener) => {
          if (typeof listener !== "function") return listener;
          let stand = stands.get(listener);
          if (!stand) {
            stand = function (...args) {
              if (!importing) return listener.apply(this, args);
              if (!arriving || arriving.called.has(listener)) {
                const event = arriving = { called: new Set(), at: added };
                afterImport(() => {
                  if (arriving === event) arriving = null;
                  for (const [f, at] of [...current]) {
                    if (!event.called.has(f) && at <= event.at) continue;
                    try { f.apply(this, args); } catch (e) { setTimeout(() => { throw e; }); }
                  }
                });
              }
              arriving.called.add(listener);
            };
            stands.set(listener, stand);
          }
          return stand;
        };
        if (mentioned.has(name)) {
          try {
            const standIn = function (...args) {
              if (!late.size && !current.size) idle.set(name, (idle.get(name) || 0) + 1);
              // A content script's port while the worker starts code from
              // an event: turned away, to come again (`turnAway`). One
              // arriving during an import made as the worker loads: Chrome
              // hands it to the listeners that import adds, the worker being
              // one thread; here it went to nobody. It waits for them now,
              // what it carries meanwhile kept for them.
              if (name === "runtime.onConnect" && turnAway(args[0])) return undefined;
              const since = added, alone = !current.size;
              // A content script's: Yab's own ports (pages' messages to the
              // extension, apps) go as before.
              const port = name === "runtime.onConnect" && alone && tabPort(args[0]) ? args[0] : null;
              const held = port && importing ? holdPort(port) : null;
              if (afterImport(() => {
                const takers = [...late];
                // A command can wake the worker while its first listener
                // is still being imported. With no listener at dispatch,
                // no holding wrapper can hand it to the one the import adds.
                if (held || (alone && name === "commands.onCommand")) for (const [f, at] of [...current]) if (at > since) takers.push(f);
                for (const f of takers) { try { f(...args); } catch (e) { setTimeout(() => { throw e; }); } }
                if (held) held.done(takers.length > 0);
              })) return undefined;
              let answer;
              for (const f of [...late]) { try { const r = f(...args); if (r !== undefined) answer = r; } catch (e) { setTimeout(() => { throw e; }); } }
              return answer;
            };
            add(standIn);
            standIns.push({ space, name, late, own: current, drop: () => remove(standIn) });
          } catch (e) {}
        }
        heard.set(name, () => current.size + late.size);
        const has = typeof target.hasListener === "function" ? target.hasListener.bind(target) : null;
        put(target, "addListener", (listener, ...rest) => {
          try {
            const result = add(holding(listener), ...rest);
            if (typeof listener === "function" && !current.has(listener)) current.set(listener, ++added);
            return result;
          } catch (e) { if (/startup/i.test(String(e && e.message))) late.add(listener); else throw e; }
        });
        put(target, "removeListener", (listener) => { late.delete(listener); current.delete(listener); try { remove(stands.get(listener) || listener); } catch (e) {} });
        if (has) put(target, "hasListener", (listener) => late.has(listener) || has(stands.get(listener) || listener));
      }
    }
    const others = (space, keys) => keys.filter((key) => {
      try { const t = chrome[space] && chrome[space][key]; return t && typeof t.hasListeners === "function" && t.hasListeners(); } catch (e) { return false; }
    }).map((key) => space + "." + key);
    const tell = () => {
      const events = [...heard].filter(([, count]) => count() > 0).map(([name]) => name)
        .concat(others("runtime", ["onMessage", "onMessageExternal"]))
        .concat(others("webRequest", ["onBeforeRequest", "onBeforeSendHeaders", "onSendHeaders", "onHeadersReceived", "onAuthRequired", "onResponseStarted", "onBeforeRedirect", "onCompleted", "onErrorOccurred"]));
      native("background.listeners", [events.sort(), Object.fromEntries(idle)]).catch(() => {});
    };
    setTimeout(tell, 4000);
    let looked = 0;
    const settle = () => {
      for (const s of standIns) {
        if (s.dropped || s.space === "runtime" || s.late.size || s.own.size || !idle.get(s.name)) continue;
        try { s.drop(); s.dropped = true; } catch (e) {}
      }
      if (++looked === 1) tell();
      setTimeout(settle, 20000);
    };
    setTimeout(settle, 20000);
  }

  // What one of the extension's pages or its worker posts to another
  // before their port has opened, at once after connect, or from inside
  // onConnect, WebKit keeps until the other end takes the port, then
  // hands on once for each end's world: between two of the extension's
  // own, the same world, so twice. iCloud Passwords' popup asks its
  // worker for its state that way, and was answered twice. So between
  // the extension's own ends every message goes numbered by the end
  // that sends it, and a number already heard is let go by. A content
  // script's port, or an app's, goes as it is.
  if (runtime && typeof runtime.connect === "function" && runtime.onConnect) {
    const own = runtime.getURL("");
    const numbered = new WeakSet();
    // Set on the port itself, not with `put`, which holds what it touches
    // for good: a port is the extension's to let go. Its onMessage is held
    // by what is set here, so it isn't made afresh without it.
    const set = (target, key, value) => { try { Object.defineProperty(target, key, { value, configurable: true, writable: true }); } catch (e) {} };
    // Chrome hands a port's listeners the port they were added to. WebKit
    // can hand a different wrapper, without what the extension set on its
    // port: Vimium C keeps its sender state on port.s and reads it in both
    // listeners, so its worker answered no key from a page (request #422).
    const sameEndpoint = (port, key) => {
      const event = port && port[key];
      if (!event || typeof event.addListener !== "function") return;
      const add = event.addListener, remove = event.removeListener, has = event.hasListener;
      const stands = new WeakMap();
      set(port, key, event);
      set(event, "addListener", (f, ...rest) => {
        if (typeof f !== "function") return add.call(event, f, ...rest);
        let w = stands.get(f);
        if (!w) { w = key === "onMessage" ? (message) => f(message, port) : () => f(port); stands.set(f, w); }
        return add.call(event, w, ...rest);
      });
      if (typeof remove === "function") set(event, "removeListener", (f) => remove.call(event, stands.get(f) || f));
      if (typeof has === "function") set(event, "hasListener", (f) => has.call(event, stands.get(f) || f));
    };
    const number = (port) => {
      const event = port && port.onMessage, post = port && port.postMessage;
      if (!event || typeof event.addListener !== "function" || typeof post !== "function" || numbered.has(port)) return port;
      numbered.add(port);
      const me = Math.random().toString(36).slice(2);
      let sent = 0;
      const heard = new Map();
      const listeners = new Set();
      event.addListener.call(event, (message, ...rest) => {
        const tag = message && typeof message === "object" ? message.__yabPort : null;
        if (Array.isArray(tag)) {
          if (tag[1] <= (heard.get(tag[0]) || 0)) return;
          heard.set(tag[0], tag[1]);
          message = message.message;
        }
        // The listener belongs to this endpoint. WebKit can hand back a
        // different wrapper as its second argument, losing the extension's
        // state on it (Vimium C sets port.s before registering its handler).
        for (const f of [...listeners]) { try { f(message, port); } catch (e) { setTimeout(() => { throw e; }); } }
      });
      // WebKit makes a port's onMessage afresh once nothing holds it, and
      // a fresh one has none of what is set below: a listener added to it
      // later would hear the numbered wrapper. Held on the port, it stays.
      set(port, "onMessage", event);
      set(port, "postMessage", (message) => post.call(port, { __yabPort: [me, ++sent], message }));
      set(event, "addListener", (f) => { listeners.add(f); });
      set(event, "removeListener", (f) => { listeners.delete(f); });
      set(event, "hasListener", (f) => listeners.has(f));
      set(event, "hasListeners", () => listeners.size > 0);
      sameEndpoint(port, "onDisconnect");
      return port;
    };
    const connect = runtime.connect;
    // Only a port to the extension itself: another extension would hear
    // the numbered wrapper, not the message.
    put(runtime, "connect", (...args) => {
      const port = connect.apply(runtime, args);
      return typeof args[0] === "string" && args[0] !== runtime.id ? port : number(port);
    });
    const onConnect = runtime.onConnect;
    const add = onConnect.addListener, remove = onConnect.removeListener, has = onConnect.hasListener;
    const wrapped = new WeakMap();
    // The worker's sender is the bare origin, with no slash after it.
    const fromOwn = (port) => !!port && !!port.sender && (String(port.sender.url) + "/").startsWith(own);
    // React pairs a DevTools port and a page proxy with each tab. A new
    // panel or document can connect before the old native disconnect
    // event reaches the worker. Retire the old pipe before React sees
    // the new one; a delayed old callback must not clear the new pipe.
    const reactWorker = background && (["fmkadmapgofadopljbjfkapdkoienihi", "gpphkfbcpidddadnkolkpfckpihlkkil"].includes(runtime.id)
      || runtime.getManifest().name === "React Developer Tools");
    const reactPorts = new Map();
    const reactPort = (port) => {
      if (!reactWorker) return port;
      const page = port.name === "proxy" && port.sender && port.sender.tab && port.sender.tab.id;
      const key = /^\d+$/.test(port.name) ? "devtools:" + port.name
        : Number.isInteger(page) ? "proxy:" + page : null;
      if (!key) return port;
      const previous = reactPorts.get(key);
      if (previous === port) return port;
      if (previous) previous.disconnect();
      const disconnectEvent = port.onDisconnect, disconnect = port.disconnect, post = port.postMessage;
      const listeners = new Set();
      let closed = false;
      const close = (native) => {
        if (closed) return;
        closed = true;
        if (reactPorts.get(key) === port) reactPorts.delete(key);
        for (const listener of [...listeners]) { try { listener(port); } catch (error) { setTimeout(() => { throw error; }); } }
        listeners.clear();
        if (native) { try { disconnect.call(port); } catch (error) {} }
      };
      disconnectEvent.addListener(() => close(false));
      set(port, "onDisconnect", disconnectEvent);
      set(disconnectEvent, "addListener", (listener) => listeners.add(listener));
      set(disconnectEvent, "removeListener", (listener) => listeners.delete(listener));
      set(disconnectEvent, "hasListener", (listener) => listeners.has(listener));
      set(disconnectEvent, "hasListeners", () => listeners.size > 0);
      set(port, "disconnect", () => close(true));
      set(port, "postMessage", (message) => { if (!closed) return post.call(port, message); });
      reactPorts.set(key, port);
      return port;
    };
    // A content script's port: told which life of the worker it is
    // connected to, and, let go here, the word that tells the content
    // script so, which WebKit doesn't (see `closable`, above), with the
    // port let go a moment later, so the word goes first.
    const closingPorts = new WeakSet();
    const closing = (port) => {
      if (!port || closingPorts.has(port) || !port.sender || !port.sender.tab || fromOwn(port)) return port;
      closingPorts.add(port);
      sameEndpoint(port, "onMessage");
      sameEndpoint(port, "onDisconnect");
      const post = port.postMessage, disconnect = port.disconnect;
      if (worker) { try { post.call(port, { __yabPortLife: workerLife }); } catch (e) {} }
      let closed = false;
      set(port, "disconnect", () => {
        if (closed) return;
        closed = true;
        try { post.call(port, { __yabPortClosed: true }); } catch (e) {}
        setTimeout(() => { try { disconnect.call(port); } catch (e) {} }, 100);
      });
      set(port, "postMessage", (message) => {
        if (closed) throw new Error("Attempting to use a disconnected port object");
        return post.call(port, message);
      });
      return port;
    };
    put(onConnect, "addListener", (listener, ...rest) => {
      if (typeof listener !== "function") return add.call(onConnect, listener, ...rest);
      let w = wrapped.get(listener);
      if (!w) { w = (port) => { if (turnAway(port)) return; return listener(reactPort(fromOwn(port) ? number(port) : closing(port))); }; wrapped.set(listener, w); }
      return add.call(onConnect, w, ...rest);
    });
    put(onConnect, "removeListener", (listener) => remove.call(onConnect, wrapped.get(listener) || listener));
    put(onConnect, "hasListener", (listener) => has.call(onConnect, wrapped.get(listener) || listener));
  }

  // Members of namespaces WebKit has.
  if (chrome.i18n && !chrome.i18n.detectLanguage) put(chrome.i18n, "detectLanguage", call("i18n.detectLanguage"));
  if (runtime && !runtime.getContexts) put(runtime, "getContexts", call("runtime.getContexts"));

  // An extension's DevTools page, the panels it adds to the inspector
  // (Yab's card shows them in its head). WebKit refuses a panel with no
  // icon, which Chrome takes and draws as its title alone: React
  // Developer Tools asks with "", and had no Components, no Profiler.
  // The extension's own icon stands in. Then what Chrome has and WebKit
  // hasn't, or has otherwise: the Elements panel's selection, an event
  // that never fires here (React's tree reads it, unguarded); the
  // network's HAR, empty, so React fetches a file itself; a file shown
  // in Sources at a line, which the card does; and inspectedWindow.eval's
  // answer, two arguments as in Chromium where WebKit hands one array.
  const devtools = chrome.devtools;
  if (devtools && devtools.panels) {
    // The same objects each time they are asked for, as the
    // namespaces above: a fresh wrapper wouldn't have what is set here.
    const panels = devtools.panels, network = devtools.network, inspected = devtools.inspectedWindow;
    put(devtools, "panels", panels);
    if (network) put(devtools, "network", network);
    if (inspected) put(devtools, "inspectedWindow", inspected);
    const manifest = (runtime && runtime.getManifest && runtime.getManifest()) || {};
    const icons = manifest.icons || {};
    const largest = Object.keys(icons).map(Number).sort((a, b) => b - a)[0];
    const icon = largest ? icons[largest] : "";
    const create = panels.create;

    // React Developer Tools draws its panels from its DevTools page,
    // into each panel's window as Chromium hands it over (onShown). WebKit
    // keeps the DevTools page in a web view of its own, apart from the
    // panels in the inspector, and has no window to hand. So its
    // DevTools page only makes the panels, and the panel on screen runs
    // the page's script itself; one at a time, as the extension pairs
    // one DevTools page with a tab. Yab's card tells a panel's frame
    // when it comes and goes (DevTools.swift).
    const hosted = !!manifest.devtools_page && (manifest.name === "React Developer Tools"
      || ["fmkadmapgofadopljbjfkapdkoienihi", "gpphkfbcpidddadnkolkpfckpihlkkil"].includes(runtime && runtime.id));
    const devtoolsPage = !!manifest.devtools_page && location.pathname === "/" + String(manifest.devtools_page).replace(/^\.?\//, "");
    const ownPanel = new URLSearchParams(location.search).get("yab-panel");

    if (hosted && ownPanel !== null) {
      // The panels' frames, by title: siblings in the inspector's page,
      // of one origin, so each can reach the others' windows.
      const panelWindows = () => {
        const found = {};
        try {
          for (let i = 0; i < parent.frames.length; i++) {
            try {
              const title = new URLSearchParams(parent.frames[i].location.search).get("yab-panel");
              if (title !== null) found[title] = parent.frames[i];
            } catch (e) {}
          }
        } catch (e) {}
        return found;
      };
      const findHost = () => {
        const all = panelWindows();
        for (const title in all) { try { if (all[title].__yabPanels) return all[title].__yabPanels; } catch (e) {} }
        return null;
      };
      // The first panel shown runs the DevTools page's script, once, and
      // shows each panel in that panel's own window, as Chromium does.
      const host = () => {
        const made = [];
        let showing = null;
        // The page's side may still be serving a panel that went with
        // the last inspector: Chrome's DevTools page tells it "shutdown"
        // as it goes, a panel's frame goes without a word, and may even
        // stay connected a while. So the panel of a last inspector for
        // this tab is asked to let go first (the extension pairs one
        // DevTools page with a tab and refuses a second), then the first
        // thing said is "shutdown", and the page starts afresh for this
        // panel, its whole tree sent again. A page's side started afresh
        // waits to hear from the extension before it starts; the
        // extension's script in the page said so once, long ago, so it is
        // said here too until the page answers.
        const me = Math.random().toString(36).slice(2);
        const channel = typeof BroadcastChannel === "function" ? new BroadcastChannel("yab-devtools-" + (runtime && runtime.id)) : null;
        const tab = String(inspected && inspected.tabId);
        let live = null, retired = false;
        if (channel) {
          channel.onmessage = (e) => {
            if (!e.data || e.data.tab !== tab || e.data.from === me || !live) return;
            retired = true;
            try { live.disconnect(); } catch (error) {}
            live = null;
          };
          channel.postMessage({ tab, from: me });
        }
        const connect = runtime.connect;
        put(runtime, "connect", (...args) => {
          const name = args[0] && args[0].name;
          if (typeof name !== "string" || !/^\d+$/.test(name)) return connect.apply(runtime, args);
          if (retired) return { name, onMessage: event(), onDisconnect: event(), postMessage: () => {}, disconnect: () => {} };
          const port = connect.apply(runtime, args);
          live = port;
          let answered = false;
          const hello = setInterval(() => {
            if (answered || live !== port) { clearInterval(hello); return; }
            try { port.postMessage({ event: "yabHello" }); } catch (error) { clearInterval(hello); }
          }, 500);
          try {
            port.onMessage.addListener((m) => { if (m && (m.event === "backendInitialized" || m.event === "extensionBackendInitialized")) answered = true; });
            port.onDisconnect.addListener(() => clearInterval(hello));
            port.postMessage({ event: "shutdown" });
          } catch (error) {}
          if (__YAB_VERBOSE__) {
            const note = (what) => { own.journal.push(what); if (own.journal.length > 30) own.journal.shift(); };
            note("connected " + name);
            try {
              port.onMessage.addListener((m) => note("in " + ((m && (m.event || (m.payload && m.payload.type))) || "?")));
              port.onDisconnect.addListener(() => note("disconnected"));
            } catch (e) {}
          }
          return port;
        });
        // A page loading anew: WebKit says so as it starts, Chrome once
        // it has committed, and React looks for itself on the page right
        // after, five times in two and a half seconds. Told once the new
        // page has loaded, React finds itself there.
        const navigated = network && network.onNavigated;
        if (navigated && inspected && typeof navigated.addListener === "function") {
          put(network, "onNavigated", navigated);
          const listen = navigated.addListener;
          const look = () => Promise.resolve(inspected.eval("JSON.stringify([performance.timeOrigin, document.readyState])"))
            .then((got) => JSON.parse((Array.isArray(got) ? got[0] : got) || "[0, \"\"]"), () => [0, ""]);
          put(navigated, "addListener", (listener) => listen.call(navigated, (...args) => {
            const began = Date.now();
            look().then(([first]) => {
              const wait = () => look().then(([origin, state]) => {
                const loaded = state === "complete" && (origin !== first || Date.now() - began > 2000);
                if (loaded || Date.now() - began > 15000) listener(...args); else setTimeout(wait, 250);
              });
              setTimeout(wait, 250);
            });
          }));
        }
        put(panels, "create", (title, iconPath, pagePath, callback) => {
          const panel = { title, onShown: event(), onHidden: event(), onSearch: event(), createStatusBarButton: () => ({ onClicked: event(), update: () => {} }) };
          made.push(panel);
          setTimeout(() => { if (typeof callback === "function") callback(panel); });
          return Promise.resolve(panel);
        });
        const fire = (listeners, ...args) => { for (const f of [...listeners]) { try { f(...args); } catch (e) {} } };
        const own = {
          selections: 0,
          journal: [],
          show(title) {
            const attempt = (tries) => {
              const panel = made.find((p) => p.title === title), win = panelWindows()[title];
              if (!panel || !panel.onShown.listeners.size || !win || !win.container) {
                if (tries < 200) setTimeout(() => attempt(tries + 1), 50);
                return;
              }
              if (showing === panel) return;
              if (showing) fire(showing.onHidden.listeners);
              showing = panel;
              fire(panel.onShown.listeners, win);
            };
            attempt(0);
          },
          hide(title) {
            if (!showing || showing.title !== title) return;
            fire(showing.onHidden.listeners);
            showing = null;
          },
        };
        put(window, "__yabPanels", own);
        // A test run reads and works the panels through the extension's
        // storage (evals/extensions/react_devtools.py): a page of theirs
        // is otherwise out of every test's reach.
        if (__YAB_VERBOSE__ && chrome.storage && chrome.storage.onChanged) {
          // Keep the exact native event wrapper that owns the listener:
          // fetching onChanged again can make a different wrapper.
          const benchChanges = chrome.storage.onChanged;
          put(chrome.storage, "onChanged", benchChanges);
          benchChanges.addListener(async (changes) => {
            const asked = changes.__yabPanelBench && changes.__yabPanelBench.newValue;
            if (!asked || retired) return;
            // Each window has its own inspector, all share storage.
            if (asked.url) {
              try {
                const got = await inspected.eval("location.href");
                if ((Array.isArray(got) ? got[0] : got) !== asked.url) return;
              } catch (error) { return; }
            }
            // Kept small: a large item is refused for going over quota.
            const answer = (value) => {
              if (retired) return;
              let said = JSON.stringify(value === undefined ? null : value);
              if (said.length > 4000) said = JSON.stringify(String(typeof value === "string" ? value : said).slice(0, 3500));
              // Two frames can answer during a handoff. Even after a
              // remove, the second write can replace the first one's
              // Unicode value. Store escaped JSON so both WebKit's
              // character count and byte count see the same ASCII.
              said = said.replace(/[^\x00-\x7f]/g, (c) => "\\u" + c.charCodeAt(0).toString(16).padStart(4, "0"));
              // WebKit's quota accounting can reject replacement of a
              // Unicode value although storage is far below its quota.
              // Remove only this test key before writing its next value.
              chrome.storage.local.remove("__yabPanelBenchAnswer").then(() =>
                chrome.storage.local.set({ __yabPanelBenchAnswer: { id: asked.id, json: said } })).catch((error) => {
                  console.error("React panel test answer:", String(error));
                });
            };
            try {
              const win = panelWindows()[asked.panel];
              if (!win) { answer({ error: "no panel " + asked.panel }); return; }
              const doc = win.document;
              if (asked.op === "text") { answer(doc.body.innerText); return; }
              if (asked.op === "state") { answer({ showing: showing && showing.title, selections: own.selections, made: made.map((p) => p.title), journal: own.journal }); return; }
              if (asked.op === "eval") {
                Promise.resolve(inspected.eval(String(asked.expression))).then((got) => answer({ got }), (error) => answer({ error: String(error) }));
                return;
              }
              // A control's tooltip, as React DevTools gives it: a prop of
              // the components around the button, not an attribute.
              const labelled = (el) => {
                const key = Object.keys(el).find((k) => k.startsWith("__reactFiber$"));
                for (let f = key && el[key], i = 0; f && i < 8; f = f.return, i++) {
                  const p = f.memoizedProps;
                  if (p && typeof (p.label || p.title) === "string") return p.label || p.title;
                }
                return null;
              };
              if (asked.op === "list") {
                answer(Array.from(doc.querySelectorAll(asked.selector || "button, [title], [aria-label], [data-testname]")).slice(0, 30)
                  .map((el) => [el.tagName, el.getAttribute("title"), el.getAttribute("aria-label"), el.getAttribute("data-testname"), el.textContent.trim().slice(0, 30), labelled(el)]));
                return;
              }
              const all = asked.label ? Array.from(doc.querySelectorAll("button")).filter((el) => (labelled(el) || "").includes(asked.label))
                : asked.selector ? Array.from(doc.querySelectorAll(asked.selector))
                : Array.from(doc.querySelectorAll("*")).filter((el) => el.textContent.trim() === asked.text
                    && !Array.from(el.children).some((c) => c.textContent.trim() === asked.text));
              const el = all[asked.nth || 0];
              if (!el) { answer({ error: "nothing matches", count: all.length }); return; }
              if (asked.op === "html") { answer(el.outerHTML.slice(0, 3000)); return; }
              if (asked.op === "click") {
                const r = el.getBoundingClientRect();
                const at = { bubbles: true, cancelable: true, view: win, clientX: r.left + r.width / 2, clientY: r.top + r.height / 2, button: 0 };
                for (const type of ["pointerdown", "mousedown", "pointerup", "mouseup", "click"]) {
                  el.dispatchEvent(type.startsWith("pointer") ? new win.PointerEvent(type, at) : new win.MouseEvent(type, at));
                }
                answer({ clicked: el.outerHTML.slice(0, 300) });
                return;
              }
              if (asked.op === "type") {
                el.focus();
                Object.getOwnPropertyDescriptor(win.HTMLInputElement.prototype, "value").set.call(el, String(asked.value));
                el.dispatchEvent(new win.Event("input", { bubbles: true }));
                el.dispatchEvent(new win.Event("change", { bubbles: true }));
                const enter = { key: "Enter", code: "Enter", keyCode: 13, which: 13, bubbles: true, cancelable: true };
                el.dispatchEvent(new win.KeyboardEvent("keydown", enter));
                el.dispatchEvent(new win.KeyboardEvent("keyup", enter));
                answer({ typed: el.outerHTML.slice(0, 300) });
                return;
              }
              answer({ error: "unknown op " + asked.op });
            } catch (error) { answer({ error: String(error) }); }
          });
        }
        const page = "/" + String(manifest.devtools_page).replace(/^\.?\//, "");
        fetch(page).then((r) => r.text()).then((html) => {
          const sources = Array.from(new DOMParser().parseFromString(html, "text/html").querySelectorAll("script[src]"))
            .map((s) => s.getAttribute("src")).filter((src) => !/(yab|fast)-shim\.js$/.test(src));
          const next = () => {
            const src = sources.shift();
            if (!src) return;
            const script = document.createElement("script");
            script.src = new URL(src, location.origin + page).href;
            script.onload = next;
            script.onerror = next;
            document.head.appendChild(script);
          };
          next();
        });
        return own;
      };
      addEventListener("message", (e) => {
        if (e.source !== parent || !e.data || e.data.yab !== "panel") return;
        const panelsHost = findHost() || (e.data.shown ? host() : null);
        if (!panelsHost) return;
        if (e.data.shown) panelsHost.show(ownPanel); else panelsHost.hide(ownPanel);
      });
    } else if (hosted && devtoolsPage) {
      // The DevTools page itself: its panels made, the rest left to them.
      // React's listeners get stand-ins: WebKit now and then calls a
      // panel's onShown here too, with a window in another process, and
      // reading it throws.
      put(panels, "create", (title, iconPath, pagePath, callback) => {
        const page = String(pagePath) + (String(pagePath).includes("?") ? "&" : "?") + "yab-panel=" + encodeURIComponent(title);
        const stand = { onShown: event(), onHidden: event(), onSearch: event(), createStatusBarButton: () => ({ onClicked: event(), update: () => {} }) };
        create.call(panels, title, iconPath || icon, page, () => {});
        if (typeof callback === "function") setTimeout(() => callback(stand));
        return Promise.resolve(stand);
      });
      put(runtime, "connect", (info) => ({ name: (info && info.name) || "", onMessage: event(), onDisconnect: event(), postMessage: () => {}, disconnect: () => {} }));
      if (inspected) put(inspected, "eval", (expression, ...rest) => {
        const callback = rest.length && typeof rest[rest.length - 1] === "function" ? rest.pop() : null;
        if (callback) setTimeout(() => callback(false, undefined));
        return Promise.resolve([false, null]);
      });
    } else if (typeof create === "function") {
      put(panels, "create", (title, iconPath, pagePath, ...rest) => create.call(panels, title, iconPath || icon, pagePath, ...rest));
    }

    if (inspected && typeof inspected.eval === "function" && !(hosted && devtoolsPage)) {
      const evaluate = inspected.eval;
      put(inspected, "eval", (expression, ...rest) => {
        const callback = rest.length && typeof rest[rest.length - 1] === "function" ? rest.pop() : null;
        const answer = evaluate.call(inspected, expression, ...rest);
        if (!callback) return answer;
        Promise.resolve(answer).then((got) => {
          const [result, failure] = Array.isArray(got) && got.length === 2 ? got : [got, null];
          callback(result, failure || undefined);
        }, (error) => callback(undefined, { isError: true, code: "E_FAILED", description: String(error && error.message || error) }));
      });
    }
    // What is picked in Elements: the card tells each panel's frame
    // (DevTools.swift), and the panel's listeners hear it as in Chromium.
    {
      const selection = event(), elements = panels.elements;
      put(panels, "elements", Object.assign(Object.create(elements || null), { onSelectionChanged: selection }));
      if (parent !== window) {
        addEventListener("message", (e) => {
          if (e.source !== parent || !e.data || e.data.yab !== "selection") return;
          if (window.__yabPanels) window.__yabPanels.selections += 1;
          for (const f of [...selection.listeners]) { try { f(); } catch (error) {} }
        });
      }
    }
    if (!panels.openResource) {
      // In a panel's frame the card is the parent and shows it; from a
      // DevTools page of its own, Yab is asked.
      put(panels, "openResource", (url, line, column, callback) => {
        const done = (failure) => { if (typeof callback === "function") callback(failure ? { isError: true, code: "E_NOTFOUND", description: failure } : {}); };
        if (parent !== window) { parent.postMessage({ yab: "reveal", url: String(url), line: (Number(line) || 0) + 1, column: (Number(column) || 0) + 1 }, "*"); done(); return; }
        native("devtools.openResource", [String(url), Number(line) || 0, Number(column) || 0]).then(() => done(), (error) => done(String(error && error.message || error)));
      });
    }
    if (network && !network.getHAR) put(network, "getHAR", resolve({ entries: [] }));
  }

  __YAB_FILE_SYSTEM__

  // A worker that starts again, after WebKit let it go between events,
  // puts its scripts into the tabs that are open, as in Chromium, where the
  // copies already there have heard by then that the old worker is gone.
  // Here each start is a new life: its ports say which (`closing`), it
  // tells every content script it has begun (through storage, which
  // reaches them all and asks for no answer), a port of an earlier life
  // is closed there as Chromium would have closed it (`closable`), and
  // what the worker puts into tabs waits a moment for that.
  if (worker && chrome.storage && chrome.storage.local && typeof chrome.storage.local.set === "function") {
    const area = chrome.storage.local, key = "__yabWorkerLife";
    const told = Promise.resolve()
      .then(() => area.set({ [key]: workerLife }))
      .then(() => new Promise((resolve) => setTimeout(resolve, 300)))
      // Overwrite the hidden generation at the next start. Removing our
      // sole key here asks WebKit to delete its just-emptied native DB.
      .catch(() => {});
    const waits = (space, method) => {
      const ns = chrome[space], f = ns && ns[method];
      if (typeof f !== "function") return;
      put(ns, method, function (...args) {
        const callback = args.length && typeof args[args.length - 1] === "function" ? args.pop() : null;
        const p = told.then(() => f.apply(ns, args));
        if (!callback) return p;
        p.then((value) => callback(value), (error) => withLastError(error, callback));
      });
    };
    waits("scripting", "executeScript");
    waits("tabs", "executeScript");
  }

  // A worker at work stays, as in Chromium, where every call to an
  // extension API starts the worker's 30 s again. NordPass keeps its
  // unlocked vault only in its worker and saves a heartbeat every 20 s
  // (storage.local.set, its keepAlive) so that Chrome never stops it.
  // WebKit lets a worker go 30 s after its last event unless it holds an
  // open port it was active on in the last two minutes, so NordPass's
  // worker went, its vault locked with it, and the next page asked a
  // fresh, locked worker: its field icon said locked while its popup had
  // just been unlocked (Danny Peck, Oct 14 2026). So a worker that called
  // one of these in the last 30 s opens a port to the browser
  // (ExtensionKeep) every 10 s; one that stops calling goes as before.
  // YAB_WORKER_KEEP=0: as WebKit does.
  if (worker && __YAB_KEEP__ && runtime && typeof runtime.connectNative === "function") {
    // A port of its own each time, the last one let go first: one port
    // held from the start, with a word on it a second before, didn't keep
    // NordPass's worker 30 s past the close of one of its own pages (farm
    // 427630e0); a port added afresh each time did (farm c6223dac).
    let last = 0, said = 0, port = null;
    const say = () => {
      said = Date.now();
      try { if (port) port.disconnect(); } catch (e) {}
      port = null;
      try {
        port = runtime.connectNative("yab.keep");
        port.postMessage({ at: said });
      } catch (e) { port = null; }
    };
    // Yab's own words in storage (the worker's start) are no call of the
    // extension's.
    const own = (args) => {
      const first = args[0];
      if (typeof first === "string") return ownWords.has(first);
      if (Array.isArray(first)) return first.length > 0 && first.every((k) => ownWords.has(k));
      return !!first && typeof first === "object" && Object.keys(first).length > 0 && Object.keys(first).every((k) => ownWords.has(k));
    };
    const done = new WeakSet();
    const counted = (ns, names) => {
      if (!ns || typeof ns !== "object" || done.has(ns)) return;
      done.add(ns);
      for (const name of names) {
        let f; try { f = ns[name]; } catch (e) { continue; }
        if (typeof f !== "function") continue;
        put(ns, name, function (...args) {
          if (!own(args)) {
            last = Date.now();
            // The first call after a quiet spell says so at once: the
            // next word on the timer could come after WebKit's 30 s.
            if (last - said > 8000) say();
          }
          return f.apply(ns, args);
        });
      }
    };
    // `browser` too, a namespace of its own in WebKit: NordPass calls
    // through it.
    for (const api of new Set([chrome, root.browser].filter((a) => a && typeof a === "object"))) {
      // The same object every time, as `chrome`'s are made at the top:
      // what is set on a fresh one is gone with it.
      const get = (o, k) => {
        let v; try { v = o && o[k]; } catch (e) { return undefined; }
        if (v && typeof v === "object") {
          kept.add(v);
          const d = Object.getOwnPropertyDescriptor(o, k);
          if (!d || d.get) { try { Object.defineProperty(o, k, { value: v, configurable: true, writable: true, enumerable: true }); } catch (e) {} }
        }
        return v;
      };
      const storage = get(api, "storage");
      for (const area of ["local", "session", "sync"]) counted(get(storage, area), ["get", "set", "remove", "clear", "getBytesInUse", "getKeys"]);
      counted(get(api, "runtime"), ["getPlatformInfo", "sendMessage"]);
      counted(get(api, "tabs"), ["query", "get"]);
      counted(get(api, "alarms"), ["get", "getAll"]);
    }
    setInterval(() => {
      if (last && Date.now() - last <= 30000) say();
      else if (port) { try { port.disconnect(); } catch (e) {} port = null; }
    }, 10000);
  }

  // Errors in an extension's own pages and worker are told to the browser,
  // which lists them, the only window onto a worker there is.
  if (root.addEventListener) {
    const tell = (text) => { try { native("debug.error", [String(text).slice(0, 2000)]).catch(() => {}); } catch (e) {} };
    root.addEventListener("error", (e) => tell((e.message || "error") + " @ " + String(e.filename || "").split("/").slice(3).join("/") + ":" + e.lineno));
    root.addEventListener("unhandledrejection", (e) => tell("unhandled: " + (e.reason && ((e.reason.message || "") + ", " + (e.reason.stack || "")) || e.reason)));
    // In a test run, what the extension says went wrong, too.
    if (__YAB_VERBOSE__ && root.console) {
      let told = 0;
      for (const level of ["error", "warn"]) {
        const original = console[level].bind(console);
        console[level] = (...args) => {
          original(...args);
          if (told++ < 60) tell("console." + level + ": " + args.map((a) => {
            if (a instanceof Error) return a.message + ", " + (a.stack || "");
            try { return typeof a === "string" ? a : JSON.stringify(a); } catch (e) { return String(a); }
          }).join(" "));
        };
      }
      // Each start of a worker: a run's timeline counts them
      // (evals/extensions/onepassword_profile.py).
      if (typeof document === "undefined") { try { native("background.started", []).catch(() => {}); } catch (e) {} }
    }
  }
})();
