// CalFeed: serves the calendars macOS already syncs (EventKit) as iCal feeds on this Mac only.
//
//   http://localhost:8765/                       setup page: one feed URL per calendar, with copy buttons
//   http://<label>-<name>.localhost:8765/calendar.ics?id=<calendar id>   one calendar
//   http://localhost:8765/calendar.ics           all calendars
//
// Each calendar gets its own *.localhost host name because Super Productivity labels a calendar tab
// with the first two characters of the host. macOS resolves every *.localhost name to this Mac, so
// no /etc/hosts entries are needed.
//
// Events you declined are left out. Window: 14 days back, 90 days ahead.
// Port: --port <n> (default 8765). Listens on 127.0.0.1 and ::1 only.

import EventKit
import Foundation
import Network

if CommandLine.arguments.contains("--version") {
    // The version is stamped into the app bundle's Info.plist by scripts/build-app.sh.
    print("CalFeed \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev")")
    exit(0)
}

let port: UInt16 = {
    let args = CommandLine.arguments
    if let i = args.firstIndex(of: "--port"), i + 1 < args.count, let p = UInt16(args[i + 1]) { return p }
    return 8765
}()
let daysBack = 14.0
let daysAhead = 90.0

let store = EKEventStore()

func hasAccess() -> Bool { EKEventStore.authorizationStatus(for: .event) == .fullAccess }

// MARK: - Feed labels and host names

struct Feed {
    let calendar: EKCalendar
    let label: String  // two letters, unique
    let host: String   // e.g. "ac-apple-calendar.localhost"
    var url: String { "http://\(host):\(port)/calendar.ics?id=\(calendar.calendarIdentifier)" }
}

func words(_ s: String) -> [String] {
    let replaced = s.replacingOccurrences(of: "ä", with: "ae").replacingOccurrences(of: "ö", with: "oe")
        .replacingOccurrences(of: "ü", with: "ue").replacingOccurrences(of: "Ä", with: "Ae")
        .replacingOccurrences(of: "Ö", with: "Oe").replacingOccurrences(of: "Ü", with: "Ue")
        .replacingOccurrences(of: "ß", with: "ss")
    let ascii = replaced.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .init(identifier: "en_US_POSIX"))
        .lowercased().unicodeScalars.map { ("a"..."z").contains($0) || ("0"..."9").contains($0) ? Character($0) : " " }
    return String(ascii).split(separator: " ").map(String.init)
}

/// "alex@example.com" -> "example", "Calendar@Work" -> "work", "Other" -> "other"
func accountWord(_ source: String) -> String {
    words(String(source.split(separator: "@").last ?? "")).first ?? "x"
}

func labelCandidates(_ ws: [String], duplicateTitle: Bool) -> [String] {
    let first = Array(ws[0])
    var c: [String] = []
    if duplicateTitle, let last = ws.last?.first { c.append("\(first[0])\(last)") }
    if ws.count > 1 {
        c.append("\(first[0])\(ws[1].first!)")
        c.append("\(first[0])\(ws.last!.first!)")
    }
    if first.count > 1 { c.append(String(first[0...1])) }
    for ch in first.dropFirst() + Array(ws.dropFirst().joined()) { c.append("\(first[0])\(ch)") }
    let letters = Array("abcdefghijklmnopqrstuvwxyz")
    for a in letters { for b in letters { c.append("\(a)\(b)") } }
    return c
}

// Labels are saved per calendar ID, so they never shift and can be edited on the setup page.
let labelsFile = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Application Support/CalFeed/labels.json")

func loadLabels() -> [String: String] {
    guard let data = try? Data(contentsOf: labelsFile),
          let map = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
    return map
}

func saveLabels(_ map: [String: String]) {
    try? FileManager.default.createDirectory(at: labelsFile.deletingLastPathComponent(), withIntermediateDirectories: true)
    let enc = JSONEncoder()
    enc.outputFormatting = [.prettyPrinted, .sortedKeys]
    try? enc.encode(map).write(to: labelsFile, options: .atomic)
}

func isValidLabel(_ s: String) -> Bool {
    s.count == 2 && s.unicodeScalars.allSatisfy { ("a"..."z").contains($0) || ("0"..."9").contains($0) }
}

