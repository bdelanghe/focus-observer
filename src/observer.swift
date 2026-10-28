// focus-observer — which application has the screen, as intervals rather than
// samples.
//
// `app-attention` polls `lsappinfo front` once a minute. That has two costs
// nothing can fix from inside a poller: an app used for thirty seconds may
// never be sampled at all, and every interval is quantised to the sampling
// grid. This subscribes instead, so a focus change is an event with a real
// start and a real end.
//
// EMITS SPANS, NOT LOG RECORDS, and that is the whole reason to write it. A
// focus interval IS a span — it has a start, an end and a duration — whereas
// `attention-poller` emits log records because a sample has only an instant.
// The end is only known when the NEXT activation arrives, so a span is closed
// on the switch that ends it, never on the one that starts it.
//
// # No permissions
//
// NSWorkspace's activation notifications need no Accessibility grant, no
// Screen Recording grant, and no NSApplication. Verified on this machine: a
// plain command-line tool with a run loop receives them. That keeps this on
// the same side of the line as `lsappinfo` and `ioreg` — the narrowest
// capability that answers the question.
//
// What it records is a bundle id, a display name and a pid. NOT window
// titles, which need Screen Recording and carry document names, subject lines
// and URLs. The AX route to per-element focus is a deliberate later decision,
// not an oversight.

import AppKit
import ApplicationServices
import Foundation

// MARK: - Configuration

let otlpTraces = ProcessInfo.processInfo.environment["OTLP_TRACES_URL"]
  ?? "http://127.0.0.1:4318/v1/traces"

// MARK: - State

/// The focus interval currently open. Closed and emitted when the next
/// activation arrives, or when the daemon is asked to stop.
struct Focus {
  let bundleId: String
  let name: String
  let pid: Int32
  let start: Date
  /// True when the daemon started with this app already frontmost. The START
  /// is then the daemon's start, not the app's — an unknown we record rather
  /// than round off, so a reader can drop these instead of trusting them.
  let partial: Bool
}

var current: Focus?
var emitted = 0
var dropped = 0

// MARK: - OTLP

func hex(_ bytes: Int) -> String {
  (0 ..< bytes).map { _ in String(format: "%02x", Int.random(in: 0 ... 255)) }.joined()
}

func attr(_ key: String, _ value: String) -> [String: Any] {
  ["key": key, "value": ["stringValue": value]]
}

func attr(_ key: String, _ value: Int) -> [String: Any] {
  ["key": key, "value": ["intValue": String(value)]]
}

func attr(_ key: String, _ value: Bool) -> [String: Any] {
  ["key": key, "value": ["boolValue": value]]
}

/// Post one closed interval as a span.
///
/// Each span gets its own trace id today. The seam for correlating focus with
/// what an agent did is here: a shared trace id, or a `session.id` attribute
/// carrying the Claude conversation, would make "what was on screen while the
/// agent ran this tool" a single query. Deliberately not guessed at yet.
func emit(_ f: Focus, end: Date) {
  let ns = { (d: Date) in String(Int64(d.timeIntervalSince1970 * 1_000_000_000)) }
  let payload: [String: Any] = [
    "resourceSpans": [[
      "resource": ["attributes": [
        attr("service.name", "focus-observer"),
        attr("host.name", Host.current().localizedName ?? "unknown"),
      ]],
      "scopeSpans": [[
        "scope": ["name": "focus-observer"],
        "spans": [[
          "traceId": hex(16),
          "spanId": hex(8),
          "name": "app.focused",
          "kind": 1,
          "startTimeUnixNano": ns(f.start),
          "endTimeUnixNano": ns(end),
          "attributes": [
            attr("app.bundle_id", f.bundleId),
            attr("app.name", f.name),
            attr("app.pid", Int(f.pid)),
            // A span whose start is the daemon's start rather than the app's.
            // Present on exactly one span per daemon lifetime.
            attr("focus.partial", f.partial),
          ],
        ]],
      ]],
    ]],
  ]

  post(payload)
}

/// Ship one OTLP payload. Shared by every span kind so the drop accounting,
/// the timeout and the no-retry rule are stated once.
func post(_ payload: [String: Any]) {
  guard let body = try? JSONSerialization.data(withJSONObject: payload) else {
    dropped += 1
    return
  }
  var req = URLRequest(url: URL(string: otlpTraces)!)
  req.httpMethod = "POST"
  req.setValue("application/json", forHTTPHeaderField: "Content-Type")
  req.httpBody = body
  // Short timeout, and NO RETRY QUEUE. The collector being down is a dropped
  // span, counted and reported on exit — buffering focus history in memory
  // would turn a restarting collector into unbounded growth in a process that
  // is meant to run for weeks.
  req.timeoutInterval = 5

  URLSession.shared.dataTask(with: req) { _, response, error in
    if error != nil || (response as? HTTPURLResponse)?.statusCode != 200 {
      dropped += 1
    } else {
      emitted += 1
    }
  }.resume()
}

// MARK: - Accessibility

