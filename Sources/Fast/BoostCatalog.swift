import Foundation

/// The first shelf is shipped with Yab. Every entry is a readable CSS recipe;
/// trials still run in a separate tab and only Keep makes one persistent.
enum BoostCatalog {
    struct Entry: Identifiable {
        let id: String
        let name: String
        let site: String
        let path: String
        let intent: String
        let css: String
        let check: String
        var url: URL { URL(string: "https://" + site + path)! }
        var files: [String: String] {
            ["manifest.json": BoostScript.json(["manifest_version": 3, "name": name, "version": "1.0.0",
                "content_scripts": [["matches": ["https://" + site + "/*"], "css": ["style.css"], "run_at": "document_end"]]]),
             "style.css": css,
             "BOOST.md": "---\nname: \(name)\nsites: \(site)\nmade: \(Brand.name) recipe\npreview: \(url.absoluteString)\nchecks:\n  - on /*: \(check)\n  - on /*: some of body\n---\n\n\(intent)"]
        }
    }
    static let entries: [Entry] = [
        .init(id: "youtube-no-shorts", name: "Hide Shorts", site: "www.youtube.com", path: "/results?search_query=minecraft", intent: "Hide YouTube Shorts shelves and Shorts links.", css: "ytd-reel-shelf-renderer,\nytd-rich-shelf-renderer[is-shorts],\ngrid-shelf-view-model:has(a[href^='/shorts/']),\nytd-rich-section-renderer:has(a[href^='/shorts/']),\nytd-rich-item-renderer:has(a[href^='/shorts/']),\nytd-video-renderer:has(a[href^='/shorts/']),\na[href^='/shorts/'] { display: none !important; }", check: "none of ytd-reel-shelf-renderer, ytd-rich-shelf-renderer[is-shorts], grid-shelf-view-model:has(a[href^='/shorts/']), a[href^='/shorts/']"),
        .init(id: "youtube-no-comments", name: "Hide video comments", site: "www.youtube.com", path: "/watch?v=jNQXAC9IVRw", intent: "Hide YouTube comments below videos.", css: "ytd-comments { display: none !important; }", check: "none of ytd-comments"),
        .init(id: "youtube-no-related", name: "Hide related videos", site: "www.youtube.com", path: "/watch?v=jNQXAC9IVRw", intent: "Hide related videos beside YouTube's player.", css: "ytd-watch-next-secondary-results-renderer { display: none !important; }", check: "none of ytd-watch-next-secondary-results-renderer"),
        .init(id: "x-no-trends", name: "Hide trends", site: "x.com", path: "/home", intent: "Hide the What's happening and trending blocks on X.", css: "[aria-label='Timeline: Trending now'], [data-testid='trend'] { display: none !important; }", check: "none of [data-testid='trend']"),
        .init(id: "x-no-follow-suggestions", name: "Hide follow suggestions", site: "x.com", path: "/home", intent: "Hide Who to follow suggestions on X.", css: "aside[aria-label='Who to follow'] { display: none !important; }", check: "none of aside[aria-label='Who to follow']"),
        .init(id: "x-hide-counts", name: "Hide engagement counts", site: "x.com", path: "/home", intent: "Hide numerical engagement counts on X tweets, keeping the action buttons.", css: "[data-testid='tweet'] [data-testid='app-text-transition-container'] { visibility: hidden !important; }", check: "none of [data-testid='tweet'] [data-testid='app-text-transition-container']"),
        .init(id: "github-wide-repository", name: "Wider repositories", site: "github.com", path: "/swiftlang/swift", intent: "Let GitHub repository content use the full available width.", css: ".container-xl { max-width: none !important; }", check: "some of .container-xl"),
        .init(id: "github-readable-code", name: "Larger code", site: "github.com", path: "/swiftlang/swift/blob/main/CMakeLists.txt", intent: "Make source code and diffs on GitHub easier to read.", css: ".blob-code, .blob-code-inner, [data-testid='code-cell'] { font-size: 14px !important; line-height: 1.7 !important; }\n#read-only-cursor-text-area { font-size: 14px !important; }", check: "some of [data-testid='code-cell'], .blob-code-inner"),
        .init(id: "github-no-dashboard-feed", name: "Quiet GitHub home", site: "github.com", path: "/", intent: "Hide the activity feed on GitHub's dashboard.", css: "[data-target='feed-container.feed'], .feed-content { display: none !important; }", check: "none of .feed-content"),
        .init(id: "hn-readable", name: "Readable Hacker News", site: "news.ycombinator.com", path: "/", intent: "Make Hacker News text larger with more breathing room.", css: "body, td, .comment, .title, .comhead, .subtext { font-size: 15px !important; line-height: 1.65 !important; }\n.spacer { height: 12px !important; }", check: "some of .title"),
        .init(id: "hn-hide-scores", name: "Hide HN scores", site: "news.ycombinator.com", path: "/", intent: "Hide Hacker News scores while keeping stories and comments.", css: ".score { display: none !important; }", check: "none of .score"),
        .init(id: "hn-wide-comments", name: "Roomier HN comments", site: "news.ycombinator.com", path: "/item?id=1", intent: "Give Hacker News discussions a readable width and spacing.", css: ".comment { max-width: 78ch; line-height: 1.7 !important; }\n.comtr td { padding-bottom: 6px; }", check: "some of .comment"),
        .init(id: "wikipedia-readable", name: "Readable Wikipedia", site: "en.wikipedia.org", path: "/wiki/Main_Page", intent: "Make Wikipedia's article text larger and easier to read.", css: ".mw-parser-output { font-size: 18px !important; line-height: 1.7 !important; }", check: "some of .mw-parser-output"),
        .init(id: "wikipedia-wide", name: "Wide Wikipedia articles", site: "en.wikipedia.org", path: "/wiki/Web_browser", intent: "Let Wikipedia articles use more of the window.", css: ".mw-page-container, .vector-header, .mw-body, .mw-content-container { max-width: none !important; }", check: "some of .mw-page-container"),
        .init(id: "stackoverflow-hide-hot", name: "Hide hot network questions", site: "stackoverflow.com", path: "/questions", intent: "Hide Hot Network Questions on Stack Overflow.", css: "#hot-network-questions { display: none !important; }", check: "none of #hot-network-questions"),
        .init(id: "stackoverflow-readable-code", name: "Larger code examples", site: "stackoverflow.com", path: "/questions/11227809/why-is-processing-a-sorted-array-faster-than-processing-an-unsorted-array", intent: "Make Stack Overflow code examples larger.", css: "pre, code { font-size: 14px !important; line-height: 1.65 !important; }", check: "some of pre"),
        .init(id: "reddit-hide-sidebar", name: "Quiet Reddit sidebar", site: "www.reddit.com", path: "/", intent: "Hide Reddit's right sidebar while keeping the feed.", css: "#right-sidebar-container { display: none !important; }", check: "none of #right-sidebar-container"),
        .init(id: "reddit-hide-promoted", name: "Hide promoted Reddit cards", site: "www.reddit.com", path: "/", intent: "Hide cards marked as promoted on Reddit.", css: "shreddit-ad-post, [data-promoted='true'] { display: none !important; }", check: "none of shreddit-ad-post"),
        .init(id: "mdn-readable", name: "Readable MDN", site: "developer.mozilla.org", path: "/en-US/docs/Web", intent: "Make MDN article text larger and code easier to read.", css: "main { font-size: 18px !important; line-height: 1.7 !important; }\npre { line-height: 1.65 !important; }", check: "some of main"),
        .init(id: "npm-readable-readme", name: "Readable package docs", site: "www.npmjs.com", path: "/package/react", intent: "Make npm package READMEs easier to read.", css: "#readme { font-size: 17px !important; line-height: 1.7 !important; max-width: 85ch; }", check: "some of #readme"),
    ]
}