/// Saved labels win; new calendars get a generated label, which is saved right away.
func feeds() -> [Feed] {
    let cals = store.calendars(for: .event).sorted {
        ($0.title.lowercased(), $0.source.title.lowercased(), $0.calendarIdentifier)
            < ($1.title.lowercased(), $1.source.title.lowercased(), $1.calendarIdentifier)
    }
    let titleCounts = Dictionary(cals.map { ($0.title, 1) }, uniquingKeysWith: +)
    var saved = loadLabels()
    var used = Set<String>()
    var labelFor: [String: String] = [:]
    for cal in cals {
        if let l = saved[cal.calendarIdentifier], isValidLabel(l), !used.contains(l) {
            labelFor[cal.calendarIdentifier] = l
            used.insert(l)
        }
    }
    var changed = false
    let result = cals.map { cal in
        let duplicate = titleCounts[cal.title, default: 0] > 1
        var ws = words(cal.title)
        if ws.isEmpty { ws = ["cal"] }
        if duplicate { ws.append(accountWord(cal.source.title)) }
        let label = labelFor[cal.calendarIdentifier]
            ?? labelCandidates(ws, duplicateTitle: duplicate).first { !used.contains($0) }!
        used.insert(label)
        if saved[cal.calendarIdentifier] != label {
            saved[cal.calendarIdentifier] = label
            changed = true
        }
        var name = String(([label] + ws).joined(separator: "-").prefix(60))
        while name.hasSuffix("-") { name.removeLast() }  // host labels must not end with "-"
        return Feed(calendar: cal, label: label, host: "\(name).localhost")
    }
    if changed { saveLabels(saved) }
    return result
}

/// Returns an error message, or nil on success.
func setLabel(id: String, to raw: String) -> String? {
    let label = raw.lowercased()
    guard isValidLabel(label) else { return "Use exactly two letters or digits." }
    let current = feeds()
    guard current.contains(where: { $0.calendar.calendarIdentifier == id }) else { return "Unknown calendar." }
    if let other = current.first(where: { $0.label == label && $0.calendar.calendarIdentifier != id }) {
        return "\(label.uppercased()) is already used by “\(other.calendar.title)”."
    }
    var saved = loadLabels()
    saved[id] = label
    saveLabels(saved)
    return nil
}

// MARK: - iCal rendering

func esc(_ s: String) -> String {
    s.replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: ";", with: "\\;")
        .replacingOccurrences(of: ",", with: "\\,")
        .replacingOccurrences(of: "\r\n", with: "\\n")
        .replacingOccurrences(of: "\n", with: "\\n")
}

/// RFC 5545 line folding: max 75 octets per line, continuation lines start with a space.
func fold(_ line: String) -> String {
    var out = "", current = "", bytes = 0
    for ch in line {
        let n = String(ch).utf8.count
        if bytes + n > 75 {
            out += current + "\r\n "
            current = ""
            bytes = 1
        }
        current.append(ch)
        bytes += n
    }
    return out + current
}

let utc: DateFormatter = {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = TimeZone(identifier: "UTC")
    f.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
    return f
}()

let dayOnly: DateFormatter = {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = .current
    f.dateFormat = "yyyyMMdd"
    return f
}()

func declinedByMe(_ e: EKEvent) -> Bool {
    e.attendees?.contains { $0.isCurrentUser && $0.participantStatus == .declined } ?? false
}

