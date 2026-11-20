import AppKit
import Testing
import WebKit
@testable import Fast

@MainActor @Suite(.serialized)
struct ChromiumStoreButtonTests {
    private func fixture(_ html: String, beforeScript: String = "") async throws -> WKWebView {
        _ = NSApplication.shared
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        let address = "https://chromewebstore.google.com/detail/example/kmnmkpgmneeokldcmfcgjppgpcfecoed"
        web.loadHTMLString("<html><body>" + html + "</body></html>", baseURL: URL(string: address)!)
        let loaded = try await Loaded.until(30, every: .milliseconds(50)) {
            (try? await web.evaluateJavaScript("location.href + ' ' + document.readyState")) as? String == address + " complete"
        }
        try #require(loaded)
        _ = try await web.evaluateJavaScript("window.messages=[];window.yabChromiumStore=m=>messages.push(JSON.parse(m)); true;")
        if !beforeScript.isEmpty { _ = try await web.evaluateJavaScript(beforeScript) }
        _ = try await web.evaluateJavaScript(ChromiumStoreBridge.script)
        return web
    }

    @Test func observingTheInstallControlNeverObservesThePageOrPolls() async throws {
        let web = try await fixture("<header><div id='action'><button disabled>Add to Chrome</button></div></header>", beforeScript: """
        window.observed=[];window.storeTimers=0;
        const NativeObserver=MutationObserver;
        window.MutationObserver=class extends NativeObserver {
            observe(root,options){observed.push({id:root.id,broad:root===document||root===document.body||root===document.documentElement});super.observe(root,options)}
        };
        const timeout=window.setTimeout;
        window.setTimeout=(...args)=>{storeTimers++;return timeout(...args)};
        true;
        """)
        #expect(try await web.evaluateJavaScript("observed.length>0 && observed.every(o=>!o.broad && o.id==='action')") as? Bool == true)
        #expect(try await web.evaluateJavaScript("storeTimers") as? Int == 0)
        _ = try await web.evaluateJavaScript("__yabStore.state({installed:[],busy:'kmnmkpgmneeokldcmfcgjppgpcfecoed'}); true")
        #expect(try await web.evaluateJavaScript("document.querySelector('button[data-yab=add]').textContent") as? String == "Adding…")
        _ = try await web.evaluateJavaScript("__yabStore.state({installed:[],busy:null}); true")
        #expect(try await web.evaluateJavaScript("document.querySelector('button[data-yab=add]').disabled") as? Bool == false)
    }

    @Test func hydrationCanRemoveTheCloneWithoutRemovingTheOriginal() async throws {
        let web = try await fixture("<header><h1>Extension</h1><div><button disabled id='install'>Add to Chrome</button></div></header>")
        _ = try await web.evaluateJavaScript("document.querySelector('button[data-yab=add]').remove(); true")
        let recovered = try await Loaded.until(3, every: .milliseconds(50)) {
            (try? await web.evaluateJavaScript("document.querySelectorAll('button[data-yab=add]').length")) as? Int == 1
        }
        #expect(recovered)
        #expect(try await web.evaluateJavaScript("document.querySelector('h1').getClientRects().length > 0") as? Bool == true)
    }

    @Test func aHiddenPromoCannotGrowIntoTheExtensionHeaderDuringRedraw() async throws {
        let web = try await fixture("""
        <section id='detail'><div id='promo'><div><button aria-label='Install Chrome'>Install Chrome</button></div></div>
        <section><h1>Extension</h1><div id='action'><button disabled>Add to Chrome</button></div></section></section>
        """)
        // The store tears down the old action before inserting its enabled
        // replacement. A second scan still sees the hidden Install Chrome.
        _ = try await web.evaluateJavaScript("document.getElementById('action').replaceChildren(); true")
        _ = try await web.evaluateJavaScript("window.dispatchEvent(new PageTransitionEvent('pageshow')); true")
        try await Task.sleep(for: .milliseconds(200))
        let kept = try await Loaded.until(3, every: .milliseconds(50)) {
            (try? await web.evaluateJavaScript("getComputedStyle(document.getElementById('detail')).display !== 'none'")) as? Bool == true
        }
        #expect(kept)
        #expect(try await web.evaluateJavaScript("document.getElementById('detail').dataset.yab || ''") as? String == "")
    }

    @Test func onlyChromePromotionsMayBeHiddenAndAnInstalledHeaderStays() async throws {
        let web = try await fixture("""
        <section id='header'><h1>Extension</h1><button aria-label='Remove from Chrome'>Remove from Chrome</button></section>
        <aside id='banner'><button aria-label='Download Chrome'>Download Chrome</button></aside>
        <div role='dialog'><img src='https://example.com/productlogos/chrome/logo.png'><button>Switch</button></div>
        """)
        #expect(try await web.evaluateJavaScript("getComputedStyle(document.getElementById('header')).display !== 'none'") as? Bool == true)
        #expect(try await web.evaluateJavaScript("document.querySelectorAll('button[data-yab=add]').length") as? Int == 1)
        _ = try await web.evaluateJavaScript("__yabStore.state({installed:['kmnmkpgmneeokldcmfcgjppgpcfecoed'],busy:null}); true")
        #expect(try await web.evaluateJavaScript("document.querySelector('button[data-yab=add]').textContent") as? String == "Added to Pane")
        #expect(try await web.evaluateJavaScript("document.querySelector('button[data-yab=add]').disabled") as? Bool == true)
        #expect(try await web.evaluateJavaScript("getComputedStyle(document.querySelector('[role=dialog]')).display") as? String == "none")
    }

