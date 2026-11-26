// The query string is refused in `tab.url`. It must not come back in through
// `tab.title`.
//
// Chrome titles a page that has no <title> — and every page for the first
// moments of loading — with its own URL: scheme and `www.` dropped, escapes
// and punycode decoded, QUERY AND FRAGMENT KEPT. The titles below are what
// Chromium reported for those URLs, not guesses at its formatting.

import assert from "node:assert/strict";
import { test } from "node:test";
import { loadExtension } from "./harness.mjs";

/** Focus a tab, leave it, and return the one span that closes. */
async function spanFor(url, title) {
  const ext = loadExtension();
  ext.addWindow(1);
  ext.focus(1);
  ext.setTab({ id: 10, windowId: 1, url, title });
  await ext.fire("tabs.onActivated", { tabId: 10, windowId: 1 });
  await ext.fire("windows.onFocusChanged", ext.focus());
  await ext.settle();
  assert.equal(ext.spans.length, 1);
  return ext.spans[0];
}

const urlTitles = [
  ["http://127.0.0.1:8765/search?q=SECRET#frag", "127.0.0.1:8765/search?q=SECRET#frag"],
  ["https://www.example.test/a?q=SECRET%20words&x=%E2%9C%93", "example.test/a?q=SECRET words&x=✓"],
  ["https://xn--bcher-kva.test/b?token=SECRET", "bücher.test/b?token=SECRET"],
  ["https://example.test/c%20d/e#SECRET", "example.test/c d/e#SECRET"],
  ["https://example.test/?code=SECRET", "https://example.test/?code=SECRET"],
];

for (const [url, title] of urlTitles) {
  test(`no query or fragment in the title of ${url}`, async () => {
    const span = await spanFor(url, title);
    assert.doesNotMatch(JSON.stringify(span), /SECRET/);
    assert.equal(span["tab.title"], "");
    assert.equal(span["tab.has_query"], true);
  });
}

test("a real title is kept, question marks and all", async () => {
  const span = await spanFor("https://example.test/search?q=sky", "why is the sky blue? - Search");
  assert.equal(span["tab.title"], "why is the sky blue? - Search");
});

test("a real title that merely names the site is kept", async () => {
  const span = await spanFor("https://example.test/?ref=home", "example.test");
  assert.equal(span["tab.title"], "example.test");
});

test("a URL title with nothing to hide is left alone", async () => {
  const span = await spanFor("https://example.test/plain.txt", "example.test/plain.txt");
  assert.equal(span["tab.title"], "example.test/plain.txt");
});