func renderICS(calendars: [EKCalendar], name: String) -> String {
    var lines = [
        "BEGIN:VCALENDAR",
        "VERSION:2.0",
        "PRODID:-//local//CalFeed//EN",
        "CALSCALE:GREGORIAN",
        "X-WR-CALNAME:\(esc(name))",
    ]
    if !calendars.isEmpty {
        let now = Date()
        let pred = store.predicateForEvents(
            withStart: now.addingTimeInterval(-daysBack * 86400),
            end: now.addingTimeInterval(daysAhead * 86400),
            calendars: calendars)
        let stamp = utc.string(from: now)
        for e in store.events(matching: pred) where !declinedByMe(e) {
            // Recurring events come back as separate occurrences; make each UID unique.
            let uid = "\(e.calendarItemExternalIdentifier ?? e.eventIdentifier ?? UUID().uuidString)-\(utc.string(from: e.startDate))"
            lines.append("BEGIN:VEVENT")
            lines.append("UID:\(esc(uid))")
            lines.append("DTSTAMP:\(stamp)")
            if e.isAllDay {
                lines.append("DTSTART;VALUE=DATE:\(dayOnly.string(from: e.startDate))")
                // EventKit's all-day end is the last instant of the last day; iCal wants the exclusive next day.
                let end = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: e.endDate))!
                lines.append("DTEND;VALUE=DATE:\(dayOnly.string(from: end))")
            } else {
                lines.append("DTSTART:\(utc.string(from: e.startDate))")
                lines.append("DTEND:\(utc.string(from: e.endDate))")
            }
            lines.append("SUMMARY:\(esc(e.title ?? "(no title)"))")
            if let loc = e.location, !loc.isEmpty { lines.append("LOCATION:\(esc(loc))") }
            if let url = e.url { lines.append("URL:\(esc(url.absoluteString))") }
            lines.append("CATEGORIES:\(esc(e.calendar.title))")
            if e.availability == .free { lines.append("TRANSP:TRANSPARENT") }
            lines.append("END:VEVENT")
        }
    }
    lines.append("END:VCALENDAR")
    return lines.map(fold).joined(separator: "\r\n") + "\r\n"
}

// MARK: - Setup page

func html(_ s: String) -> String {
    s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
}

func hex(_ cg: CGColor?) -> String {
    guard let c = cg?.converted(to: CGColorSpace(name: CGColorSpace.sRGB)!, intent: .defaultIntent, options: nil)?.components,
          c.count >= 3 else { return "#888888" }
    return String(format: "#%02X%02X%02X", Int(c[0] * 255), Int(c[1] * 255), Int(c[2] * 255))
}

let pageStyle = """
<style>
:root{--bg:#f6f7f9;--card:#fff;--fg:#1d2330;--muted:#6b7280;--line:#e5e7eb;--accent:#2563eb}
@media (prefers-color-scheme:dark){:root{--bg:#16181d;--card:#1f232b;--fg:#e8eaee;--muted:#9aa1ad;--line:#2d323c;--accent:#60a5fa}}
body{margin:0;background:var(--bg);color:var(--fg);font:15px/1.5 -apple-system,BlinkMacSystemFont,sans-serif}
main{max-width:920px;margin:0 auto;padding:32px 16px}
h1{font-size:22px;margin:0 0 4px}p{color:var(--muted);margin:0 0 20px}
ol{color:var(--muted);margin:0 0 24px;padding-left:20px}
.row{display:grid;grid-template-columns:56px 1fr auto;gap:12px;align-items:center;background:var(--card);
  border:1px solid var(--line);border-radius:10px;padding:10px 12px;margin-bottom:8px}
.head{display:grid;grid-template-columns:56px 1fr;gap:12px;padding:0 13px 6px;color:var(--muted);
  font-size:12px;text-transform:uppercase;letter-spacing:.04em}
.lab{display:flex;flex-direction:column;align-items:center;gap:2px;cursor:pointer}
.tag{font:600 13px ui-monospace,Menlo,monospace;text-align:center;border-radius:6px;padding:4px 0;color:#fff;
  width:48px;box-sizing:border-box;border:2px dashed rgba(255,255,255,.7);text-transform:uppercase;outline:none;cursor:text}
.tag:hover{border-style:solid}.tag:focus{border:2px solid var(--fg);background:var(--card)!important;color:var(--fg)}
.hint{font-size:11px;color:var(--muted)}.lab:hover .hint{color:var(--accent)}
.err{color:#dc2626;font-size:13px}
.why{background:var(--card);border:1px solid var(--line);border-left:4px solid var(--accent);border-radius:10px;
  padding:14px 16px;margin:0 0 24px}
.why h2{font-size:15px;margin:0 0 6px}.why p{margin:0 0 10px;color:var(--fg)}.why p.small{color:var(--muted);margin:10px 0 0}
.tabs{display:flex;gap:18px;flex-wrap:wrap;padding:10px 14px;border-radius:8px;background:var(--bg);width:fit-content}
.tab{display:flex;flex-direction:column;align-items:center;font:600 12px -apple-system,sans-serif;color:var(--fg)}
.tab svg{width:22px;height:22px}
@media (max-width:600px){.row{grid-template-columns:56px 1fr}.row button{grid-column:2;justify-self:start}}
.name{font-weight:600}.acct{color:var(--muted);font-weight:400;margin-left:6px}
code{display:block;font:12px ui-monospace,Menlo,monospace;color:var(--muted);overflow-wrap:anywhere}
button{font:inherit;font-size:13px;padding:6px 12px;border-radius:8px;border:1px solid var(--line);
  background:var(--card);color:var(--accent);cursor:pointer}button.ok{color:#16a34a}
</style>
<script>
function copy(b,u){navigator.clipboard.writeText(u).then(()=>{b.textContent='Copied';b.className='ok';
setTimeout(()=>{b.textContent='Copy URL';b.className=''},1500)})}
async function relabel(input,id){
  const err=input.closest('.row').querySelector('.err');
  if(input.value.toLowerCase()===input.defaultValue.toLowerCase())return;
  const r=await fetch('/label?id='+encodeURIComponent(id)+'&label='+encodeURIComponent(input.value),{method:'POST'});
  if(r.ok){location.reload()}else{err.textContent=await r.text();input.value=input.defaultValue}
}
</script>
"""

