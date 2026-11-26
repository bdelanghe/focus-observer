// A tab that is `active` is only the selected tab OF ITS WINDOW. Whether the
// window is the one being looked at is a separate fact, and tab events arrive
// from every window whether or not it — or Chrome at all — has focus.

import assert from "node:assert/strict";
import { test } from "node:test";
import { loadExtension } from "./harness.mjs";

function browser() {
  const ext = loadExtension();
  ext.addWindow(1);
  ext.addWindow(2);
  ext.setTab({ id: 10, windowId: 1, url: "https://example.com/doc", title: "Doc" });
  ext.setTab({ id: 20, windowId: 2, url: "https://mail.example.com/inbox", title: "Inbox" });
  return ext;
}

test("a title change while Chrome is in the background opens no interval", async () => {
  const ext = browser();
  ext.focus(1);
  await ext.fire("tabs.onActivated", { tabId: 10, windowId: 1 });

  // Off to the terminal. The interval closes, as designed.
  await ext.fire("windows.onFocusChanged", ext.focus());
  assert.equal(ext.open(), undefined);

  // The page left behind retitles itself, as pages with counters do.
  const tab = ext.setTab({ id: 10, windowId: 1, url: "https://example.com/doc", title: "(1) Doc" });
  await ext.fire("tabs.onUpdated", 10, { title: tab.title }, tab);
  await ext.settle();

  assert.equal(ext.open(), undefined, "Chrome is not focused; nothing is being looked at");
});

test("a tab updating in another window does not take the interval", async () => {
  const ext = browser();
  ext.focus(1);
  await ext.fire("tabs.onActivated", { tabId: 10, windowId: 1 });

  // Window 2 sits behind window 1; its selected tab gets new mail.
  const tab = ext.setTab({ id: 20, windowId: 2, url: "https://mail.example.com/inbox", title: "(1) Inbox" });
  await ext.fire("tabs.onUpdated", 20, { title: tab.title }, tab);
  await ext.settle();

  assert.deepEqual(ext.spans, []);
  assert.equal(ext.open().url, "https://example.com/doc");
});

test("a tab selected in a window without focus does not take the interval", async () => {
  const ext = browser();
  ext.focus(1);
  await ext.fire("tabs.onActivated", { tabId: 10, windowId: 1 });

  await ext.fire("tabs.onActivated", { tabId: 20, windowId: 2 });
  await ext.settle();

  assert.deepEqual(ext.spans, []);
  assert.equal(ext.open().url, "https://example.com/doc");
});

test("the focused window still records navigation and tab switches", async () => {
  const ext = browser();
  ext.focus(1);
  await ext.fire("tabs.onActivated", { tabId: 10, windowId: 1 });

  const tab = ext.setTab({ id: 10, windowId: 1, url: "https://example.com/other", title: "Other" });
  await ext.fire("tabs.onUpdated", 10, { url: tab.url }, tab);
  await ext.settle();

  assert.deepEqual(ext.spans.map((s) => s["tab.url"]), ["https://example.com/doc"]);
  assert.equal(ext.open().url, "https://example.com/other");
});
