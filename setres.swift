// setres — built-in display resolution switcher
//
// Commands:
//   setres                         switch to the configured target (config file below)
//   setres WxH                     shorthand for `set WxH`
//   setres set [WxH] [--hidpi] [--hz N]   switch built-in display (saves previous mode)
//   setres reset                   return to the mode saved by `set` (or panel default)
//   setres list [WxH]              list modes of the built-in display (optionally filtered)
//   setres status                  current mode, saved mode, EVE state, external count
//   setres watch [WxH] [--hidpi]   daemon: EVE launches + no externals -> WxH; EVE quits -> reset
//   setres help
//
// Low-res (1:1 pixel) modes are the default; --hidpi (or hidpi=true in config) picks
// the HiDPI variant when one exists. Without an explicit hz the current refresh rate
// is preserved.
//
// Config: ~/.config/setres/config, key=value lines, # comments:
//   resolution=1920x1080
//   hidpi=false
//   hz=60          (optional)
//
// Build: swiftc -O setres.swift -o ~/.local/bin/setres

import AppKit
import CoreGraphics
import Foundation

let eveBundleIDs: Set<String> = ["com.ccpgames.eve-online-launcher", "com.ccpgames.eveonline"]
let configDir = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".config/setres")
let stateURL = configDir.appendingPathComponent("saved-mode")
let configURL = configDir.appendingPathComponent("config")
let kDisplayModeDefaultFlag: UInt32 = 0x4

func fail(_ msg: String) -> Never {
    FileHandle.standardError.write(("setres: " + msg + "\n").data(using: .utf8)!)
    exit(1)
}

// MARK: - Config

struct Config {
    var width = 1920
    var height = 1080
    var hidpi = false
    var hz: Double?
}

func parseWxH(_ s: String) -> (Int, Int)? {
    let parts = s.lowercased().split(separator: "x")
    guard parts.count == 2, let w = Int(parts[0]), let h = Int(parts[1]) else { return nil }
    return (w, h)
}

func loadConfig() -> Config {
    var c = Config()
    guard let text = try? String(contentsOf: configURL, encoding: .utf8) else { return c }
    for line in text.split(separator: "\n") {
        let t = line.trimmingCharacters(in: .whitespaces)
        if t.isEmpty || t.hasPrefix("#") { continue }
        let kv = t.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
        guard kv.count == 2 else { continue }
        switch kv[0] {
        case "resolution":
            if let (w, h) = parseWxH(kv[1]) { c.width = w; c.height = h }
        case "hidpi":
            c.hidpi = ["true", "1", "yes"].contains(kv[1].lowercased())
        case "hz":
            c.hz = Double(kv[1])
        default:
            break
        }
    }
    return c
}

// MARK: - Display helpers

// Active (drawable) displays, not merely online — an unplugged display can
// linger in the online list for a while.
func activeDisplays() -> [CGDirectDisplayID] {
    var count: UInt32 = 0
    CGGetActiveDisplayList(0, nil, &count)
    var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
    CGGetActiveDisplayList(count, &ids, &count)
    return Array(ids.prefix(Int(count)))
}

func builtinDisplay() -> CGDirectDisplayID? {
    activeDisplays().first { CGDisplayIsBuiltin($0) != 0 }
}

func externalCount() -> Int {
    activeDisplays().filter { CGDisplayIsBuiltin($0) == 0 }.count
}

// CoreGraphics caches the display list per process, and display-reconfiguration
// events are not delivered to launchd-managed processes on Tahoe — so in the
// long-running watch daemon externalCount() reports the topology from launch
// time. A short-lived child process gets a fresh WindowServer connection and
// therefore the real current list.
func freshExternalCount() -> Int {
    guard let exe = Bundle.main.executableURL else { return externalCount() }
    let p = Process()
    p.executableURL = exe
    p.arguments = ["external-count"]
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = FileHandle.nullDevice
    guard (try? p.run()) != nil else { return externalCount() }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    guard p.terminationStatus == 0,
          let n = Int(String(data: data, encoding: .utf8)?
              .trimmingCharacters(in: .whitespacesAndNewlines) ?? "") else { return externalCount() }
    return n
}