// Which WINDOW inside the focused app, and how much it was worked in.
//
// NSWorkspace stops at the app. That is enough to say "Ghostty had the
// screen" and not enough to say which repo, which document, which channel —
// and for a browser or an editor the app is nearly the least informative
// thing about the interval.
//
// # What is recorded, and what is refused
//
// The window TITLE, and a COUNT of focused-element changes. Nothing else.
//
// Element titles and values are deliberately not read. `kAXValueAttribute` on
// a focused text field is its contents — a search box, a password field
// before it is masked, a message being typed. That is keystroke-adjacent
// content, and it is the exact data that got Recall recalled. The count
// answers what the interval-level question actually needs — was this window
// being worked in, or merely open — without recording what was typed into it.
//
// Titles are already a real disclosure (document names, subject lines, URLs)
// and are the reason this needs the Accessibility grant at all. That is the
// line: identity of the thing on screen, never its contents.
//
// # Degradation
//
// Accessibility is a grant a launchd agent may not have, and `AXIsProcessTrusted`
// in a terminal can be TRUE because the terminal holds it, while the same
// code under launchd is FALSE — the grant follows the responsible process,
// which for an agent is itself. So trust is re-checked on every app switch,
// never prompted for, and the app-level spans continue unchanged either way.

/// The window interval currently open inside `current`'s app.
struct WindowFocus {
  let title: String
  let start: Date
  /// Focused-element changes seen while this window was frontmost. A measure
  /// of interaction intensity, NOT of what was interacted with.
  var elementChanges: Int
}

var window: WindowFocus?
var axObserver: AXObserver?
var axElement: AXUIElement?
var axTrusted = false
var axAnnounced: Bool?

func axTitle(of element: AXUIElement) -> String? {
  var value: CFTypeRef?
  guard AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &value) == .success
  else { return nil }
  return value as? String
}

func emitWindow(_ w: WindowFocus, end: Date, app: Focus) {
  let ns = { (d: Date) in String(Int64(d.timeIntervalSince1970 * 1_000_000_000)) }
  let payload: [String: Any] = [
    "resourceSpans": [[
      "resource": ["attributes": [
        attr("service.name", "focus-observer"),
        attr("host.name", Host.current().localizedName ?? "unknown"),
      ]],
      "scopeSpans": [[
        "scope": ["name": "focus-observer"],
        "spans": [[
          "traceId": hex(16),
          "spanId": hex(8),
          "name": "window.focused",
          "kind": 1,
          "startTimeUnixNano": ns(w.start),
          "endTimeUnixNano": ns(end),
          "attributes": [
            attr("app.bundle_id", app.bundleId),
            attr("app.name", app.name),
            attr("window.title", w.title),
            // Interaction intensity. Zero means the window was frontmost and
            // untouched — which is a different fact from a short interval,
            // and the one that separates working from watching.
            attr("window.element_changes", w.elementChanges),
          ],
        ]],
      ]],
    ]],
  ]
  post(payload)
}

/// Close the open window interval, if any.
func closeWindow(at when: Date) {
  guard let w = window, let app = current else { window = nil; return }
  emitWindow(w, end: when, app: app)
  window = nil
}

func windowChanged(to element: AXUIElement?, at when: Date) {
  let title = element.flatMap(axTitle) ?? ""
  // A title-less window is still a window, but an empty title is not worth an
  // interval of its own when the previous one had the same (empty) identity.
  if let w = window, w.title == title { return }
  closeWindow(at: when)
  window = WindowFocus(title: title, start: when, elementChanges: 0)
}

/// C callback: no captured context is possible, so the state above is global.
let axCallback: AXObserverCallback = { _, element, notification, _ in
  let now = Date()
  switch notification as String {
  case kAXFocusedWindowChangedNotification:
    windowChanged(to: element, at: now)
  case kAXFocusedUIElementChangedNotification:
    // Counted, never described. See the refusal note above.
    window?.elementChanges += 1
  default:
    break
  }
}

func detachAX(at when: Date) {
  closeWindow(at: when)
  if let obs = axObserver {
    CFRunLoopRemoveSource(
      CFRunLoopGetCurrent(), AXObserverGetRunLoopSource(obs), .defaultMode
    )
  }
  axObserver = nil
  axElement = nil
}

