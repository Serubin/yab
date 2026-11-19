import Combine
import WebKit

// The Chrome Web Store, made to work for this browser.
//
// The store sees a browser that isn't Chrome and says so: a banner asking to
// "Switch to Chrome", and an "Add to Chrome" button that stays gray. yab
// installs from the store on its own (Extensions.install, through Crx), so on
// the store's pages the banner goes and the gray button is replaced by an
// "Add to yab" one, the button people already look for, rather than a bar
// at the bottom of the window they would have to notice. What gets installed
// is read from the tab's own address, never from anything the page says; the
// page only asks, and the usual confirmation still stands between the asking
// and the installing.

final class StoreRelay: NSObject, PageScriptReceiving {
    static let name = "yabStore"

    weak var tab: Tab?

    func receive(_ message: PageScriptMessage) {
        guard let body = message.body as? [String: Any] else { return }
        let frame = message.frame
        MainActor.assumeIsolated {
            // The store's own page, the one place the button is for (RelayGuard).
            guard let tab, RelayGuard.from(frame, "chromewebstore.google.com") else { return }
            if body["add"] != nil { tab.onStoreAdd?(tab) }
            if let placed = body["placed"] as? String { tab.storePlaced = placed }
        }
    }

    /// Main frame, every page, returning at once anywhere but the store. The
    /// store's markup is generated and its class names change between
    /// releases, so nothing here leans on them: the store's own button is the
    /// disabled one that names Chrome, and the banner is the small block
    /// around the one enabled button that does, only that block, since the
    /// store puts the banner and the extension's own header, button and all,
    /// in the same section.
    static let script = """
    (function () {
      if (location.hostname !== 'chromewebstore.google.com' || window.__yabStore) return;
      var state = { installed: [], busy: null };
      var pairs = new Map(), watchers = [];

      function pageID() {
        var m = location.pathname.match(/\\/detail\\/(?:[^\\/]+\\/)?([a-p]{32})/);
        return m ? m[1] : null;
      }

      function theirs() {
        var buttons = document.querySelectorAll('button[disabled]');
        for (var i = 0; i < buttons.length; i++) {
          var b = buttons[i];
          if (b.dataset.yab !== 'add' && !pairs.has(b) && /chrome/i.test(b.textContent || '')) return b;
        }
        return null;
      }

      // From the banner's own button up, as far as it goes without taking in
      // the header beside it: short, and holding no install button.
      function bannerOf(button) {
        var box = null, up = button.parentElement;
        while (up && up !== document.body) {
          // A hidden promo is already handled. Walking past it on the next
          // redraw can reach the extension header while its controls rebuild.
          if (up.dataset.yab === 'banner' || up.dataset.yab === 'promo') return null;
          if (up.querySelector('h1')) break;
          if (up.querySelector('button[disabled], button[data-yab]')) break;
          if ((up.innerText || '').length > 160) break;
          box = up;
          up = up.parentElement;
        }
        return box;
      }

      function hideBanner() {
        // And the floating "Switch to Chrome?" card, known by the Chrome logo
        // it carries in any language, it sits right over the button.
        var cards = document.querySelectorAll('[role="dialog"]');
        for (var c = 0; c < cards.length; c++) {
          if (!cards[c].dataset.yab && cards[c].querySelector('img[src*="productlogos/chrome"]')) {
            cards[c].style.display = 'none';
            cards[c].dataset.yab = 'promo';
          }
        }
        var buttons = document.querySelectorAll('button:not([disabled])');
        for (var i = 0; i < buttons.length; i++) {
          var b = buttons[i];
          if (b.dataset.yab || !/chrome/i.test(b.getAttribute('aria-label') || '')) continue;
          var box = bannerOf(b);
          if (box && !box.dataset.yab) {
            box.style.display = 'none';
            box.dataset.yab = 'banner';
          }
        }
      }

      // The words only, so the button keeps the store's own shape and color.
      function label(button, text) {
        var walker = document.createTreeWalker(button, NodeFilter.SHOW_TEXT);
        var node, last = null;
        while ((node = walker.nextNode())) { if (node.nodeValue.trim()) last = node; }
        if (last) { if (last.nodeValue !== text) last.nodeValue = text; }
        else if (button.textContent !== text) button.textContent = text;
      }

      function render(ours) {
        var id = pageID();
        var installed = !!id && state.installed.indexOf(id) >= 0;
        var busy = !!id && state.busy === id;
        label(ours, installed ? 'Added to \(Brand.name)' : (busy ? 'Adding…' : 'Add to \(Brand.name)'));
        if (ours.disabled !== (installed || busy)) ours.disabled = installed || busy;
      }

      function mend() {
        // Only the small install control's container is observed. Disconnect
        // while writing our own nodes so a repair cannot trigger itself.
        watchers.forEach(function (watcher) { watcher.disconnect(); });
        watchers = [];
        hideBanner();
        pairs.forEach(function (ours, original) {
          if (!original.isConnected) { ours.remove(); pairs.delete(original); return; }
          // Hydration can remove our sibling but retain the marked original.
          // Keep the pair, rather than mistaking the marker for a live button.
          if (original.nextElementSibling !== ours) original.after(ours);
          if (original.style.display !== 'none') original.style.display = 'none';
        });
        var original;
        while (pageID() && (original = theirs()) && original.parentNode) {
          var ours = original.cloneNode(true);
          ['disabled', 'jsaction', 'jscontroller', 'jsname', 'jslog', 'aria-describedby'].forEach(function (name) {
            ours.removeAttribute(name);
          });
          ours.dataset.yab = 'add';
          pairs.set(original, ours);
          original.dataset.yab = 'theirs';
          original.style.display = 'none';
          original.parentNode.insertBefore(ours, original.nextSibling);
          window.webkit.messageHandlers.yabStore.postMessage({ placed: pageID() });
        }
        renderAll();
        var roots = new Set();
        pairs.forEach(function (_, original) { roots.add(original.parentElement); });
        roots.forEach(function (root) {
          if (!root || root === document.body || root === document.documentElement) return;
          var watcher = new MutationObserver(mend);
          watcher.observe(root, { childList: true, subtree: true, attributes: true,
                                  attributeFilter: ['disabled', 'aria-label', 'style'] });
          watchers.push(watcher);
        });
      }

      // The store keeps the pages it has left, hidden, beside the one it shows.
      function renderAll() {
        var mine = document.querySelectorAll('button[data-yab="add"]');
        for (var i = 0; i < mine.length; i++) render(mine[i]);
      }

      // Caught on the window, before the store's own handlers, which listen
      // on the document, can see the click at all.
      window.addEventListener('click', function (e) {
        var mine = e.target && e.target.closest && e.target.closest('button[data-yab="add"]');
        if (!mine) return;
        e.preventDefault();
        e.stopImmediatePropagation();
        if (!mine.disabled) window.webkit.messageHandlers.yabStore.postMessage({ add: true });
      }, true);

      function box(el) {
        var r = el.getBoundingClientRect();
        return { x: r.left, y: r.top, width: r.width, height: r.height };
      }

      // Where the extension is on the page, for its icon to fly from once
      // it is added: our button, and the extension's own picture, the
      // largest square image level with the button, on screen.
      function spot() {
        var button = null, mine = document.querySelectorAll('button[data-yab="add"]');
        for (var i = 0; i < mine.length; i++) {
          if (mine[i].getClientRects().length) { button = mine[i]; break; }
        }
        var middle = button ? box(button).y + box(button).height / 2 : null;
        var logo = null, images = document.images;
        for (var j = 0; j < images.length; j++) {
          var r = box(images[j]);
          if (r.width < 32 || r.width > 200 || Math.abs(r.width - r.height) > 2) continue;
          if (r.y + r.height < 0 || r.y > innerHeight) continue;
          if (middle !== null && Math.abs(r.y + r.height / 2 - middle) > 160) continue;
          if (!logo || r.width > box(logo).width) logo = images[j];
        }
        // It leaves a trace while it is in the air.
        if (logo) { logo.dataset.yabLifted = '1'; logo.style.opacity = '0.25'; }
        return { logo: logo ? box(logo) : null, button: button ? box(button) : null };
      }

      function landed() {
        var lifted = document.querySelectorAll('img[data-yab-lifted]');
        for (var i = 0; i < lifted.length; i++) {
          lifted[i].style.opacity = '';
          delete lifted[i].dataset.yabLifted;
        }
      }

      window.__yabStore = {
        state: function (next) {
          state = next || state;
          renderAll();
        },
        spot: spot,
        landed: landed
      };

      // Discovery is an insertion/visibility event, including a new SPA
      // header. No whole-document observer or polling on the store or any
      // other page. A custom property animates without changing any pixels.
      var discovery = document.createElement('style');
      discovery.textContent = '@keyframes yab-store-discovery { from { --yab-store-seen: 0; } to { --yab-store-seen: 1; } }' +
        'button:not([data-yab]), [role="dialog"]:not([data-yab]) { animation-name: yab-store-discovery !important; animation-duration: 0.001s !important; animation-iteration-count: 1 !important; }';
      window.addEventListener('animationstart', function (event) {
        if (event.animationName === 'yab-store-discovery') mend();
      }, true);
      window.addEventListener('pageshow', mend);
      if (window.navigation) window.navigation.addEventListener('navigatesuccess', mend);
      (document.head || document.documentElement).appendChild(discovery);
      mend();
    })();
    """
}