func allModes(_ d: CGDirectDisplayID) -> [CGDisplayMode] {
    let opts = [kCGDisplayShowDuplicateLowResolutionModes as String: true] as CFDictionary
    return (CGDisplayCopyAllDisplayModes(d, opts) as? [CGDisplayMode]) ?? []
}

func modeDesc(_ m: CGDisplayMode) -> String {
    let kind = m.pixelWidth > m.width ? "HiDPI" : "low-res"
    return String(format: "%dx%d %@ %.1fHz (px %dx%d, mode-id %d)",
                  m.width, m.height, kind, m.refreshRate, m.pixelWidth, m.pixelHeight, m.ioDisplayModeID)
}

// No explicit hz -> stick to the display's current refresh rate, so switching
// resolution never silently changes 60Hz into ProMotion 120Hz or vice versa.
func preferredHz(_ d: CGDirectDisplayID, explicit: Double?) -> Double? {
    if let explicit { return explicit }
    guard let cur = CGDisplayCopyDisplayMode(d), cur.refreshRate > 0 else { return nil }
    return cur.refreshRate
}

func pickMode(_ d: CGDirectDisplayID, w: Int, h: Int, hidpi: Bool, hz: Double?) -> CGDisplayMode? {
    let matching = allModes(d).filter { $0.width == w && $0.height == h && $0.isUsableForDesktopGUI() }
    guard !matching.isEmpty else { return nil }
    let hi = matching.filter { $0.pixelWidth > $0.width }
    let lo = matching.filter { $0.pixelWidth == $0.width }
    var cands = hidpi ? (hi.isEmpty ? matching : hi) : (lo.isEmpty ? matching : lo)
    if let hz {
        cands.sort { abs($0.refreshRate - hz) < abs($1.refreshRate - hz) }
    } else {
        cands.sort { $0.refreshRate > $1.refreshRate }
    }
    return cands.first
}

@discardableResult
func apply(_ d: CGDirectDisplayID, _ m: CGDisplayMode) -> Bool {
    var cfg: CGDisplayConfigRef?
    guard CGBeginDisplayConfiguration(&cfg) == .success, let cfg else { return false }
    guard CGConfigureDisplayWithDisplayMode(cfg, d, m, nil) == .success else {
        CGCancelDisplayConfiguration(cfg)
        return false
    }
    return CGCompleteDisplayConfiguration(cfg, .forSession) == .success
}

// MARK: - Saved-mode state

// The saved mode is stored as its signature "W H pxW hz", not its mode-id —
// mode-ids are re-enumerated when the display topology changes.
func saveCurrentModeIfNeeded(_ d: CGDirectDisplayID) {
    guard !FileManager.default.fileExists(atPath: stateURL.path),
          let cur = CGDisplayCopyDisplayMode(d) else { return }
    try? FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
    let sig = "\(cur.width) \(cur.height) \(cur.pixelWidth) \(cur.refreshRate)"
    try? sig.write(to: stateURL, atomically: true, encoding: .utf8)
}

func savedSignature() -> String? {
    guard let s = try? String(contentsOf: stateURL, encoding: .utf8) else { return nil }
    return s.trimmingCharacters(in: .whitespacesAndNewlines)
}

func savedMode(in modes: [CGDisplayMode]) -> CGDisplayMode? {
    guard let parts = savedSignature()?.split(separator: " ").compactMap({ Double($0) }),
          parts.count == 4 else { return nil }
    return modes.first {
        $0.width == Int(parts[0]) && $0.height == Int(parts[1])
            && $0.pixelWidth == Int(parts[2]) && abs($0.refreshRate - parts[3]) < 0.5
    }
}

// Reset to saved mode; falls back to the panel's default-flagged mode at the
// refresh rate closest to the current one. Returns a report line.
func resetSaved(_ d: CGDirectDisplayID) -> String {
    let modes = allModes(d)
    var target = savedMode(in: modes)
    if target == nil {
        let hz = CGDisplayCopyDisplayMode(d)?.refreshRate ?? 60
        target = modes.filter { $0.ioFlags & kDisplayModeDefaultFlag != 0 }
                      .min { abs($0.refreshRate - hz) < abs($1.refreshRate - hz) }
    }
    guard let t = target else { return "reset: no saved or default mode found" }
    if let cur = CGDisplayCopyDisplayMode(d), cur.ioDisplayModeID == t.ioDisplayModeID {
        try? FileManager.default.removeItem(at: stateURL)
        return "already at \(modeDesc(t))"
    }
    if apply(d, t) {
        try? FileManager.default.removeItem(at: stateURL)
        return "reset to \(modeDesc(t))"
    }
    return "reset failed"
}