func setupPage() -> String {
    guard hasAccess() else {
        return """
        <!doctype html><meta charset=utf-8><title>CalFeed</title>\(pageStyle)<main>
        <h1>CalFeed has no calendar access</h1>
        <p>Open <b>System Settings → Privacy &amp; Security → Calendars</b>, turn on <b>CalFeed</b>
        (choose “Full Access”), then reload this page.</p>
        <p><a href="x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars">Open Calendars privacy settings</a></p>
        </main>
        """
    }
    let all = feeds()
    let rows = all.map { f in
        """
        <div class=row><label class=lab title="Click to change the tab label">
          <input class=tag maxlength=2 value="\(f.label.uppercased())"
          style="background:\(hex(f.calendar.cgColor))" onchange="relabel(this,'\(html(f.calendar.calendarIdentifier))')"
          onkeydown="if(event.key==='Enter')this.blur()"><span class=hint>✎ edit</span></label>
        <div><div class=name>\(html(f.calendar.title))<span class=acct>\(html(f.calendar.source.title))</span></div>
        <code>\(html(f.url))</code><div class=err></div></div>
        <button onclick="copy(this,'\(html(f.url))')">Copy URL</button></div>
        """
    }.joined(separator: "\n")
    let calIcon = """
    <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><rect x="4" y="5" width="16" height="15" rx="2"/>\
    <path d="M4 10h16M8 3v4M16 3v4"/></svg>
    """
    let previewTabs = all.prefix(5).map { "<div class=tab>\(calIcon)\($0.label.uppercased())</div>" }.joined()
    return """
    <!doctype html><meta charset=utf-8><meta name=viewport content="width=device-width,initial-scale=1">
    <title>CalFeed</title>\(pageStyle)<main>
    <h1>CalFeed</h1>
    <p>Your Mac's calendars as local iCal feeds. Nothing leaves this Mac.</p>
    <ol>
    <li>In Super Productivity, open the right panel → <b>+</b> → <b>Other (iCal)</b>.</li>
    <li>Paste one URL per calendar you want to see. The tab shows the two-letter label.</li>
    <li>Recommended: tick <b>Reference calendar</b>, untick <b>Auto import events as tasks</b>, leave the notification empty.</li>
    </ol>
    <div class=why>
      <h2>The label is the name of the calendar's tab</h2>
      <p>Super Productivity has no name field for calendars. It shows the first two characters of the URL's host
      under each calendar icon. CalFeed puts the label at the start of every URL, so these labels become your tabs:</p>
      <div class=tabs>\(previewTabs)</div>
      <p class=small><b>To change one:</b> click the label below, type two letters or digits, press Enter.
      The URL changes too, so copy it again and paste it into that calendar's settings in Super Productivity.
      Pick labels that don't clash with your other tabs (for example Jira or GitHub).</p>
    </div>
    <div class=head><span>Tab label</span><span>Calendar and feed URL</span></div>
    \(rows)
    </main>
    """
}

// MARK: - HTTP