/// A tab held without keeping it open.
struct WeakTab {
    weak var tab: Tab?
    init(_ tab: Tab) { self.tab = tab }
}

extension Browser {
    /// Where "Chrome Web Store…" goes: its extensions, not its themes.
    static let webStore = URL(string: "https://chromewebstore.google.com/category/extensions")!

    /// The page's "Add to yab" was pressed: the extension this tab is showing.
    func addFromStore(_ tab: Tab) {
        guard #available(macOS 15.4, *), let url = tab.address, StoreOffer.isStorePage(url) else { return }
        if let page = tab.builtPage as? ChromiumPage, let id = Crx.id(in: url.absoluteString) {
            page.extensions.reviewInstall(id, browser: self)
            return
        }
        if let id = Crx.id(in: url.absoluteString) { storeAskers[id] = WeakTab(tab) }
        // Into the sign-in the store's tab is in, the profile its window
        // belongs to (ExtensionSignIns).
        Extensions.of(tab: tab).install(from: url.absoluteString)
    }

    /// An extension from the store is in, the yes given: its icon flies from
    /// its picture on the page that asked into the puzzle, which gives a
    /// hop when it lands, the landing says it is added, so no notice does.
    /// False when there is nothing to fly, the page not in front, no icon,
    /// Reduce Motion, and a notice should say so instead.
    func arrived(_ id: String, name: String, icon: NSImage?) -> Bool {
        guard #available(macOS 15.4, *),
              let tab = storeAskers.removeValue(forKey: id)?.tab, tab === active,
              let page = tab.webKitOnly("WebKit page message relay", build: false), page.window != nil,
              let icon, let sky = hoard.sky,
              !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        else { return false }
        let extensions = Extensions.of(tab: tab)
        // A beat for the question's sheet to go up, off the page.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self, weak page, weak sky] in
            guard let page, let sky else { return }
            page.evaluateInYab("window.__yabStore ? window.__yabStore.spot() : null") { result in
                MainActor.assumeIsolated {
                    let found = result as? [String: Any]
                    guard let start = (found?["logo"] as? [String: Any] ?? found?["button"] as? [String: Any]).flatMap({ Browser.rect($0, in: page) }) else {
                        extensions.hop()
                        return
                    }
                    sky.fly(icon: icon, from: start, to: {
                        guard let puzzle = extensions.anchors[Extensions.menuAnchor]?.view, puzzle.window === page.window else { return nil }
                        return puzzle.convert(NSPoint(x: puzzle.bounds.midX, y: puzzle.bounds.midY), to: nil)
                    }) { home in
                        page.evaluateInYab("window.__yabStore && window.__yabStore.landed()")
                        if home { extensions.hop() } else { self?.announce("\(name) installed", mark: "puzzlepiece.extension", feedback: .success) }
                    }
                }
            }
        }
        return true
    }

    /// A box the page measured, in CSS pixels from its top left, in the
    /// window's points.
    private static func rect(_ box: [String: Any], in page: WKWebView) -> CGRect? {
        guard let x = box["x"] as? Double, let y = box["y"] as? Double,
              let width = box["width"] as? Double, let height = box["height"] as? Double, width > 0, height > 0
        else { return nil }
        let zoom = page.pageZoom * page.magnification
        var rect = CGRect(x: x * zoom, y: y * zoom, width: width * zoom, height: height * zoom)
        if !page.isFlipped { rect.origin.y = page.bounds.height - rect.maxY }
        return page.convert(rect, to: nil)
    }

    /// Tells a store page what is installed and what is on its way, so its
    /// button can say "Added to yab" or "Adding…".
    func tellStore(_ tab: Tab) {
        guard #available(macOS 15.4, *), let url = tab.address, StoreOffer.isStorePage(url) else { return }
        let extensions = Extensions.of(tab: tab)
        tab.tellStore(installed: extensions.installed.map(\.id), busy: extensions.busy)
    }

    /// And tells every store page again whenever either changes.
    func followStore() {
        guard #available(macOS 15.4, *) else { return }
        // Any sign-in's list: each store page says its own sign-in's.
        storeWatch = Extensions.listsChanged
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in
                guard let self else { return }
                for tab in tabs where tab.webKitOnly("WebKit page message relay", build: false) != nil { tellStore(tab) }
            }
    }
}
