// A fake `chrome` for extension/background.js, so its behaviour can be tested
// under plain `node --test` — no browser, no collector.
//
// The fake is asynchronous on purpose: every chrome.* call and every POST
// resolves on a later turn of the event loop, as the real ones do. Handlers
// fired together therefore interleave the way they do in a service worker.

import { readFileSync } from "node:fs";
import vm from "node:vm";

const SOURCE = new URL("../extension/background.js", import.meta.url);
const WINDOW_ID_NONE = -1;

const turn = () => new Promise((resolve) => setImmediate(resolve));

/**
 * Load background.js against a fake browser.
 *
 * `fetch` replaces the collector; by default every POST succeeds on a later
 * turn. Either way each span posted is recorded in `spans`.
 */
export function loadExtension({ fetch } = {}) {
  const store = {};
  const spans = [];
  const listeners = {};
  const tabs = new Map();
  const windows = new Map();
  let lastFocused = null;

  const event = (name) => ({ addListener: (fn) => { listeners[name] = fn; } });

  const chrome = {
    storage: {
      session: {
        async get(key) {
          await turn();
          return key in store ? { [key]: structuredClone(store[key]) } : {};
        },
        async set(items) {
          await turn();
          Object.assign(store, structuredClone(items));
        },
        async remove(key) {
          await turn();
          delete store[key];
        },
      },
    },
    tabs: {
      onActivated: event("tabs.onActivated"),
      onUpdated: event("tabs.onUpdated"),
      async get(id) {
        await turn();
        if (!tabs.has(id)) throw new Error(`No tab with id: ${id}.`);
        return { ...tabs.get(id) };
      },
      async query({ active, lastFocusedWindow }) {
        await turn();
        return [...tabs.values()]
          .filter((t) => !active || t.active)
          .filter((t) => !lastFocusedWindow || t.windowId === lastFocused)
          .map((t) => ({ ...t }));
      },
    },
    windows: {
      WINDOW_ID_NONE,
      onFocusChanged: event("windows.onFocusChanged"),
      async get(id) {
        await turn();
        if (!windows.has(id)) throw new Error(`No window with id: ${id}.`);
        return { ...windows.get(id) };
      },
    },
    runtime: {
      onStartup: event("runtime.onStartup"),
      onInstalled: event("runtime.onInstalled"),
    },
  };

  const collector = fetch ?? (async () => { await turn(); return { ok: true, status: 200 }; });
  const fakeFetch = (url, init) => {
    const span = JSON.parse(init.body).resourceSpans[0].scopeSpans[0].spans[0];
    spans.push({
      name: span.name,
      start: span.startTimeUnixNano,
      end: span.endTimeUnixNano,
      ...Object.fromEntries(span.attributes.map((a) => [a.key, Object.values(a.value)[0]])),
    });
    return collector(url, init);
  };

  vm.runInNewContext(readFileSync(SOURCE, "utf8"), {
    chrome, fetch: fakeFetch, crypto: globalThis.crypto, URL, AbortSignal, setTimeout, clearTimeout, console,
  }, { filename: "background.js" });

  return {
    /** Spans posted to the collector so far, attributes flattened. */
    spans,
    /** The open interval in chrome.storage.session, or undefined. */
    open: () => store["open-interval"],

    /** Add or replace a window. Windows start unfocused; see `focus`. */
    addWindow(id) {
      windows.set(id, { id, focused: false });
    },
    /** Add or replace a tab. Returns the tab as an event would carry it. */
    setTab(tab) {
      tabs.set(tab.id, { active: true, title: "", ...tab });
      return { ...tabs.get(tab.id) };
    },
    /**
     * Move OS focus to a window, or away from the browser entirely with no
     * argument. Updates browser state only — fire the event separately.
     */
    focus(id = WINDOW_ID_NONE) {
      for (const w of windows.values()) w.focused = w.id === id;
      if (id !== WINDOW_ID_NONE) lastFocused = id;
      return id;
    },

    /** Fire a browser event at the extension; resolves when its handler does. */
    fire(name, ...args) {
      return Promise.resolve(listeners[name](...args));
    },
    /** Let everything already in flight finish. */
    async settle(turns = 50) {
      for (let i = 0; i < turns; i++) await turn();
    },
  };
}