    @Test func syntheticClicksCannotAskToInstallAndReinjectionIsIdempotent() async throws {
        let web = try await fixture("<header><button disabled>Add to Chrome</button></header>")
        _ = try await web.evaluateJavaScript(ChromiumStoreBridge.script)
        _ = try await web.evaluateJavaScript("document.querySelector('button[data-yab=add]').click(); true")
        #expect(try await web.evaluateJavaScript("messages.filter(m=>m.add).length") as? Int == 0)
        #expect(try await web.evaluateJavaScript("document.querySelectorAll('button[data-yab=add]').length") as? Int == 1)
    }

    @Test(arguments: ["Ajouter à Google\u{00a0}Chrome", "添加至 Chrome", "Добавить в Chrome", "Zu Chrome hinzufügen", "Add to Chrome"])
    func enabledLocalizedInstallButtonsUseTheReviewRegardlessOfHydration(label: String) async throws {
        let web = try await fixture("""
        <aside><button aria-label="Install Chrome" id="promo">Install Chrome</button></aside>
        <div hidden><button id="stale">Add to Chrome</button></div>
        <section><h1>Dark Reader</h1><div id="action"><button id="install">\(label)</button></div></section>
        """)
        #expect(try await web.evaluateJavaScript("document.querySelectorAll('button[data-yab=add]').length") as? Int == 1)
        #expect(try await web.evaluateJavaScript("document.querySelector('#action button[data-yab=add]')?.textContent") as? String == "Add to Pane")
        #expect(try await web.evaluateJavaScript("document.querySelector('#action button[data-yab=add]')?.disabled") as? Bool == false)
        #expect(try await web.evaluateJavaScript("document.getElementById('stale').dataset.yab || ''") as? String == "")
        #expect(try await web.evaluateJavaScript("document.getElementById('promo').dataset.yab || ''") as? String == "")
        #expect(try await web.evaluateJavaScript("messages.filter(m=>m.placed).length") as? Int == 1)
        // The store replaces its control during hydration, already enabled.
        _ = try await web.evaluateJavaScript("""
        const next=document.createElement('button');
        next.textContent=document.getElementById('install').textContent;
        document.getElementById('action').replaceChildren(next);true;
        """)
        let repaired = try await Loaded.until(3, every: .milliseconds(50)) {
            (try? await web.evaluateJavaScript("document.querySelector('#action button[data-yab=add]')?.textContent")) as? String == "Add to Pane"
        }
        #expect(repaired)
        _ = try await web.evaluateJavaScript("document.querySelector('#action button[data-yab=add]').click();true")
        #expect(try await web.evaluateJavaScript("messages.filter(m=>m.add).length") as? Int == 0)
    }

    @Test(arguments: ["添加至 Chrome", "Добавить в Chrome", "Zu Chrome hinzufügen", "Add to Chrome"])
    func disabledLocalizedInstallButtonsKeepTheExistingYabReplacement(label: String) async throws {
        _ = NSApplication.shared
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        let address = "https://chromewebstore.google.com/detail/example/kmnmkpgmneeokldcmfcgjppgpcfecoed"
        web.loadHTMLString("""
        <html><body><header><button disabled id="install">\(label)</button></header>
        <aside><button aria-label="Download Chrome" id="promo">Download Chrome</button></aside>
        <button disabled id="unrelated">Unrelated</button></body></html>
        """, baseURL: URL(string: address)!)
        let loaded = try await Loaded.until(30, every: .milliseconds(50)) {
            (try? await web.evaluateJavaScript("location.href + ' ' + document.readyState")) as? String == address + " complete"
        }
        try #require(loaded)
        _ = try await web.evaluateJavaScript("window.messages=[];window.yabChromiumStore=m=>messages.push(JSON.parse(m)); true;")
        _ = try await web.evaluateJavaScript(ChromiumStoreBridge.script)
        let result = try #require(try await web.evaluateJavaScript("""
        JSON.stringify({count:document.querySelectorAll('button[data-yab="add"]').length,
            label:document.querySelector('button[data-yab="add"]')?.textContent,
            enabled:document.querySelector('button[data-yab="add"]')?.disabled===false,
            placed:messages[0]?.placed,
            promo:document.getElementById('promo').dataset.yab||null,
            unrelated:document.getElementById('unrelated').dataset.yab||null})
        """) as? String)
        let state = try #require(try JSONSerialization.jsonObject(with: Data(result.utf8)) as? [String: Any])
        #expect(state["count"] as? Int == 1)
        #expect(state["label"] as? String == "Add to Pane")
        #expect(state["enabled"] as? Bool == true)
        #expect(state["placed"] as? String == "kmnmkpgmneeokldcmfcgjppgpcfecoed")
        #expect(state["promo"] is NSNull)
        #expect(state["unrelated"] is NSNull)
    }
}
