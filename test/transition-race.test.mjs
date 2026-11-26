// One interval closing must be one span, however many events report it.
//
// Clicking a tab in another Chrome window fires `tabs.onActivated` and
// `windows.onFocusChanged` together, and a navigation fires `tabs.onUpdated`
// for the URL and again for the title. Each handler closes the open interval.

import assert from "node:assert/strict";
import { test } from "node:test";
import { loadExtension } from "./harness.mjs";

function browser(options) {
  const ext = loadExtension(options);
  ext.addWindow(1);
  ext.addWindow(2);
  ext.setTab({ id: 10, windowId: 1, url: "https://example.com/a", title: "A" });
  ext.setTab({ id: 20, windowId: 2, url: "https://example.com/b", title: "B" });
  return ext;
}

test("two events for one switch close the interval once", async () => {
  const ext = browser();
  ext.focus(1);
  await ext.fire("tabs.onActivated", { tabId: 10, windowId: 1 });

  ext.focus(2);
  await Promise.all([
    ext.fire("tabs.onActivated", { tabId: 20, windowId: 2 }),
    ext.fire("windows.onFocusChanged", 2),
  ]);
  await ext.settle();

  assert.deepEqual(ext.spans.map((s) => s["tab.url"]), ["https://example.com/a"]);
  assert.equal(ext.open().url, "https://example.com/b");
});

test("a collector that never answers does not hold the next interval back", async () => {
  // Accepts the POST and never responds: the open interval must still move on,
  // or the page being left keeps absorbing time spent on the next one.
  const ext = browser({ fetch: () => new Promise(() => {}) });
  ext.focus(1);
  await ext.fire("tabs.onActivated", { tabId: 10, windowId: 1 });

  ext.focus(2);
  ext.fire("tabs.onActivated", { tabId: 20, windowId: 2 });
  await ext.settle();

  assert.equal(ext.open().url, "https://example.com/b");
});