func attachAX(pid: pid_t, at when: Date) {
  // Re-checked every switch rather than once at startup: the grant can be
  // given while the daemon is running, and a daemon that only ever asked once
  // would stay blind until the next restart with no sign of why.
  axTrusted = AXIsProcessTrusted()

  // ONE prompt, ever, and only when the runner says this binary has not asked
  // before. The dialog is what ADDS a process to the Accessibility list — a
  // program that only ever calls `AXIsProcessTrusted` never appears there, so
  // without this there is no way to grant the permission at all.
  //
  // Guarded from the outside rather than here because the condition is "this
  // build has not asked yet", which is a fact about the filesystem, not about
  // this process. focus-observer.nix clears the marker whenever it rebuilds
  // the binary — which is exactly when the ad-hoc signature changes and the
  // grant needs renewing anyway.
  if !axTrusted, ProcessInfo.processInfo.environment["FOCUS_OBSERVER_PROMPT"] == "1" {
    let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
    axTrusted = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
  }

  if axAnnounced != axTrusted {
    FileHandle.standardError.write(
      (axTrusted
        ? "focus-observer: Accessibility granted; window titles enabled\n"
        : "focus-observer: no Accessibility grant; app spans only. "
          + "Add the binary in System Settings > Privacy & Security > "
          + "Accessibility to get window titles.\n")
        .data(using: .utf8)!
    )
    axAnnounced = axTrusted
  }
  guard axTrusted else { return }

  var obs: AXObserver?
  guard AXObserverCreate(pid, axCallback, &obs) == .success, let obs else { return }
  let appElement = AXUIElementCreateApplication(pid)

  // Both may fail for an app that refuses AX — a sandboxed app, one still
  // launching. A failure here is one app without window detail, not a reason
  // to lose the app-level span.
  AXObserverAddNotification(
    obs, appElement, kAXFocusedWindowChangedNotification as CFString, nil
  )
  AXObserverAddNotification(
    obs, appElement, kAXFocusedUIElementChangedNotification as CFString, nil
  )
  CFRunLoopAddSource(CFRunLoopGetCurrent(), AXObserverGetRunLoopSource(obs), .defaultMode)
  axObserver = obs
  axElement = appElement

  // The window that is already focused. Without this, the first window of
  // every app would go unrecorded until the user switched windows within it.
  var focused: CFTypeRef?
  if AXUIElementCopyAttributeValue(
    appElement, kAXFocusedWindowAttribute as CFString, &focused
  ) == .success, let focused {
    windowChanged(to: (focused as! AXUIElement), at: when)
  }
}

// MARK: - Observers

func switched(to app: NSRunningApplication?, at when: Date) {
  guard let app, let bundleId = app.bundleIdentifier else {
    // No bundle id means nothing joinable — the login window, a process
    // Launch Services has not registered. The same call app-attention.nix
    // makes, for the same reason: an unjoinable row is a hole shaped like a
    // vertex.
    return
  }
  if let open = current {
    // A repeat activation of the same app is not a switch. Electron apps
    // re-activate on window changes within themselves, which would otherwise
    // shred one interval into dozens.
    if open.bundleId == bundleId { return }
    // Window interval first: it belongs to the app that is ending, and
    // closing it after `current` moves on would attribute it to the next app.
    detachAX(at: when)
    emit(open, end: when)
  }
  current = Focus(
    bundleId: bundleId,
    name: app.localizedName ?? bundleId,
    pid: app.processIdentifier,
    start: when,
    partial: false
  )
  attachAX(pid: app.processIdentifier, at: when)
}

let nc = NSWorkspace.shared.notificationCenter

nc.addObserver(
  forName: NSWorkspace.didActivateApplicationNotification,
  object: nil,
  queue: .main
) { note in
  let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
  switched(to: app, at: Date())
}

// An app that quits while focused never generates a deactivation, so without
// this its interval would stay open until the next switch and absorb the gap.
nc.addObserver(
  forName: NSWorkspace.didTerminateApplicationNotification,
  object: nil,
  queue: .main
) { note in
  let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
  guard let open = current, app?.processIdentifier == open.pid else { return }
  let now = Date()
  detachAX(at: now)
  emit(open, end: now)
  current = nil
}

// Whatever is frontmost when the daemon starts, marked partial.
if let front = NSWorkspace.shared.frontmostApplication,
   let bundleId = front.bundleIdentifier
{
  let now = Date()
  current = Focus(
    bundleId: bundleId,
    name: front.localizedName ?? bundleId,
    pid: front.processIdentifier,
    start: now,
    partial: true
  )
  attachAX(pid: front.processIdentifier, at: now)
}

// MARK: - Shutdown

// launchd sends SIGTERM at logout and on `launchctl kickstart -k`. Flushing
// the open interval there is the difference between a clean last span and a
// silently truncated one.
//
// A signal handler cannot safely touch this state, so the handler is disabled
// with `signal()` and the work happens on a dispatch source on the main queue.
signal(SIGTERM, SIG_IGN)
let term = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
term.setEventHandler {
  let now = Date()
  // Window first, for the same reason as in `switched`: it belongs to the app
  // still in `current`.
  detachAX(at: now)
  if let open = current { emit(open, end: now) }
  FileHandle.standardError.write(
    "focus-observer stopping: emitted=\(emitted) dropped=\(dropped) ax=\(axTrusted)\n"
      .data(using: .utf8)!
  )
  // One run-loop turn for the in-flight POST, then go. Not a guarantee — a
  // lost final span at logout is a smaller cost than a daemon that refuses to
  // die.
  DispatchQueue.main.asyncAfter(deadline: .now() + 1) { exit(0) }
}
term.resume()

FileHandle.standardError.write(
  "focus-observer up; posting to \(otlpTraces)\n".data(using: .utf8)!
)
RunLoop.main.run()