// MARK: - EVE watcher

func eveRunning() -> Bool {
    NSWorkspace.shared.runningApplications.contains {
        eveBundleIDs.contains($0.bundleIdentifier ?? "")
    }
}

// Edge-triggered, two triggers only:
//   - EVE launches with no externals connected -> set target
//   - all EVE processes quit                   -> reset
// Display plug/unplug is deliberately ignored.
final class Watcher {
    let cfg: Config
    private var evePrev: Bool
    private var pending: DispatchWorkItem?

    init(cfg: Config) {
        self.cfg = cfg
        self.evePrev = eveRunning()
    }

    func log(_ s: String) {
        let ts = ISO8601DateFormatter().string(from: Date())
        print("\(ts) \(s)")
        fflush(stdout)
    }

    func start() {
        log("watch started: target \(cfg.width)x\(cfg.height)\(cfg.hidpi ? " hidpi" : " low-res"), EVE running: \(evePrev)")
        if evePrev {
            log("EVE already running — leaving resolution alone")
        } else if FileManager.default.fileExists(atPath: stateURL.path), let d = builtinDisplay() {
            // Stale state from a previous run (crash/logout mid-game) — clean up.
            log(resetSaved(d))
        }
    }

    // Debounced path, used for quit events: a client restart shouldn't bounce
    // the resolution through a reset and straight back.
    func schedule() {
        pending?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.evaluate() }
        pending = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0, execute: item)
    }

    // eveHint carries knowledge from the notification itself: at willLaunch
    // time the app is not yet in runningApplications, so polling would miss it.
    func evaluate(eveHint: Bool? = nil) {
        pending?.cancel()
        let now = eveHint ?? eveRunning()
        let was = evePrev
        evePrev = now
        guard now != was else { return }
        if now { onEveLaunch() } else { onEveQuit() }
    }

    private func onEveLaunch() {
        let ext = freshExternalCount()
        guard ext == 0 else {
            log("EVE launched, \(ext) external(s) connected — no change")
            return
        }
        guard let d = builtinDisplay() else {
            log("EVE launched, built-in display offline — no change")
            return
        }
        guard let t = pickMode(d, w: cfg.width, h: cfg.height, hidpi: cfg.hidpi,
                               hz: preferredHz(d, explicit: cfg.hz)) else {
            log("target \(cfg.width)x\(cfg.height) not in mode list — override installed and rebooted?")
            return
        }
        if let cur = CGDisplayCopyDisplayMode(d), cur.ioDisplayModeID == t.ioDisplayModeID {
            log("EVE launched, already at \(modeDesc(t))")
            return
        }
        saveCurrentModeIfNeeded(d)
        log(apply(d, t) ? "EVE launched, no externals -> \(modeDesc(t))" : "failed to set \(modeDesc(t))")
    }

    private func onEveQuit() {
        guard FileManager.default.fileExists(atPath: stateURL.path) else {
            log("EVE quit, nothing to reset")
            return
        }
        guard let d = builtinDisplay() else {
            log("EVE quit, built-in display offline — reset skipped")
            return
        }
        log("EVE quit -> \(resetSaved(d))")
    }
}

func runWatch(cfg: Config) -> Never {
    let watcher = Watcher(cfg: cfg)
    watcher.start()

    let nc = NSWorkspace.shared.notificationCenter
    func observe(_ name: Notification.Name, _ handler: @escaping () -> Void) {
        nc.addObserver(forName: name, object: nil, queue: .main) { note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  eveBundleIDs.contains(app.bundleIdentifier ?? "") else { return }
            handler()
        }
    }
    // willLaunch fires at process spawn, seconds before didLaunch (app checkin) —
    // reacting there switches the panel before the first window appears. Launch
    // events evaluate immediately; didLaunch stays as backup in case willLaunch
    // was missed; quits go through the debounce.
    observe(NSWorkspace.willLaunchApplicationNotification) { watcher.evaluate(eveHint: true) }
    observe(NSWorkspace.didLaunchApplicationNotification) { watcher.evaluate(eveHint: true) }
    observe(NSWorkspace.didTerminateApplicationNotification) { watcher.schedule() }

    RunLoop.main.run()
    exit(0)
}

