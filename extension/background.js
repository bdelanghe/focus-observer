// focus-observer: tabs — which page inside Chrome, as intervals.
//
// `focus-observer` (the Swift agent) says Chrome had the screen, and with
// Accessibility it says which window. Neither can say which TAB: a browser
// window's AX title is the active tab's title, so it changes without a window
// change and the interval boundaries land in the wrong places. Only the
// browser knows when a tab became active.
//
// This is the one signal in the stack that has to come from inside the app,
// and it is why an extension beats a proxy here. A proxy would need a CA in
// the trust store to see URLs at all, would still only see REQUESTS rather
// than tab identity, and would have to guess which of a page's hundred
// requests was the one you were looking at. The extension is both narrower
// and more accurate.
//
// # What is recorded, and what is refused
//
// Origin and pathname. NOT the query string, NOT the fragment.
//
// A path names the thing — a repo, an issue, a document, a channel. A query
// string is usually its CONTENTS: `?q=` is what you searched for, and OAuth
// and session tokens ride there too. That is the same line the Swift observer
// draws at window titles versus element values, and the same one that got
// Recall recalled.
//
// The refusal is recorded rather than silent: `tab.has_query` says a query
// string was present and dropped, so a reader can tell "no query" from
// "query removed" without being able to reconstruct it.
//
// # MV3 has no memory
//
// A service worker is killed after ~30s idle, so an interval cannot live in a
// variable — the worker holding it will be gone before the interval ends.
// State goes in `chrome.storage.session`: every event wakes the worker, which
// reads the open interval, closes it, and writes the new one. Nothing is kept
// across the gap except that record.
//
// `chrome.storage.session` and not `local`: this is ephemeral focus state, it
// should not survive a browser restart, and it never belongs on disk.

const OTLP = "http://127.0.0.1:4318/v1/traces";
const KEY = "open-interval";

const hex = (bytes) =>
  Array.from(crypto.getRandomValues(new Uint8Array(bytes)))
    .map((b) => b.toString(16).padStart(2, "0"))
    .join("");

const str = (key, value) => ({ key, value: { stringValue: String(value) } });
const bool = (key, value) => ({ key, value: { boolValue: !!value } });

/**
 * Origin + pathname, and whether a query string was dropped.
 *
 * Returns null for anything that is not http(s) — chrome://, devtools://,
 * file:// and extension pages are either not browsing or are local paths that
 * say more about the filesystem than about attention.
 */
function redact(rawUrl) {
  let u;
  try {
    u = new URL(rawUrl);
  } catch {
    return null;
  }
  if (u.protocol !== "http:" && u.protocol !== "https:") return null;
  return {
    url: u.origin + u.pathname,
    hasQuery: u.search.length > 0 || u.hash.length > 0,
  };
}

async function emit(open, end) {
  const ns = (ms) => String(Math.round(ms * 1e6));
  const payload = {
    resourceSpans: [{
      resource: {
        attributes: [
          str("service.name", "focus-observer-tabs"),
          str("browser", "chrome"),
        ],
      },
      scopeSpans: [{
        scope: { name: "focus-observer-tabs" },
        spans: [{
          traceId: hex(16),
          spanId: hex(8),
          name: "tab.focused",
          kind: 1,
          startTimeUnixNano: ns(open.start),
          endTimeUnixNano: ns(end),
          attributes: [
            str("tab.url", open.url),
            str("tab.title", open.title),
            // The refusal, made visible. A reader can tell "there was no
            // query" from "a query was dropped" without recovering it.
            bool("tab.has_query", open.hasQuery),
          ],
        }],
      }],
    }],
  };

  try {
    await fetch(OTLP, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(payload),
    });
  } catch {
    // NO RETRY QUEUE, matching the Swift observer: a collector that is down
    // is a dropped span. Queuing focus history in extension storage would
    // turn a restarting collector into unbounded growth in something the user
    // never sees.
  }
}

/**
 * Close whatever interval is open and, if `next` is given, open a new one.
 *
 * `next` is null when focus left the browser entirely. That case is the whole
 * reason `windows.onFocusChanged` is observed: without it, a tab interval
 * keeps running while you are in another app, and Chrome absorbs every minute
 * you spent in the terminal.
 */
async function transition(next) {
  const now = Date.now();
  const { [KEY]: open } = await chrome.storage.session.get(KEY);

  if (open) {
    // Re-activating the same page is not a switch. Chrome fires onUpdated
    // several times per navigation, and onActivated again when a window
    // regains focus on the tab it already had.
    if (next && next.url === open.url && next.title === open.title) return;
    await emit(open, now);
  }

  if (next) {
    await chrome.storage.session.set({ [KEY]: { ...next, start: now } });
  } else {
    await chrome.storage.session.remove(KEY);
  }
}

/** Build the interval record for a tab, or null if it is not observable. */
function intervalFor(tab) {
  if (!tab || !tab.url) return null;
  const r = redact(tab.url);
  if (!r) return null;
  return { url: r.url, hasQuery: r.hasQuery, title: tab.title || "" };
}

async function activeTab() {
  const [tab] = await chrome.tabs.query({ active: true, lastFocusedWindow: true });
  return tab;
}

chrome.tabs.onActivated.addListener(async ({ tabId }) => {
  try {
    await transition(intervalFor(await chrome.tabs.get(tabId)));
  } catch {
    // A tab that closed between the event and the lookup.
  }
});

// A navigation inside the tab you are already on is a new interval — going
// from one issue to another in the same tab is a change of subject, and
// without this it would read as one long interval on whichever page was first.
chrome.tabs.onUpdated.addListener(async (_id, changeInfo, tab) => {
  if (!tab.active) return;
  // `status` fires twice per navigation and `title` often lands after `url`;
  // only act once the URL has settled.
  if (!changeInfo.url && !changeInfo.title) return;
  await transition(intervalFor(tab));
});

chrome.windows.onFocusChanged.addListener(async (windowId) => {
  if (windowId === chrome.windows.WINDOW_ID_NONE) {
    // Chrome lost OS focus. Close the interval — the Swift observer's
    // `app.focused` span for whatever took the screen begins here, and the
    // two line up.
    await transition(null);
    return;
  }
  try {
    await transition(intervalFor(await activeTab()));
  } catch {
    // No focusable tab in that window.
  }
});

// A browser that is already open when the extension loads or the worker
// restarts. Without this the current tab goes unrecorded until the next
// switch.
chrome.runtime.onStartup.addListener(async () => {
  await transition(intervalFor(await activeTab()));
});
chrome.runtime.onInstalled.addListener(async () => {
  await transition(intervalFor(await activeTab()));
});