func respond(_ conn: NWConnection, status: String, type: String, body: String) {
    let data = Data(body.utf8)
    let head = "HTTP/1.1 \(status)\r\nContent-Type: \(type)\r\nContent-Length: \(data.count)\r\n"
        + "Access-Control-Allow-Origin: *\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n"
    conn.send(content: Data(head.utf8) + data, completion: .contentProcessed { _ in conn.cancel() })
}

func handle(_ conn: NWConnection) {
    conn.start(queue: .main)
    conn.receive(minimumIncompleteLength: 1, maximumLength: 16384) { data, _, _, _ in
        guard let data, let req = String(data: data, encoding: .utf8),
              let target = req.split(separator: " ").dropFirst().first,
              let comps = URLComponents(string: "http://x" + target)
        else { return respond(conn, status: "400 Bad Request", type: "text/plain", body: "bad request\n") }
        let query = { (name: String) in comps.queryItems?.first { $0.name == name }?.value }
        let method = req.split(separator: " ").first.map(String.init) ?? "GET"

        if method == "POST" {
            // Only the setup page itself may change labels, not other websites in the browser.
            let origin = req.split(separator: "\r\n").first { $0.lowercased().hasPrefix("origin:") }
            let allowed = ["localhost", "127.0.0.1", "[::1]"].map { "://\($0):\(port)" }
            if let origin, !allowed.contains(where: { origin.hasSuffix($0) }) {
                return respond(conn, status: "403 Forbidden", type: "text/plain", body: "forbidden\n")
            }
            guard comps.path == "/label", hasAccess(), let id = query("id"), let label = query("label") else {
                return respond(conn, status: "400 Bad Request", type: "text/plain", body: "bad request\n")
            }
            if let error = setLabel(id: id, to: label) {
                return respond(conn, status: "409 Conflict", type: "text/plain; charset=utf-8", body: error)
            }
            return respond(conn, status: "200 OK", type: "text/plain", body: "ok\n")
        }

        switch comps.path {
        case "/":
            respond(conn, status: "200 OK", type: "text/html; charset=utf-8", body: setupPage())
        case "/calendar.ics":
            guard hasAccess() else {
                return respond(conn, status: "503 Service Unavailable", type: "text/plain",
                               body: "CalFeed has no calendar access. Open http://localhost:\(port)/\n")
            }
            store.refreshSourcesIfNecessary()
            var cals = store.calendars(for: .event)
            var name = "All calendars"
            if let id = query("id") {
                cals = cals.filter { $0.calendarIdentifier == id }
                name = cals.first?.title ?? "Unknown calendar"
            } else if let title = query("cal") {  // older URLs
                cals = cals.filter { $0.title == title }
                name = title
            }
            respond(conn, status: "200 OK", type: "text/calendar; charset=utf-8", body: renderICS(calendars: cals, name: name))
        case "/calendars":  // plain-text list for scripts: label, url, title, account
            let list = hasAccess()
                ? feeds().map { "\($0.label.uppercased())\t\($0.url)\t\($0.calendar.title)\t\($0.calendar.source.title)" }.joined(separator: "\n")
                : "no calendar access"
            respond(conn, status: "200 OK", type: "text/plain; charset=utf-8", body: list + "\n")
        default:
            respond(conn, status: "404 Not Found", type: "text/plain", body: "Open http://localhost:\(port)/\n")
        }
    }
}

// MARK: - Main

var listeners: [NWListener] = []
for host in ["127.0.0.1", "::1"] {
    let params = NWParameters.tcp
    params.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!)
    params.allowLocalEndpointReuse = true
    do {
        let listener = try NWListener(using: params)
        listener.newConnectionHandler = handle
        listener.stateUpdateHandler = { state in
            if case .failed(let err) = state {
                FileHandle.standardError.write(Data("listener \(host):\(port) failed: \(err)\n".utf8))
                if host == "127.0.0.1" { exit(1) }  // port taken: let launchd retry, log says why
            }
        }
        listener.start(queue: .main)
        listeners.append(listener)
    } catch {
        FileHandle.standardError.write(Data("cannot listen on \(host):\(port): \(error)\n".utf8))
    }
}
print("CalFeed: open http://localhost:\(port)/")

// Ask once; if denied, the server keeps running and the setup page explains how to fix it.
store.requestFullAccessToEvents { granted, _ in
    print(granted ? "calendar access granted" : "calendar access denied – see http://localhost:\(port)/")
}
dispatchMain()