// MARK: - CLI

let usage = """
setres — built-in display resolution switcher
  setres                          switch to configured target (~/.config/setres/config)
  setres WxH                      shorthand for set
  setres set [WxH] [--hidpi] [--hz N]  switch built-in display (saves previous)
  setres reset                    back to saved / panel default mode
  setres list [WxH]               list built-in display modes
  setres status                   current mode + watcher-relevant state
  setres watch [WxH] [--hidpi]    auto: EVE launch + no externals -> target; EVE quit -> reset
Low-res is default; --hidpi (or hidpi=true in config) picks the HiDPI variant.
"""

var config = loadConfig()
var args = Array(CommandLine.arguments.dropFirst())
if args.contains("--hidpi") { config.hidpi = true }
if let i = args.firstIndex(of: "--hz"), i + 1 < args.count {
    config.hz = Double(args[i + 1])
    args.remove(at: i + 1)
}
args.removeAll { $0.hasPrefix("--") }

// Bare "setres" -> set with config target; "setres WxH" -> "setres set WxH"
if args.isEmpty {
    args = ["set"]
} else if parseWxH(args[0]) != nil {
    args.insert("set", at: 0)
}
if args.count > 1, let (w, h) = parseWxH(args[1]) {
    config.width = w
    config.height = h
}

switch args[0] {
case "list":
    guard let d = builtinDisplay() else { fail("no built-in display online") }
    let filter = args.count > 1 ? parseWxH(args[1]) : nil
    let cur = CGDisplayCopyDisplayMode(d)
    for m in allModes(d) {
        if let (w, h) = filter, m.width != w || m.height != h { continue }
        let mark = m.ioDisplayModeID == cur?.ioDisplayModeID ? " <- current" : ""
        print(modeDesc(m) + mark)
    }

case "status":
    guard let d = builtinDisplay() else { fail("no built-in display online") }
    if let cur = CGDisplayCopyDisplayMode(d) { print("built-in: \(modeDesc(cur))") }
    print("saved mode: \(savedSignature() ?? "none")")
    print("externals online: \(externalCount())")
    print("EVE running: \(eveRunning())")
    print("config target: \(config.width)x\(config.height)\(config.hidpi ? " hidpi" : " low-res")"
          + (config.hz.map { String(format: " %.1fHz", $0) } ?? "")
          + (FileManager.default.fileExists(atPath: configURL.path) ? "" : " (built-in defaults, no config file)"))
    guard let t = pickMode(d, w: config.width, h: config.height, hidpi: config.hidpi,
                           hz: preferredHz(d, explicit: config.hz)) else {
        print("target available: false")
        break
    }
    print("target available: \(modeDesc(t))")

case "set":
    guard let d = builtinDisplay() else { fail("no built-in display online") }
    guard let t = pickMode(d, w: config.width, h: config.height, hidpi: config.hidpi,
                           hz: preferredHz(d, explicit: config.hz)) else {
        fail("no \(config.width)x\(config.height) mode on built-in display — run `setres list` (override installed + rebooted?)")
    }
    if let cur = CGDisplayCopyDisplayMode(d), cur.ioDisplayModeID == t.ioDisplayModeID {
        print("already at \(modeDesc(t))")
        exit(0)
    }
    saveCurrentModeIfNeeded(d)
    if apply(d, t) { print("set \(modeDesc(t))") } else { fail("failed to set mode") }

case "reset":
    guard let d = builtinDisplay() else { fail("no built-in display online") }
    print(resetSaved(d))

case "watch":
    runWatch(cfg: config)

// Internal: fresh-process external display count for the watch daemon.
case "external-count":
    print(externalCount())

case "help", "-h":
    print(usage)

default:
    print(usage)
    exit(1)
}
