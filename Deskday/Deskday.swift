import SwiftUI
import AppKit
import EventKit

import CoreText

enum Retro {
    static func color(_ n: UInt32) -> Color { Color(red: Double((n >> 16) & 255)/255, green: Double((n >> 8) & 255)/255, blue: Double(n & 255)/255) }
    static let bg = color(0x0b0b0c)
    static let panel = color(0x131316)
    static let ink = color(0xe4e4e7)
    static let dim = color(0x99999f)
    static let line = color(0x28282d)
    static let accent = color(0x8de1e3)
    static let fontName: String = {
        if let url = Bundle.main.url(forResource: "FusionPixel", withExtension: "otf") { CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil) }
        return "Fusion-Pixel-12px-Prop-zh_hans-Regular"
    }()
}
func pixel(_ size: CGFloat = 12) -> Font { .custom(Retro.fontName, size: size) }
let mint = Retro.accent
let peach = Retro.color(0xdeb96c)
let lavender = Retro.accent
let surface = Retro.panel
struct Memo: Identifiable { let id: String; let title: String; let text: String }
func quoted(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"").replacingOccurrences(of: "\r", with: "\\r").replacingOccurrences(of: "\n", with: "\\n") + "\"" }
func html(_ s: String) -> String { s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\n", with: "<br>") }
let scriptQueue = DispatchQueue(label: "deskday.notes")
func apple(_ source: String) async throws -> NSAppleEventDescriptor {
    try await withCheckedThrowingContinuation { continuation in
        scriptQueue.async {
            var error: NSDictionary?
            guard let script = NSAppleScript(source: "with timeout of 30 seconds\n" + source + "\nend timeout") else { continuation.resume(throwing: NSError(domain: "Notes", code: 2, userInfo: [NSLocalizedDescriptionKey: "备忘录脚本无法编译。"])); return }
            let result = script.executeAndReturnError(&error)
            if let error = error { continuation.resume(throwing: NSError(domain: "Notes", code: 1, userInfo: [NSLocalizedDescriptionKey: error["NSAppleScriptErrorMessage"] as? String ?? "备忘录连接失败，请检查自动化权限。"])) }
            else { continuation.resume(returning: result) }
        }
    }
}
@MainActor final class DeskStore: ObservableObject {
    let ek = EKEventStore()
    @Published var reminders: [EKReminder] = []
    /// 已完成的提醒事项：与未完成分开存放，按完成时间倒序（最新完成在最前），供待办“已完成”分区查看与恢复。
    @Published var completedReminders: [EKReminder] = []
    @Published var events: [EKEvent] = []
    @Published var memos: [Memo] = []
    @Published var message = "连接 Apple 应用，把工作收在一处。"
    @Published var error: String?
    @Published var busy = false
    @Published var notesBusy = false
    @Published var notesConnected = false
    @Published var notesStale = false
    var refreshPending = false
    /// 浏览周请求的自增令牌，用于丢弃过时结果。
    var browseToken = 0
    @Published var lastSync: Date?
    @Published var pinned: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "pinned") ?? [])
    /// 日程分区“任意日期查看”的浏览锚点与对应整周事件；不影响 events（仍固定为本周，供概览/桌面统计）。
    @Published var browseDate: Date = Date()
    @Published var browseEvents: [EKEvent] = []
    var calendarAllowed: Bool { EKEventStore.authorizationStatus(for: .event) == .fullAccess }
    var reminderAllowed: Bool { EKEventStore.authorizationStatus(for: .reminder) == .fullAccess }
    /// 统一用 Calendar 做日期加减；不用 86400 秒，避免夏令时切换日算错一天。
    func dateAdding(days: Int, to date: Date) -> Date {
        var c = Calendar.current
        c.firstWeekday = 2
        return c.date(byAdding: .day, value: days, to: date) ?? date
    }
    /// 以周一为一周起点，返回包含该日期的整周区间。
    func weekInterval(containing date: Date) -> DateInterval {
        var c = Calendar.current
        c.firstWeekday = 2
        return c.dateInterval(of: .weekOfYear, for: date) ?? DateInterval(start: date, duration: 7 * 86400)
    }
    /// 某一天的起止区间，交给 Calendar 计算以正确跨越夏令时。
    func dayInterval(containing date: Date) -> DateInterval {
        Calendar.current.dateInterval(of: .day, for: date) ?? DateInterval(start: date, duration: 86400)
    }
    var week: DateInterval { weekInterval(containing: Date()) }
    var browseWeek: DateInterval { weekInterval(containing: browseDate) }
    /// 本周最后工作日：周一 + 4 天 = 周五，不处理节假日。仅用于标题展示，不参与任何任务过滤或截止时间。
    static let workdayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
    func lastWorkdayText(of interval: DateInterval) -> String { Self.workdayFormatter.string(from: dateAdding(days: 4, to: interval.start)) }
    var weekLastWorkdayText: String { lastWorkdayText(of: week) }
    /// 本周重点标题：只追加日期标签，不改变重点任务的判定。
    var weekFocusLabel: String { "本周重点 · " + weekLastWorkdayText }
    var browseWeekRangeText: String { Self.workdayFormatter.string(from: browseWeek.start) + " – " + Self.workdayFormatter.string(from: dateAdding(days: 6, to: browseWeek.start)) }
    var important: [EKReminder] { reminders.filter { pinned.contains($0.calendarItemIdentifier) || ($0.priority > 0 && $0.priority <= 4 && ($0.dueDateComponents?.date ?? week.start) < week.end) } }
    var weekTasks: [EKReminder] { reminders.filter { guard let d = $0.dueDateComponents?.date else { return false }; return d >= week.start && d < week.end } }
    init() {
        NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: ek, queue: .main) { [weak self] _ in Task { @MainActor in await self?.refresh() } }
    }
    func connect() async {
        do {
            if !calendarAllowed { _ = try await ek.requestFullAccessToEvents() }
            if !reminderAllowed { _ = try await ek.requestFullAccessToReminders() }
            await refresh()
            if !calendarAllowed || !reminderAllowed { error = "部分访问未授权。可在系统设置 → 隐私与安全性 → 日历 / 提醒事项中为 Deskday 开启完全访问（日历仅添加权限不足以读取日程）。" }
        } catch { self.error = error.localizedDescription }
    }
    func refresh() async {
        guard !busy else { refreshPending = true; return }; busy = true
        defer { busy = false; if refreshPending { refreshPending = false; Task { await refresh() } } }
        if calendarAllowed {
            events = ek.events(matching: ek.predicateForEvents(withStart: week.start, end: week.end, calendars: nil)).sorted { $0.startDate < $1.startDate }
        } else { events = [] }
        await refreshBrowse()
        if reminderAllowed {
            // 未完成与已完成分开拉取，互不覆盖；已完成不限时间范围，按完成时间倒序。
            let pendingPredicate = ek.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: nil)
            let pending: [EKReminder] = await withCheckedContinuation { c in ek.fetchReminders(matching: pendingPredicate) { c.resume(returning: $0 ?? []) } }
            reminders = pending.sorted { ($0.dueDateComponents?.date ?? .distantFuture) < ($1.dueDateComponents?.date ?? .distantFuture) }
            let donePredicate = ek.predicateForCompletedReminders(withCompletionDateStarting: nil, ending: nil, calendars: nil)
            let done: [EKReminder] = await withCheckedContinuation { c in ek.fetchReminders(matching: donePredicate) { c.resume(returning: $0 ?? []) } }
            completedReminders = done.sorted { ($0.completionDate ?? .distantPast) > ($1.completionDate ?? .distantPast) }
        } else { reminders = []; completedReminders = [] }
        if calendarAllowed || reminderAllowed { lastSync = Date(); message = "已同步 · 原生应用修改会自动更新" }
    }
    /// 按当前浏览日期所在周读取事件。用自增令牌丢弃过时结果，快速切换周/日时旧数据不会覆盖新数据。
    func refreshBrowse() async {
        browseToken += 1
        let token = browseToken
        guard calendarAllowed else { browseEvents = []; return }
        let interval = browseWeek
        let fetched = ek.events(matching: ek.predicateForEvents(withStart: interval.start, end: interval.end, calendars: nil)).sorted { $0.startDate < $1.startDate }
        guard token == browseToken else { return }
        browseEvents = fetched
    }
    func pin(_ r: EKReminder) {
        let id = r.calendarItemIdentifier
        if pinned.contains(id) { pinned.remove(id) } else { pinned.insert(id) }
        UserDefaults.standard.set(Array(pinned), forKey: "pinned")
    }
    /// 完成待办：按 Apple 原生逻辑只把 isCompleted 置为 true 并提交。
    /// 不删除提醒、不改动截止时间、不移除 eventFor 映射，也不删除已关联的日程；失败时还原为未完成。
    func complete(_ r: EKReminder) async { await setCompleted(r, true) }
    @Published var updatingReminders: Set<String> = []
    func setCompleted(_ r: EKReminder, _ value: Bool) async {
        let id = r.calendarItemIdentifier
        guard !updatingReminders.contains(id) else { return }
        guard reminderAllowed else { error = "请在系统设置中允许 Deskday 完全访问提醒事项。"; return }
        guard let live = ek.calendarItem(withIdentifier: id) as? EKReminder else { error = "该待办已不存在，请刷新。"; await refresh(); return }
        guard live.calendar?.allowsContentModifications == true else { error = "该提醒事项列表只读。"; return }
        updatingReminders.insert(id)
        defer { updatingReminders.remove(id) }
        let previous = live.isCompleted
        live.isCompleted = value
        do {
            try ek.save(live, commit: true)
            reminders.removeAll { $0.calendarItemIdentifier == id }
            completedReminders.removeAll { $0.calendarItemIdentifier == id }
            if value { completedReminders.insert(live, at: 0) } else { reminders.insert(live, at: 0) }
            await refresh()
        } catch { live.isCompleted = previous; self.error = "保存完成状态失败：" + error.localizedDescription }
    }
    /// 恢复已完成待办：只把 isCompleted 置回 false 并提交；失败时还原为已完成，不做删除、不动截止与关联日程。
    func uncomplete(_ r: EKReminder) async { await setCompleted(r, false) }
    /// 删除待办：按标识重新确认存在与可写；若本应用为它建过关联日程，则一并删除并清理映射。
    /// 缺日历权限时直接阻止并保留一切（不删除、不清映射），避免留下孤立日程。
    func deleteReminder(_ r: EKReminder) async -> Bool {
        guard reminderAllowed else {
            error = "需要提醒事项的完全访问权限才能删除待办。请在侧边栏点“连接日历与提醒”，或在系统设置 → 隐私与安全性 → 提醒事项中为 Deskday 开启完全访问。"
            return false
        }
        let id = r.calendarItemIdentifier
        guard !id.isEmpty, let live = ek.calendarItem(withIdentifier: id) as? EKReminder else {
            error = "找不到要删除的待办（可能已被删除），请刷新后重试。"
            return false
        }
        guard live.calendar?.allowsContentModifications == true else {
            error = "该提醒事项列表只读，无法删除。"
            return false
        }
        let linked = linkedEvent(for: id)
        if UserDefaults.standard.string(forKey: "eventFor." + id) != nil && !calendarAllowed {
            error = "这件待办关联着一条日历日程。请先恢复日历的完全访问权限，才能一并删除关联日程；本次未删除任何内容，关联关系已保留。"
            return false
        }
        do {
            try ek.remove(live, commit: false)
            if let linked = linked { try ek.remove(linked, span: .thisEvent, commit: false) }
            try ek.commit()
        } catch {
            ek.reset(); await refresh(); self.error = error.localizedDescription; return false
        }
        UserDefaults.standard.removeObject(forKey: "eventFor." + id)
        pinned.remove(id)
        UserDefaults.standard.set(Array(pinned), forKey: "pinned")
        await refresh()
        return true
    }
    /// 删除日程：只删当前这一次（span: .thisEvent），并解除本应用所有指向该事件的 eventFor 映射。
    func deleteEvent(_ e: EKEvent) async -> Bool {
        guard calendarAllowed else {
            error = "需要日历的完全访问权限才能删除日程。请在侧边栏点“连接日历与提醒”，或在系统设置 → 隐私与安全性 → 日历中为 Deskday 开启完全访问。"
            return false
        }
        let id = e.calendarItemIdentifier
        let occurrenceRange = ek.predicateForEvents(withStart: e.startDate, end: e.endDate > e.startDate ? e.endDate : e.startDate.addingTimeInterval(1), calendars: [e.calendar])
        let occurrence = ek.events(matching: occurrenceRange).first { $0.calendarItemIdentifier == id && $0.startDate == e.startDate }
        guard !id.isEmpty, let live = occurrence else {
            error = "找不到要删除的日程（可能已被删除），请刷新后重试。"
            return false
        }
        guard live.calendar?.allowsContentModifications == true else {
            error = "该日历只读，无法删除日程。"
            return false
        }
        do { try ek.remove(live, span: .thisEvent, commit: true) }
        catch { ek.reset(); await refresh(); self.error = error.localizedDescription; return false }
        let stale = UserDefaults.standard.dictionaryRepresentation().keys.filter { key in
            key.hasPrefix("eventFor.") && UserDefaults.standard.string(forKey: key) == id
        }
        for key in stale { UserDefaults.standard.removeObject(forKey: key) }
        await refresh()
        return true
    }
    /// 删除备忘：直接用 AppleScript 按 note id 删除，原生备忘录里的这条也会一起消失；不读取其它笔记。
    func deleteMemo(_ memo: Memo) async -> Bool {
        guard notesConnected else { error = "请先连接备忘录。"; return false }
        guard !memo.id.isEmpty else { error = "这条备忘缺少标识，无法删除。"; return false }
        do {
            _ = try await apple("tell application \"Notes\"\ndelete note id " + quoted(memo.id) + "\nend tell")
            await refreshNotes()
            return true
        } catch {
            self.error = "备忘录：" + error.localizedDescription
            return false
        }
    }
    func writable(_ entity: EKEntityType, _ id: String) -> EKCalendar? {
        ek.calendars(for: entity).first { $0.calendarIdentifier == id && $0.allowsContentModifications }
    }
    /// 按“eventFor.<提醒标识>”取回本应用为该待办创建的关联日程；找不到返回 nil。
    func linkedEvent(for reminderID: String) -> EKEvent? {
        guard let eventID = UserDefaults.standard.string(forKey: "eventFor." + reminderID) else { return nil }
        return ek.event(withIdentifier: eventID)
    }
    /// 按 eventID + occurrenceStart 精确定位某一次日程实例：在开始时间前后 2 分钟的窗口内取回重叠事件，
    /// 再要求标识相同且开始时间完全一致，因此重复日程只会命中被点的那一天，绝不会落到别的日期。
    /// occurrenceStart 为空时退回该标识对应的主事件；命中不到返回 nil，由调用方报错，绝不退化成新建。
    func occurrence(eventID: String, start: Date?) -> EKEvent? {
        guard !eventID.isEmpty else { return nil }
        guard let start = start else { return ek.event(withIdentifier: eventID) }
        let window = DateInterval(start: start.addingTimeInterval(-120), end: start.addingTimeInterval(120))
        let matches = ek.events(matching: ek.predicateForEvents(withStart: window.start, end: window.end, calendars: nil))
        return matches.first { $0.calendarItemIdentifier == eventID && abs($0.startDate.timeIntervalSince(start)) < 1 }
    }
    /// 找出与给定截止时间对应的绝对时间闹钟，用于精确清理旧截止而不动无关提醒。
    func deadlineAlarm(_ r: EKReminder, matching date: Date) -> EKAlarm? {
        (r.alarms ?? []).first { alarm in
            guard let absolute = alarm.absoluteDate else { return false }
            return abs(absolute.timeIntervalSince(date)) < 60
        }
    }
    /// 保存到 Apple 应用。reminderID 非空表示编辑既有待办；eventID 非空表示编辑既有日程的某一次实例（配 occurrenceStart 精确定位）。
    /// schedule 为真时，待办会额外写一条日历事件。
    /// 提醒与事件使用 commit:false + 一次 commit() 原子提交，避免只成功一半；失败时 reset 并重新拉取。
    func save(kind: String, title: String, body: String, date: Date, end: Date, hasDate: Bool, focus: Bool, calendarID: String, sourceID: String? = nil, reminderID: String? = nil, schedule: Bool = false, eventCalendarID: String = "", scheduleStart: Date? = nil, scheduleEnd: Date? = nil, eventID: String? = nil, occurrenceStart: Date? = nil) async -> Bool {
        do {
            if kind == "备忘" {
                guard notesConnected else { throw NSError(domain: "Deskday", code: 1, userInfo: [NSLocalizedDescriptionKey: "请先连接备忘录。"] ) }
                let content = "<h1>" + html(title) + "</h1><div>" + html(body) + "</div>"
                _ = try await apple("tell application \"Notes\"\nset a to default account\nset f to default folder of a\nmake new note at f with properties {body:" + quoted(content) + "}\nend tell")
                await refreshNotes(); return true
            }
            if kind == "日程" {
                guard calendarAllowed else { throw NSError(domain: "Deskday", code: 4, userInfo: [NSLocalizedDescriptionKey: "需要日历的完全访问权限才能新建日程。请在侧边栏点“连接日历与提醒”，或在系统设置 → 隐私与安全性 → 日历中为 Deskday 开启完全访问。"] ) }
                guard end > date else { throw NSError(domain: "Deskday", code: 3, userInfo: [NSLocalizedDescriptionKey: "结束时间需要晚于开始时间，请调整后再保存。"] ) }
                guard let calendar = writable(.event, calendarID) else { throw NSError(domain: "Deskday", code: 2, userInfo: [NSLocalizedDescriptionKey: "请选择可写入的日历。"] ) }
                let e: EKEvent
                if let eventID = eventID {
                    // 编辑：必须按 eventID + occurrenceStart 精确命中这一次实例；查不到直接报错，绝不退化成新建。
                    guard let live = occurrence(eventID: eventID, start: occurrenceStart) else {
                        throw NSError(domain: "Deskday", code: 10, userInfo: [NSLocalizedDescriptionKey: "找不到要编辑的日程（可能已被删除，或这是重复日程的另一天），请关闭后刷新重试；不会新建一条。"] )
                    }
                    guard live.calendar?.allowsContentModifications == true else {
                        throw NSError(domain: "Deskday", code: 11, userInfo: [NSLocalizedDescriptionKey: "这条日程所在的日历只读，无法编辑。"] )
                    }
                    // 复用原事件：只改被编辑的字段，保留 alarms / location / 重复规则等未编辑内容。
                    e = live
                } else if let sourceID = sourceID, let linked = linkedEvent(for: sourceID) {
                    // 由待办关联复用的既有事件同样视为编辑，不重复添加提醒。
                    e = linked
                } else {
                    let created = EKEvent(eventStore: ek)
                    created.addAlarm(EKAlarm(relativeOffset: -900))  // 仅新建日程添加提前 15 分钟提醒
                    e = created
                }
                e.title = title; e.notes = body; e.calendar = calendar; e.startDate = date; e.endDate = end
                do { try ek.save(e, span: .thisEvent, commit: false); try ek.commit() }
                catch { ek.reset(); await refresh(); throw error }
                if let oldID = eventID, oldID != e.calendarItemIdentifier, !e.hasRecurrenceRules {
                    for key in UserDefaults.standard.dictionaryRepresentation().keys where key.hasPrefix("eventFor.") && UserDefaults.standard.string(forKey: key) == oldID {
                        UserDefaults.standard.set(e.calendarItemIdentifier, forKey: key)
                    }
                }
                if let sourceID = sourceID { UserDefaults.standard.set(e.calendarItemIdentifier, forKey: "eventFor." + sourceID) }
                await refresh(); return true
            }
            // 待办：新建或编辑既有提醒。先完成全部校验，再改动内存对象，最后一次性提交。
            guard reminderAllowed else { throw NSError(domain: "Deskday", code: 4, userInfo: [NSLocalizedDescriptionKey: "需要提醒事项的完全访问权限才能保存待办。请在侧边栏点“连接日历与提醒”，或在系统设置 → 隐私与安全性 → 提醒事项中为 Deskday 开启完全访问。"] ) }
            guard let list = writable(.reminder, calendarID) else { throw NSError(domain: "Deskday", code: 2, userInfo: [NSLocalizedDescriptionKey: "请选择可写入的提醒事项列表。"] ) }
            var scheduleCalendar: EKCalendar?
            var scheduleRange: (start: Date, finish: Date)?
            if schedule {
                guard calendarAllowed else { throw NSError(domain: "Deskday", code: 5, userInfo: [NSLocalizedDescriptionKey: "尚未获得日历的完全访问权限，无法安排到日历。请先连接日历，或在系统设置 → 隐私与安全性 → 日历中为 Deskday 开启完全访问。"] ) }
                guard let start = scheduleStart, let finish = scheduleEnd else { throw NSError(domain: "Deskday", code: 6, userInfo: [NSLocalizedDescriptionKey: "请设置日程的开始与结束时间。"] ) }
                guard finish > start else { throw NSError(domain: "Deskday", code: 3, userInfo: [NSLocalizedDescriptionKey: "日程结束时间需要晚于开始时间，请调整后再保存。"] ) }
                guard let eventCalendar = writable(.event, eventCalendarID) else { throw NSError(domain: "Deskday", code: 7, userInfo: [NSLocalizedDescriptionKey: "请选择可写入的日历。"] ) }
                scheduleCalendar = eventCalendar
                scheduleRange = (start, finish)
            }
            // 编辑：必须按标识查到真实提醒，查不到直接报错，绝不退化成新建。
            var existing: EKReminder?
            if let reminderID = reminderID {
                guard let found = ek.calendarItem(withIdentifier: reminderID) as? EKReminder else {
                    throw NSError(domain: "Deskday", code: 8, userInfo: [NSLocalizedDescriptionKey: "找不到要编辑的待办（可能已被删除），请关闭后刷新重试；不会新建一条。"] )
                }
                existing = found
            }
            if let reminderID = reminderID,
               UserDefaults.standard.string(forKey: "eventFor." + reminderID) != nil,
               !calendarAllowed {
                throw NSError(domain: "Deskday", code: 9, userInfo: [NSLocalizedDescriptionKey: "该待办有关联日程。请先恢复日历完全访问权限再保存，以便更新或移除原日程；关联关系已保留。"])
            }
            let r = existing ?? EKReminder(eventStore: ek)
            r.title = title; r.notes = body; r.calendar = list
            if existing == nil { r.priority = 0 }  // 编辑时保留原优先级，不覆盖其它信息
            // 截止时间：清空或改写；只清理与旧截止匹配的闹钟，不动无关闹钟，避免重复。
            let oldDue = r.dueDateComponents?.date
            if hasDate {
                if let oldDue = oldDue, let stale = deadlineAlarm(r, matching: oldDue) { r.removeAlarm(stale) }
                var dc = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: date); dc.timeZone = .current
                r.dueDateComponents = dc; r.addAlarm(EKAlarm(absoluteDate: date))
            } else {
                if let oldDue = oldDue, let stale = deadlineAlarm(r, matching: oldDue) { r.removeAlarm(stale) }
                r.dueDateComponents = nil
            }
            // 日程同步：开启时优先复用已关联事件并更新；关闭时只删除本应用映射的那一条。
            var event: EKEvent?
            var eventToRemove: EKEvent?
            if let scheduleCalendar = scheduleCalendar, let range = scheduleRange {
                let linked = reminderID.flatMap { linkedEvent(for: $0) }
                let e = linked ?? EKEvent(eventStore: ek)
                if linked == nil { e.addAlarm(EKAlarm(relativeOffset: -900)) }  // 仅新建关联日程添加提前 15 分钟提醒
                e.title = title; e.notes = body; e.calendar = scheduleCalendar; e.startDate = range.start; e.endDate = range.finish
                event = e
            } else if let reminderID = reminderID {
                eventToRemove = linkedEvent(for: reminderID)
            }
            do {
                try ek.save(r, commit: false)
                if let event = event { try ek.save(event, span: .thisEvent, commit: false) }
                if let eventToRemove = eventToRemove { try ek.remove(eventToRemove, span: .thisEvent, commit: false) }
                try ek.commit()
            } catch {
                ek.reset()
                await refresh()
                throw error
            }
            let linkKey = "eventFor." + r.calendarItemIdentifier
            if let event = event { UserDefaults.standard.set(event.calendarItemIdentifier, forKey: linkKey) }
            else { UserDefaults.standard.removeObject(forKey: linkKey) }  // 关闭同步时清掉映射，避免残留
            if focus { pinned.insert(r.calendarItemIdentifier) } else { pinned.remove(r.calendarItemIdentifier) }
            UserDefaults.standard.set(Array(pinned), forKey: "pinned")
            await refresh(); return true
        } catch { self.error = error.localizedDescription; return false }
    }
    func refreshNotes() async {
        guard !notesBusy else { return }; notesBusy = true; defer { notesBusy = false }
        do {
            let result = try await apple("""
            tell application "Notes"
                set output to {}
                set cutoff to (current date) - (30 * days)
                set recentNotes to every note whose modification date > cutoff
                set n to 0
                repeat with itemNote in recentNotes
                    if not password protected of itemNote then
                        set end of output to {id of itemNote, name of itemNote, plaintext of itemNote}
                        set n to n + 1
                        if n ≥ 40 then exit repeat
                    end if
                end repeat
                return output
            end tell
            """)
            var rows: [Memo] = []
            if result.numberOfItems > 0 { for i in 1...result.numberOfItems { if let row = result.atIndex(i) { rows.append(Memo(id: row.atIndex(1)?.stringValue ?? "", title: row.atIndex(2)?.stringValue ?? "未命名", text: row.atIndex(3)?.stringValue ?? "")) } } }
            memos = rows; notesConnected = true; notesStale = false
        } catch { notesStale = true; self.error = "备忘录：" + error.localizedDescription }
    }
    func openMemo(_ memo: Memo) async {
        do { _ = try await apple("tell application \"Notes\"\nshow note id " + quoted(memo.id) + "\nactivate\nend tell") } catch { self.error = error.localizedDescription }
    }
}
struct Compose: Identifiable {
    let id = UUID()
    var kind = "待办"
    var title = ""
    var body = ""
    var sourceID: String?
    var reminderID: String?
    var focus = false
    /// 编辑既有日程时携带的事件标识；配 occurrenceStart 精确定位到具体某一次实例（重复日程不会改到别的日期）。
    var eventID: String?
    var occurrenceStart: Date?
}
struct EditorNote { let text: String; let warning: Bool }
/// 待确认的删除请求。UI 只负责构造请求并弹确认框，用户确认后才真正调用 DeskStore 的删除方法。
struct DeletionRequest: Identifiable {
    enum Target {
        case reminder(EKReminder)
        case event(EKEvent)
        case memo(Memo)
    }
    let id = UUID()
    let target: Target
    let title: String
    let message: String
}
// MARK: - 复古像素 UI 基础件（仅 UI 层，不改动数据层）

struct RetroPanelModifier: ViewModifier {
    var emphasis = false
    func body(content: Content) -> some View {
        content
            .background(Retro.panel)
            .overlay(Rectangle().stroke(emphasis ? Retro.accent.opacity(0.45) : Retro.line, lineWidth: 1))
    }
}

extension View {
    func panel(_ emphasis: Bool = false) -> some View { modifier(RetroPanelModifier(emphasis: emphasis)) }
    func inputBox() -> some View {
        self.padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(Retro.bg)
            .overlay(Rectangle().stroke(Retro.line, lineWidth: 1))
    }
}

struct RetroButtonStyle: ButtonStyle {
    var prominent = false
    var tint: Color? = nil
    func makeBody(configuration: Configuration) -> some View {
        RetroButtonBody(configuration: configuration, prominent: prominent, tint: tint)
    }
}

struct RetroButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let prominent: Bool
    let tint: Color?
    @Environment(\.isEnabled) private var enabled
    @State private var hover = false
    var body: some View {
        let accent = tint ?? Retro.accent
        configuration.label
            .font(pixel(12))
            .foregroundStyle(labelColor(accent))
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(fillColor(accent))
            .overlay(Rectangle().stroke(borderColor(accent), lineWidth: 1))
            .opacity(enabled ? (configuration.isPressed ? 0.7 : 1) : 0.45)
            .contentShape(Rectangle())
            .onHover { hover = enabled && $0 }
    }
    private func labelColor(_ accent: Color) -> Color {
        if !enabled { return Retro.dim }
        if prominent { return Retro.bg }
        return hover ? accent : Retro.ink
    }
    private func fillColor(_ accent: Color) -> Color {
        if !enabled { return Retro.panel }
        if prominent { return hover ? accent.opacity(0.85) : accent }
        return hover ? accent.opacity(0.14) : Retro.panel
    }
    private func borderColor(_ accent: Color) -> Color {
        if !enabled { return Retro.line }
        return prominent ? accent : (hover ? accent : Retro.line)
    }
}

struct RetroNavRow: View {
    let title: String
    var symbol: String? = nil
    var badge: Int? = nil
    let active: Bool
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let symbol = symbol {
                    Image(systemName: symbol)
                        .font(.system(size: 11))
                        .frame(width: 12, alignment: .leading)
                        .foregroundStyle(active ? Retro.accent : Retro.dim)
                } else {
                    Text("/").font(pixel(12)).foregroundStyle(active ? Retro.accent : Retro.dim)
                }
                Text(title).font(pixel(12)).foregroundStyle(active ? Retro.ink : (hover ? Retro.ink : Retro.dim))
                Spacer(minLength: 4)
                if let badge = badge, badge > 0 {
                    Text("\(badge)").font(pixel(12)).foregroundStyle(active ? Retro.accent : Retro.dim)
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .background(active ? Retro.accent.opacity(0.10) : (hover ? Color.white.opacity(0.05) : Color.clear))
            .overlay(alignment: .leading) { Rectangle().fill(active ? Retro.accent : Color.clear).frame(width: 2) }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

struct RetroTabs: View {
    let items: [String]
    @Binding var selection: String
    var body: some View {
        HStack(spacing: 0) {
            ForEach(items, id: \.self) { item in
                RetroTabItem(title: item, active: selection == item) { selection = item }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 24)
    }
}

struct RetroTabItem: View {
    let title: String
    let active: Bool
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            VStack(spacing: 0) {
                Text(title)
                    .font(pixel(12))
                    .foregroundStyle(active ? Retro.accent : (hover ? Retro.ink : Retro.dim))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                Rectangle().fill(active ? Retro.accent : Retro.line).frame(height: active ? 2 : 1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

struct RetroPixelBox: View {
    var cell: CGFloat = 5
    var color: Color = Retro.dim
    var body: some View {
        VStack(spacing: 1) {
            row([true, true, true])
            row([true, false, true])
            row([true, true, true])
        }
    }
    private func row(_ flags: [Bool]) -> some View {
        HStack(spacing: 1) {
            ForEach(0..<3, id: \.self) { index in
                Rectangle().fill(flags[index] ? color : Color.clear).frame(width: cell, height: cell)
            }
        }
    }
}

struct RetroEmpty: View {
    let title: String
    let detail: String
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            RetroPixelBox()
            Text(title).font(pixel(13)).foregroundStyle(Retro.ink)
            Text(detail).font(pixel(12)).foregroundStyle(Retro.dim).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 18)
    }
}

struct Editor: View {
    @EnvironmentObject var store: DeskStore
    @Environment(\.dismiss) var dismiss
    let input: Compose
    @State var title = ""
    @State var bodyText = ""
    @State var date = Date().addingTimeInterval(3600)
    @State var end = Date().addingTimeInterval(7200)
    @State var dated = false
    @State var focus = false
    @State var calendarID = ""
    @State var scheduleEnabled = false
    @State var eventCalendarID = ""
    @State var scheduleStart = Date().addingTimeInterval(3600)
    @State var eventDuration: TimeInterval = 3600
    @State var hadLinkedEvent = false
    @State var saving = false
    /// 编辑日程时预填的原始开始时间；用于识别“预填回显”，避免联动逻辑改写原结束时间。
    @State var prefilledStart: Date?
    /// 编辑日程时若原日历只读，仍列出该日历以便正确显示，保存时再明确报错。
    @State var readOnlyEventCalendar: EKCalendar?
    var calendars: [EKCalendar] {
        let list = store.ek.calendars(for: input.kind == "日程" ? .event : .reminder).filter(\.allowsContentModifications)
        if let extra = readOnlyEventCalendar, !list.contains(where: { $0.calendarIdentifier == extra.calendarIdentifier }) { return list + [extra] }
        return list
    }
    var eventCalendars: [EKCalendar] { store.ek.calendars(for: .event).filter(\.allowsContentModifications) }
    var destination: String { input.kind == "待办" ? "提醒事项" : input.kind == "日程" ? "日历" : "备忘录" }
    var schedulesToCalendar: Bool { input.kind == "待办" && scheduleEnabled }
    var isEditingTodo: Bool { input.reminderID != nil }
    var isEditingEvent: Bool { input.eventID != nil }
    var isEditing: Bool { isEditingTodo || isEditingEvent }
    var headerTitle: String { isEditingEvent ? "编辑日程" : isEditingTodo ? "编辑待办" : input.sourceID == nil ? "新建" + input.kind : "为这件事安排时间" }
    /// 有截止时间时日程结束跟随截止时间；否则沿用原关联事件时长（新建默认 1 小时），不悄悄改动待办截止。
    var effectiveScheduleEnd: Date { dated ? date : scheduleStart.addingTimeInterval(eventDuration) }
    var durationText: String {
        let seconds = max(eventDuration, 60)
        return seconds.truncatingRemainder(dividingBy: 3600) == 0 ? "\(Int(seconds / 3600)) 小时" : "\(Int(seconds / 60)) 分钟"
    }
    var timeError: String? {
        if input.kind == "日程" { return end <= date ? "结束时间需要晚于开始时间，无法保存。" : nil }
        if schedulesToCalendar { return effectiveScheduleEnd <= scheduleStart ? "日程开始必须早于待办截止时间，请调整开始时间或取消截止时间。" : nil }
        return nil
    }
    var blockReason: EditorNote? {
        if title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return EditorNote(text: "请填写名称", warning: false) }
        if input.kind != "备忘" && calendarID.isEmpty { return EditorNote(text: "请选择保存位置", warning: false) }
        if isEditingEvent, readOnlyEventCalendar != nil { return EditorNote(text: "这条日程所在的日历只读，无法编辑", warning: true) }
        if let timeError = timeError { return EditorNote(text: timeError, warning: true) }
        if schedulesToCalendar {
            if !store.calendarAllowed { return EditorNote(text: "尚未连接日历，无法安排到日历", warning: true) }
            if eventCalendarID.isEmpty { return EditorNote(text: "请选择要写入的日历", warning: false) }
        }
        return nil
    }
    var canSave: Bool { !saving && blockReason == nil }

    var body: some View {
        VStack(spacing: 0) {
            editorHeader
            Rectangle().fill(Retro.line).frame(height: 1)
            ScrollView { editorForm }
            Rectangle().fill(Retro.line).frame(height: 1)
            editorFooter
        }
        .frame(width: 520)
        .frame(maxHeight: 640)
        .background(Retro.panel)
        .preferredColorScheme(.dark)
        .onAppear {
            title = input.title; bodyText = input.body; focus = input.focus
            calendarID = calendars.first?.calendarIdentifier ?? ""
            eventCalendarID = eventCalendars.first?.calendarIdentifier ?? ""
            scheduleStart = date
            if let eventID = input.eventID { preloadEvent(eventID) }
            else if let reminderID = input.reminderID { preload(reminderID) }
        }
        .onChange(of: date) { oldValue, newValue in
            guard input.kind == "日程" else { return }
            // 编辑日程时预填回显不算用户改动：不联动改写原结束时间。
            if let prefilled = prefilledStart, prefilled == newValue { prefilledStart = nil; return }
            let span = end.timeIntervalSince(oldValue)
            end = newValue.addingTimeInterval(span > 0 ? span : 3600)
        }
        .onChange(of: scheduleEnabled) { _, enabled in
            // 仅在用户新开同步、且没有已关联日程时才默认“截止前 1 小时”，避免覆盖预填的原日程开始时间。
            if enabled && dated && !hadLinkedEvent { scheduleStart = date.addingTimeInterval(-3600) }
        }
        .onChange(of: store.calendarAllowed) { _, allowed in
            if allowed && eventCalendarID.isEmpty { eventCalendarID = eventCalendars.first?.calendarIdentifier ?? "" }
        }
        .alert("需要留意", isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.error = nil } })) { Button("知道了") { store.error = nil } } message: { Text(store.error ?? "") }
    }

    /// 编辑时按标识取回真实提醒及它关联的日程，用真实值预填表单；只读不写，不改动提醒本身。
    func preload(_ reminderID: String) {
        guard let r = store.ek.calendarItem(withIdentifier: reminderID) as? EKReminder else { return }
        title = r.title ?? title
        bodyText = r.notes ?? bodyText
        focus = store.pinned.contains(reminderID)
        if let cid = r.calendar?.calendarIdentifier, calendars.contains(where: { $0.calendarIdentifier == cid }) { calendarID = cid }
        if let due = r.dueDateComponents?.date { dated = true; date = due } else { dated = false }
        if let linked = store.linkedEvent(for: reminderID), let eventCalendar = linked.calendar {
            hadLinkedEvent = true
            scheduleEnabled = true
            scheduleStart = linked.startDate
            eventDuration = max(linked.endDate.timeIntervalSince(linked.startDate), 60)
            if eventCalendars.contains(where: { $0.calendarIdentifier == eventCalendar.calendarIdentifier }) { eventCalendarID = eventCalendar.calendarIdentifier }
        }
    }

    /// 编辑日程：按 eventID + occurrenceStart 精确定位被点的那一次实例，用真实值预填名称 / 说明 / 日历 / 开始 / 结束。
    /// 重复日程只命中 occurrenceStart 当天那一次，不会落到别的日期；只读不写，不改动事件本身。
    func preloadEvent(_ eventID: String) {
        guard let found = store.occurrence(eventID: eventID, start: input.occurrenceStart) else { return }
        title = found.title ?? title
        bodyText = found.notes ?? bodyText
        prefilledStart = found.startDate
        date = found.startDate
        end = found.endDate
        if let calendar = found.calendar {
            calendarID = calendar.calendarIdentifier
            if !calendar.allowsContentModifications { readOnlyEventCalendar = calendar }
        }
    }

    var editorHeader: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(headerTitle).font(pixel(18)).foregroundStyle(Retro.ink)
                Text(editorSubtitle).font(pixel(12)).foregroundStyle(Retro.dim)
            }
            Spacer(minLength: 8)
            Text("/ " + input.kind).font(pixel(12)).foregroundStyle(Retro.accent)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }

    var editorSubtitle: String {
        if isEditingEvent { return "修改 Apple 日历中的这一次日程" }
        if isEditingTodo { return schedulesToCalendar ? "修改 Apple 提醒事项，并同步日历日程" : "修改 Apple 提醒事项" }
        return "写入 Apple " + destination
    }

    var editorForm: some View {
        VStack(alignment: .leading, spacing: 14) {
            fieldLabel("名称")
            TextField("给它一个清楚的名字", text: $title)
                .textFieldStyle(.plain)
                .font(pixel(12))
                .foregroundStyle(Retro.ink)
                .inputBox()
            fieldLabel("说明")
            TextEditor(text: $bodyText)
                .font(pixel(12))
                .foregroundStyle(Retro.ink)
                .scrollContentBackground(.hidden)
                .padding(6)
                .frame(height: 104)
                .background(Retro.bg)
                .overlay(Rectangle().stroke(Retro.line, lineWidth: 1))
                .accessibilityLabel("补充说明")
            if input.kind == "备忘" {
                hint("保存到 Apple 备忘录的默认账户 / 默认文件夹。")
            } else {
                editorOptions
            }
        }
        .padding(20)
    }

    @ViewBuilder var editorOptions: some View {
        fieldLabel(input.kind == "日程" ? "保存到日历" : "保存到列表")
        Picker("", selection: $calendarID) {
            Text("请选择").tag("")
            ForEach(calendars, id: \.calendarIdentifier) { item in Text(item.title).tag(item.calendarIdentifier) }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .font(pixel(12))
        .tint(Retro.accent)
        if input.kind == "待办" {
            Toggle("加入本周重点（仅置顶，不建日历事件）", isOn: $focus).toggleStyle(.switch).tint(Retro.accent).font(pixel(12))
            Toggle("设置截止时间（结束时间，可不填）", isOn: $dated).toggleStyle(.switch).tint(Retro.accent).font(pixel(12))
        }
        if input.kind == "日程" || dated { dateRows }
        if input.kind == "待办" {
            Toggle("同步到日程安排（默认关闭）", isOn: $scheduleEnabled).toggleStyle(.switch).tint(Retro.accent).font(pixel(12))
            if scheduleEnabled { scheduleOptions }
            else if hadLinkedEvent { hint("关闭同步并保存后，会移除该待办已关联的日历日程；提醒事项中的待办仍会保留。") }
        }
        hint(input.kind == "日程" ? (isEditingEvent ? "只修改当前这一次日程；原有的提醒、地点、重复规则等未编辑内容会保留。" : "保存到 Apple 日历，提前 15 分钟提醒。通知请在系统设置中开启。") : "保存到 Apple 提醒事项，可以没有截止时间。需要占用一段时间时，再单独安排到日历。")
    }

    @ViewBuilder var scheduleOptions: some View {
        if store.calendarAllowed {
            fieldLabel("保存到日历")
            Picker("", selection: $eventCalendarID) {
                Text("请选择").tag("")
                ForEach(eventCalendars, id: \.calendarIdentifier) { item in Text(item.title).tag(item.calendarIdentifier) }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .font(pixel(12))
            .tint(Retro.accent)
        } else {
            HStack(spacing: 8) {
                Text("尚未获得日历完全访问权限。").font(pixel(12)).foregroundStyle(peach)
                Button("连接日历") { Task { await store.connect() } }.buttonStyle(RetroButtonStyle())
                Spacer(minLength: 0)
            }
        }
        HStack(spacing: 12) {
            fieldLabel("日程开始").frame(width: 76, alignment: .leading)
            DatePicker("", selection: $scheduleStart).labelsHidden().datePickerStyle(.compact)
            Spacer(minLength: 0)
        }
        Text(dated ? "日程结束：" + date.formatted(date: .abbreviated, time: .shortened) + "（同待办截止时间）" : "未设截止时间：日历按 " + durationText + " 安排，待办仍无截止时间。")
            .font(pixel(12)).foregroundStyle(Retro.dim).fixedSize(horizontal: false, vertical: true)
        if let timeError = timeError { Text(timeError).font(pixel(12)).foregroundStyle(peach).fixedSize(horizontal: false, vertical: true) }
        hint(store.calendarAllowed ? "只有开启同步才创建日程；截止时间同时作为日程结束时间。日程提前 15 分钟提醒。" : "在系统设置 → 隐私与安全性 → 日历中为 Deskday 开启完全访问；仅“添加”权限不足以写入日程。")
    }

    var dateRows: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                fieldLabel(input.kind == "日程" ? "开始时间" : "截止时间").frame(width: 76, alignment: .leading)
                DatePicker("", selection: $date).labelsHidden().datePickerStyle(.compact)
                Spacer(minLength: 0)
            }
            if input.kind == "日程" {
                HStack(spacing: 12) {
                    fieldLabel("结束时间").frame(width: 76, alignment: .leading)
                    DatePicker("", selection: $end).labelsHidden().datePickerStyle(.compact)
                    Spacer(minLength: 0)
                }
                if let timeError = timeError { Text(timeError).font(pixel(12)).foregroundStyle(peach).fixedSize(horizontal: false, vertical: true) }
                hint(isEditingEvent ? "修改开始时间会保留原时长，自动顺延结束时间；预填的原结束时间不会被改动。" : "修改开始时间会保留原时长，自动顺延结束时间。")
            } else {
                hint("到期时间会写入提醒事项，并在同一时刻设置提醒。")
            }
        }
    }

    var editorFooter: some View {
        HStack(spacing: 10) {
            if !saving, let note = blockReason {
                Text(note.text).font(pixel(12)).foregroundStyle(note.warning ? peach : Retro.dim).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button("取消") { dismiss() }.buttonStyle(RetroButtonStyle()).keyboardShortcut(.cancelAction)
            Button(saving ? "正在保存…" : (isEditing ? "保存修改" : "保存到 Apple " + destination)) { save() }
                .buttonStyle(RetroButtonStyle(prominent: true))
                .disabled(!canSave)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    func fieldLabel(_ text: String) -> some View { Text(text).font(pixel(12)).tracking(1).foregroundStyle(Retro.dim) }
    func hint(_ text: String) -> some View { Text(text).font(pixel(12)).foregroundStyle(Retro.dim).fixedSize(horizontal: false, vertical: true) }

    func save() {
        // 先让日期/文本输入框提交编辑中的值，再等一帧让绑定刷新，最后用最新状态校验与读取。
        NSApp.keyWindow?.makeFirstResponder(nil)
        saving = true
        Task { @MainActor in
            await Task.yield()
            guard blockReason == nil else { saving = false; return }
            let start = scheduleStart
            let finish = effectiveScheduleEnd
            let ok = await store.save(kind: input.kind, title: title.trimmingCharacters(in: .whitespacesAndNewlines), body: bodyText, date: date, end: end, hasDate: dated, focus: focus, calendarID: calendarID, sourceID: input.sourceID, reminderID: input.reminderID, schedule: schedulesToCalendar, eventCalendarID: eventCalendarID, scheduleStart: start, scheduleEnd: finish, eventID: input.eventID, occurrenceStart: input.occurrenceStart)
            if ok { dismiss() }
            saving = false
        }
    }
}
struct CodexLaunchButtons: View {
    @State private var launchError: String?
    private let personal = "/Users/zz/Desktop/Codex 切到个人订阅.command"
    private let company = "/Users/zz/Desktop/Codex 切到公司中转.command"
    var body: some View {
        HStack(spacing: 8) {
            Button("Codex-切个人订阅") { launch(personal) }
            Button("Codex-切公司中转") { launch(company) }
        }
        .buttonStyle(RetroButtonStyle())
        .help("打开桌面上的对应命令程序；执行结果请查看终端")
        .alert("无法打开切换程序", isPresented: Binding(get: { launchError != nil }, set: { if !$0 { launchError = nil } })) {
            Button("知道了") { launchError = nil }
        } message: { Text(launchError ?? "") }
    }
    private func launch(_ path: String) {
        guard FileManager.default.fileExists(atPath: path) else {
            launchError = "找不到文件：\(path)"; return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.open(URL(fileURLWithPath: path), configuration: configuration) { _, error in
            if let error = error { DispatchQueue.main.async { launchError = "打开失败：\(error.localizedDescription)\n\(path)" } }
        }
    }
}

struct CompletionButton: View {
    @EnvironmentObject var store: DeskStore
    let reminder: EKReminder
    var completed = false
    var body: some View {
        Button {
            Task { await store.setCompleted(reminder, !completed) }
        } label: {
            ZStack {
                Color.clear
                if store.updatingReminders.contains(reminder.calendarItemIdentifier) {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: completed ? "checkmark.square.fill" : "square")
                        .font(.system(size: 18)).foregroundStyle(Retro.accent)
                }
            }.frame(width: 32, height: 32).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(store.updatingReminders.contains(reminder.calendarItemIdentifier))
        .accessibilityLabel(completed ? "恢复为未完成" : "标记完成")
        .help(completed ? "恢复为未完成" : "完成并移至已完成列表")
    }
}

struct Workbench: View {
    @EnvironmentObject var store: DeskStore
    @State var composer: Compose?
    @State var section = "概览"
    @State var tab = "全部待办"
    @State var floating = false
    @State var query = ""
    @State var now = Date()
    @State var selectedDay = Calendar.current.startOfDay(for: Date())
    @State var pendingDeletion: DeletionRequest?
    let timer = Timer.publish(every: 60, on: .main, in: .common).autoconnect()
    let sections = ["概览", "本周重点", "待办", "日程", "备忘"]
    var filtered: [EKReminder] {
        let items: [EKReminder]
        switch tab {
        case "本周到期": items = store.weekTasks
        case "仅重点": items = store.important
        default: items = store.reminders
        }
        return items.filter { query.isEmpty || ($0.title ?? "").localizedCaseInsensitiveContains(query) }
    }
    /// 已完成待办（按完成时间倒序，来自 store.completedReminders），同样支持搜索。
    var completedFiltered: [EKReminder] {
        store.completedReminders.filter { query.isEmpty || ($0.title ?? "").localizedCaseInsensitiveContains(query) }
    }
    var activeList: [EKReminder] { tab == "已完成" ? completedFiltered : filtered }
    var focusList: [EKReminder] { tab == "已置顶" ? store.important.filter { store.pinned.contains($0.calendarItemIdentifier) } : store.important }
    var dayEvents: [EKEvent] {
        let d = store.dayInterval(containing: selectedDay)
        return store.events.filter { $0.startDate < d.end && $0.endDate > d.start }
    }
    /// 日程分区“任意日期”：按浏览锚点所在周的事件 + 选中日过滤。
    var browseDayEvents: [EKEvent] {
        let d = store.dayInterval(containing: store.browseDate)
        return store.browseEvents.filter { $0.startDate < d.end && $0.endDate > d.start }
    }
    var scheduleEvents: [EKEvent] { tab == "选中日" ? browseDayEvents : store.browseEvents }
    var tabsForSection: [String] {
        switch section {
        case "本周重点": return ["全部", "已置顶"]
        case "日程": return ["整周全部", "选中日"]
        case "备忘": return ["最近 30 天", "紧凑"]
        case "待办": return ["全部待办", "本周到期", "仅重点", "已完成"]
        default: return ["全部待办", "本周到期", "仅重点"]
        }
    }
    var headline: (String, String) {
        switch section {
        case "本周重点": return (store.weekFocusLabel, "只做最重要的几件事。")
        case "待办": return ("待办事项", "小步推进，也是进展。")
        case "日程": return ("日程安排", "给专注，也留一段时间。")
        case "备忘": return ("随手备忘", "想到了，就先记下来。")
        default: return ("我的工作桌", "把今天，过得有条理。")
        }
    }
    var newLabel: String { section == "日程" ? "新建日程" : section == "备忘" ? "新建备忘" : "新建待办" }
    func newCompose() -> Compose {
        switch section {
        case "日程": return Compose(kind: "日程")
        case "备忘": return Compose(kind: "备忘")
        case "本周重点": return Compose(focus: true)
        default: return Compose()
        }
    }
    func app(_ name: String) { NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/" + name + ".app")) }
    func select(_ item: String) {
        section = item
        if let first = tabsForSection.first { tab = first }
    }
    func reload() async {
        await store.refresh()
        if store.notesConnected { await store.refreshNotes() }
    }
    func toggleFloating() {
        floating.toggle()
        NSApp.windows.filter { $0.title == "Deskday" }.forEach { $0.level = floating ? .floating : .normal }
    }
    func badge(for item: String) -> Int? {
        switch item {
        case "本周重点": return store.important.count
        case "待办": return store.reminders.count
        case "日程": return store.events.count
        case "备忘": return store.memos.count
        default: return nil
        }
    }
    func columnHead(_ title: String, _ subtitle: String, _ marker: Color, action: @escaping () -> Void) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Rectangle().fill(marker).frame(width: 6, height: 6).padding(.top, 4)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(pixel(14)).foregroundStyle(Retro.ink)
                Text(subtitle).font(pixel(12)).foregroundStyle(Retro.dim)
            }
            Spacer(minLength: 6)
            Button(action: action) { Image(systemName: "plus").font(.system(size: 11)) }
                .buttonStyle(RetroButtonStyle())
                .help("新建" + title)
        }
    }
    func sectionLink(_ title: String, _ target: String) -> some View {
        Button { select(target) } label: {
            HStack(spacing: 5) {
                Text(title).font(pixel(12))
                Text("→").font(pixel(12))
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(Retro.accent)
    }
    func connectButton(_ title: String, _ work: @escaping () async -> Void) -> some View {
        Button(title) { Task { await work() } }.buttonStyle(RetroButtonStyle(prominent: true))
    }
    func openButton(_ title: String, _ bundle: String) -> some View {
        Button(title + " ↗") { app(bundle) }.buttonStyle(RetroButtonStyle())
    }
    func statusLine(_ name: String, _ ok: Bool) -> some View {
        HStack(spacing: 6) {
            Rectangle()
                .fill(ok ? Retro.accent : Color.clear)
                .frame(width: 6, height: 6)
                .overlay(Rectangle().stroke(ok ? Retro.accent : Retro.line, lineWidth: 1))
            Text(name).font(pixel(12)).foregroundStyle(ok ? Retro.ink : Retro.dim)
            Spacer(minLength: 4)
            Text(ok ? "已连接" : "未连接").font(pixel(12)).foregroundStyle(ok ? Retro.accent : Retro.dim)
        }
    }
    func appRow(_ title: String, _ symbol: String, _ bundle: String) -> some View {
        RetroNavRow(title: title, symbol: symbol, active: false) { app(bundle) }
    }
    func eventRow(_ e: EKEvent) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Rectangle().fill(lavender).frame(width: 3)
            VStack(alignment: .leading, spacing: 5) {
                Text(e.startDate.formatted(.dateTime.month().day()) + " · " + (e.isAllDay ? "全天" : "\(e.startDate.formatted(date: .omitted, time: .shortened)) – \(e.endDate.formatted(date: .omitted, time: .shortened))")).font(pixel(12)).foregroundStyle(lavender)
                Text(e.title ?? "未命名").font(pixel(13)).foregroundStyle(Retro.ink).fixedSize(horizontal: false, vertical: true)
                Text(e.calendar.title + ((e.alarms?.isEmpty ?? true) ? " · 未设提醒" : " · 已设提醒")).font(pixel(12)).foregroundStyle(Retro.dim)
                if let loc = e.location, !loc.isEmpty { Text(loc).font(pixel(12)).foregroundStyle(Retro.dim) }
            }
            Spacer(minLength: 4)
            Button { composer = Compose(kind: "日程", title: e.title ?? "", body: e.notes ?? "", eventID: e.calendarItemIdentifier, occurrenceStart: e.startDate) } label: {
                Image(systemName: "square.and.pencil").font(.system(size: 11)).foregroundStyle(Retro.dim)
            }
            .buttonStyle(.plain)
            .help("编辑这条日程，可修改具体时间（只改当前这一次）")
            .accessibilityLabel("编辑日程")
            Button { pendingDeletion = deleteRequest(for: e) } label: {
                Image(systemName: "trash").font(.system(size: 11)).foregroundStyle(Retro.dim)
            }
            .buttonStyle(.plain)
            .help("删除这条日程（仅当前这一次，同步删除 Apple 日历）")
            .accessibilityLabel("删除日程")
        }
        .padding(11)
        .background(Retro.bg)
        .overlay(Rectangle().stroke(Retro.line, lineWidth: 1))
    }
    func memoCard(_ memo: Memo, compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(memo.title).font(pixel(13)).foregroundStyle(Retro.ink).lineLimit(2).fixedSize(horizontal: false, vertical: true)
            if !compact {
                Text(memo.text).font(pixel(12)).foregroundStyle(Retro.dim).lineLimit(5).fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                Button("查看原文") { Task { await store.openMemo(memo) } }.buttonStyle(RetroButtonStyle())
                Button("转为待办") { composer = Compose(kind: "待办", title: memo.title, body: "来自 Apple 备忘录\n\(memo.text)\n原文标识：\(memo.id)") }.buttonStyle(RetroButtonStyle())
                Spacer(minLength: 0)
                Button { pendingDeletion = deleteRequest(for: memo) } label: {
                    Image(systemName: "trash").font(.system(size: 11)).foregroundStyle(Retro.dim)
                }
                .buttonStyle(.plain)
                .help("删除这条备忘（同时删除原生 Apple 备忘录）")
                .accessibilityLabel("删除备忘")
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Retro.bg)
        .overlay(Rectangle().stroke(Retro.line, lineWidth: 1))
    }
    func dueText(_ dc: DateComponents, _ d: Date) -> String {
        dc.hour == nil ? "截止 " + d.formatted(.dateTime.month().day()) : "截止 " + d.formatted(.dateTime.month().day().hour().minute())
    }
    func isOverdue(_ dc: DateComponents, _ d: Date) -> Bool {
        dc.hour == nil ? d.addingTimeInterval(86399) < now : d < now
    }
    // MARK: 删除确认（只构造请求与文案，真正删除在用户确认后执行）

    func deleteRequest(for r: EKReminder) -> DeletionRequest {
        let id = r.calendarItemIdentifier
        let name = r.title ?? "未命名"
        var message = "会从 Apple 提醒事项中删除“\(name)”，无法撤销。"
        if let linked = store.linkedEvent(for: id) {
            message += " 这件待办还关联着日历日程“\(linked.title ?? "未命名")”，确认后会同时删除那条关联日程。"
            if !store.calendarAllowed { message += " 当前没有日历完全访问权限，无法一并删除关联日程；请先恢复权限，本次不会删除任何内容。" }
        }
        return DeletionRequest(target: .reminder(r), title: "删除这件待办？", message: message)
    }
    func deleteRequest(for e: EKEvent) -> DeletionRequest {
        let name = e.title ?? "未命名"
        let when = e.startDate.formatted(.dateTime.year().month().day())
        var message = "会从 Apple 日历中删除“\(name)”（\(when)），无法撤销。"
        if e.hasRecurrenceRules { message += " 这是重复日程，只会删除当前这一次。" }
        message += " 如果这条日程由本应用从待办生成，对应关联关系也会一并解除。"
        return DeletionRequest(target: .event(e), title: "删除这条日程？", message: message)
    }
    func deleteRequest(for memo: Memo) -> DeletionRequest {
        DeletionRequest(target: .memo(memo), title: "删除这条备忘？", message: "会删除 Apple 备忘录里的“\(memo.title)”，原生备忘录中的这条笔记也会一起删除，无法撤销。")
    }
    func confirmDeletion(_ request: DeletionRequest) {
        Task {
            switch request.target {
            case .reminder(let r): _ = await store.deleteReminder(r)
            case .event(let e): _ = await store.deleteEvent(e)
            case .memo(let m): _ = await store.deleteMemo(m)
            }
            pendingDeletion = nil
        }
    }
    func taskRow(_ r: EKReminder) -> some View {
        HStack(alignment: .top, spacing: 10) {
            CompletionButton(reminder: r)
            VStack(alignment: .leading, spacing: 5) {
                Text(r.title ?? "未命名").font(pixel(13)).foregroundStyle(Retro.ink).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Text(r.calendar.title).font(pixel(12)).foregroundStyle(Retro.dim)
                    if let dc = r.dueDateComponents, let d = dc.date {
                        Text(dueText(dc, d)).font(pixel(12)).foregroundStyle(isOverdue(dc, d) ? peach : Retro.dim)
                    } else {
                        Text("无截止时间").font(pixel(12)).foregroundStyle(Retro.dim)
                    }
                }
            }
            Spacer(minLength: 4)
            Button { store.pin(r) } label: {
                Image(systemName: store.pinned.contains(r.calendarItemIdentifier) ? "star.fill" : "star")
                    .font(.system(size: 11))
                    .foregroundStyle(store.pinned.contains(r.calendarItemIdentifier) ? peach : Retro.dim)
            }
            .buttonStyle(.plain)
            .help("本周重点置顶 / 取消")
            Button { composer = Compose(kind: "待办", title: r.title ?? "", body: r.notes ?? "", reminderID: r.calendarItemIdentifier) } label: {
                Image(systemName: "calendar.badge.plus").font(.system(size: 11)).foregroundStyle(Retro.dim)
            }
            .buttonStyle(.plain)
            .help(UserDefaults.standard.string(forKey: "eventFor." + r.calendarItemIdentifier) == nil ? "编辑这件待办，可安排到日历" : "编辑待办与已关联的日程")
            Button { pendingDeletion = deleteRequest(for: r) } label: {
                Image(systemName: "trash").font(.system(size: 11)).foregroundStyle(Retro.dim)
            }
            .buttonStyle(.plain)
            .help("删除这件待办（同步删除 Apple 提醒事项；若有关联日程会一并删除）")
            .accessibilityLabel("删除待办")
        }
        .padding(.vertical, 10)
    }
    /// 已完成待办行：只提供“恢复为未完成”和“删除”两个动作，避免与星标、日历编辑产生歧义。
    /// 勾选按钮走原生恢复（isCompleted = false），不是删除；删除仍走既有确认弹窗。
    func completedRow(_ r: EKReminder) -> some View {
        HStack(alignment: .top, spacing: 10) {
            CompletionButton(reminder: r, completed: true)
            VStack(alignment: .leading, spacing: 5) {
                Text(r.title ?? "未命名").font(pixel(13)).foregroundStyle(Retro.dim).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Text(r.calendar.title).font(pixel(12)).foregroundStyle(Retro.dim)
                    if let done = r.completionDate {
                        Text("完成于 " + done.formatted(.dateTime.month().day().hour().minute())).font(pixel(12)).foregroundStyle(Retro.accent)
                    } else {
                        Text("已完成").font(pixel(12)).foregroundStyle(Retro.dim)
                    }
                }
                if let linked = store.linkedEvent(for: r.calendarItemIdentifier) {
                    Text("已关联日程：" + (linked.title ?? "未命名")).font(pixel(12)).foregroundStyle(Retro.dim).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 4)
            Button { pendingDeletion = deleteRequest(for: r) } label: {
                Image(systemName: "trash").font(.system(size: 11)).foregroundStyle(Retro.dim)
            }
            .buttonStyle(.plain)
            .help("删除这件已完成的待办（同步删除 Apple 提醒事项；若有关联日程会一并删除）")
            .accessibilityLabel("删除待办")
        }
        .padding(.vertical, 10)
    }
    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Rectangle().fill(Retro.line).frame(width: 1)
            mainArea
        }
        .frame(minWidth: 1040, minHeight: 660)
        .background(Retro.bg)
        .preferredColorScheme(.dark)
        .sheet(item: $composer) { Editor(input: $0).environmentObject(store) }
        .alert("需要留意", isPresented: Binding(get: { store.error != nil && composer == nil }, set: { if !$0 { store.error = nil } })) { Button("知道了") { store.error = nil } } message: { Text(store.error ?? "") }
        .task { await store.refresh() }
        .onChange(of: store.browseDate) { _, _ in Task { await store.refreshBrowse() } }
        .onChange(of: section) { _, newValue in if newValue == "日程" { Task { await store.refreshBrowse() } } }
        .onReceive(timer) { tick in
            now = tick
            Task { await store.refresh(); if store.notesConnected && Calendar.current.component(.minute, from: tick) % 5 == 0 { await store.refreshNotes() } }
        }
    }

    // MARK: 左导航

    var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 5) {
                Text("DESKDAY").font(pixel(15)).tracking(3).foregroundStyle(Retro.ink)
                Text("原生工作台").font(pixel(12)).foregroundStyle(Retro.dim)
            }
            .padding(.horizontal, 14)
            .padding(.top, 20)
            .padding(.bottom, 18)
            VStack(spacing: 2) {
                ForEach(sections, id: \.self) { item in
                    RetroNavRow(title: item, badge: badge(for: item), active: section == item) { select(item) }
                }
            }
            .padding(.horizontal, 6)
            Rectangle().fill(Retro.line).frame(height: 1).padding(.horizontal, 14).padding(.vertical, 14)
            VStack(alignment: .leading, spacing: 2) {
                Text("原生应用").font(pixel(12)).tracking(1).foregroundStyle(Retro.dim).padding(.horizontal, 9).padding(.bottom, 6)
                appRow("提醒事项", "checklist", "Reminders")
                appRow("日历", "calendar", "Calendar")
                appRow("备忘录", "note.text", "Notes")
            }
            .padding(.horizontal, 6)
            Spacer(minLength: 12)
            VStack(alignment: .leading, spacing: 8) {
                Text("授权状态").font(pixel(12)).tracking(1).foregroundStyle(Retro.dim)
                statusLine("日历", store.calendarAllowed)
                statusLine("提醒事项", store.reminderAllowed)
                statusLine("备忘录", store.notesConnected)
                if !store.calendarAllowed || !store.reminderAllowed {
                    connectButton("连接日历与提醒") { await store.connect() }
                }
                if !store.notesConnected {
                    Button("连接备忘录") { Task { await store.refreshNotes() } }
                        .buttonStyle(RetroButtonStyle())
                        .disabled(store.notesBusy)
                }
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 16)
        }
        .frame(width: 160, alignment: .leading)
        .background(Retro.bg)
    }

    // MARK: 主区骨架

    var mainArea: some View {
        VStack(spacing: 0) {
            header
            RetroTabs(items: tabsForSection, selection: $tab)
            ScrollView { content.padding(24) }
            footerBar
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .alert(pendingDeletion?.title ?? "确认删除", isPresented: Binding(get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } }), presenting: pendingDeletion) { request in
            Button("删除", role: .destructive) { confirmDeletion(request) }
            Button("取消", role: .cancel) { pendingDeletion = nil }
        } message: { request in
            Text(request.message)
        }
    }

    var header: some View {
        HStack(alignment: .top, spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                Text("DESKDAY  /  " + section).font(pixel(12)).tracking(2).foregroundStyle(Retro.accent)
                Text(headline.0).font(pixel(36)).foregroundStyle(Retro.ink)
                Text(headline.1).font(pixel(24)).foregroundStyle(Retro.dim)
            }
            Spacer(minLength: 12)
            headerActions
        }
        .padding(.horizontal, 24)
        .padding(.top, 22)
        .padding(.bottom, 16)
    }

    var headerActions: some View {
        VStack(alignment: .trailing, spacing: 10) {
            HStack(spacing: 8) {
                Button(floating ? "已置顶" : "窗口置顶") { toggleFloating() }.buttonStyle(RetroButtonStyle())
                Button("刷新") { Task { await reload() } }.buttonStyle(RetroButtonStyle()).disabled(store.busy || store.notesBusy)
                Button(newLabel) { composer = newCompose() }.buttonStyle(RetroButtonStyle(prominent: true))
            }
            CodexLaunchButtons()
            HStack(spacing: 8) {
                if store.busy || store.notesBusy { Text("同步中…").font(pixel(12)).foregroundStyle(Retro.accent) }
                Text(now, format: .dateTime.year().month().day().weekday()).font(pixel(12)).foregroundStyle(Retro.dim)
                Text(store.lastSync == nil ? "等待连接" : "上次同步 " + store.lastSync!.formatted(date: .omitted, time: .shortened)).font(pixel(12)).foregroundStyle(Retro.dim)
            }
        }
    }

    var footerBar: some View {
        HStack(spacing: 8) {
            Rectangle().fill(store.lastSync == nil ? Retro.dim : Retro.accent).frame(width: 6, height: 6)
            Text(store.message).font(pixel(12)).foregroundStyle(Retro.dim)
            Spacer(minLength: 8)
            Text("一件一件来，就很好。").font(pixel(12)).foregroundStyle(Retro.dim)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 9)
        .background(Retro.panel)
        .overlay(alignment: .top) { Rectangle().fill(Retro.line).frame(height: 1) }
    }

    @ViewBuilder var content: some View {
        switch section {
        case "本周重点": focusSection
        case "待办": todoSection
        case "日程": scheduleSection
        case "备忘": memoSection
        default: overviewSection
        }
    }

    // MARK: 概览

    var overviewSection: some View {
        VStack(alignment: .leading, spacing: 20) {
            focusBlock
            HStack(alignment: .top, spacing: 0) {
                todoColumn
                Rectangle().fill(Retro.line).frame(width: 1)
                scheduleColumn
                Rectangle().fill(Retro.line).frame(width: 1)
                memoColumn
            }
            .panel()
        }
    }

    var focusBlock: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Rectangle().fill(peach).frame(width: 6, height: 6)
                Text(store.weekFocusLabel).font(pixel(14)).foregroundStyle(Retro.ink)
                Text("星标置顶 · 高优先级自动汇入").font(pixel(12)).foregroundStyle(Retro.dim)
                Spacer(minLength: 8)
                Text("\(store.important.count) 件").font(pixel(12)).foregroundStyle(Retro.accent)
                Button { composer = Compose(focus: true) } label: { Image(systemName: "plus").font(.system(size: 11)) }
                    .buttonStyle(RetroButtonStyle())
                    .help("新建一件本周重点")
            }
            if store.important.isEmpty {
                RetroEmpty(title: "给重要的事留个位置", detail: "在待办旁点星标，或新建一件本周重点。置顶会一直保留，直到完成或取消。")
            } else {
                VStack(spacing: 0) {
                    ForEach(store.important, id: \.calendarItemIdentifier) { r in
                        taskRow(r)
                        Rectangle().fill(Retro.line).frame(height: 1)
                    }
                }
            }
        }
        .padding(16)
        .panel(true)
    }

    var todoColumn: some View {
        VStack(alignment: .leading, spacing: 12) {
            columnHead("待办事项", "小步推进，也是进展", mint) { composer = Compose() }
            if !store.reminderAllowed { connectButton("连接提醒事项") { await store.connect() } }
            if filtered.isEmpty {
                RetroEmpty(title: store.reminderAllowed ? "这里暂时清清爽爽" : "你的待办，还没连接", detail: "新增、完成和截止时间都会写回 Apple 提醒事项。")
            } else {
                VStack(spacing: 0) {
                    ForEach(filtered.prefix(5), id: \.calendarItemIdentifier) { r in
                        taskRow(r)
                        Rectangle().fill(Retro.line).frame(height: 1)
                    }
                }
            }
            Spacer(minLength: 0)
            sectionLink("查看全部待办", "待办")
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    var scheduleColumn: some View {
        VStack(alignment: .leading, spacing: 12) {
            columnHead("日程安排", "给专注，也留一段时间", lavender) { composer = Compose(kind: "日程") }
            dayChips(start: store.week.start, selection: $selectedDay)
            if dayEvents.isEmpty {
                RetroEmpty(title: "这一页，还留着空白", detail: store.calendarAllowed ? "今天没有日程。给自己安排一段不被打扰的时间吧。" : "授权后显示本周日程，点击日期切换。")
            } else {
                VStack(spacing: 8) {
                    ForEach(dayEvents.prefix(3), id: \.calendarItemIdentifier) { e in eventRow(e) }
                }
            }
            Spacer(minLength: 0)
            sectionLink("查看整周日程", "日程")
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    var memoColumn: some View {
        VStack(alignment: .leading, spacing: 12) {
            columnHead("随手备忘", "想到了，就先记下来", peach) { composer = Compose(kind: "备忘") }
            if !store.notesConnected {
                Button("连接 Apple 备忘录") { Task { await store.refreshNotes() } }.buttonStyle(RetroButtonStyle()).disabled(store.notesBusy)
                RetroEmpty(title: "想法不必一次写完整", detail: "读取近 30 天修改的非加锁备忘，最多 40 条。首次连接需允许自动化访问。")
            } else if store.memos.isEmpty {
                RetroEmpty(title: "等一个新想法", detail: "点右上角新建，写下第一条备忘。")
            } else {
                VStack(spacing: 10) {
                    ForEach(store.memos.prefix(2)) { memo in memoCard(memo, compact: true) }
                }
            }
            Spacer(minLength: 0)
            sectionLink("查看全部备忘", "备忘")
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: 本周重点

    var focusSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Text("星标置顶的待办会一直出现在这里，直到完成或取消。").font(pixel(12)).foregroundStyle(Retro.dim)
                Spacer(minLength: 8)
                Text("\(focusList.count) 件").font(pixel(12)).foregroundStyle(Retro.accent)
            }
            if focusList.isEmpty {
                RetroEmpty(title: "还没有本周重点", detail: "在待办右侧点星标，即可把它设为本周重点；也可以直接新建一件。")
            } else {
                VStack(spacing: 0) {
                    ForEach(focusList, id: \.calendarItemIdentifier) { r in
                        taskRow(r)
                        Rectangle().fill(Retro.line).frame(height: 1)
                    }
                }
            }
            HStack(spacing: 10) {
                Button("新建一件重点") { composer = Compose(focus: true) }.buttonStyle(RetroButtonStyle(prominent: true))
                sectionLink("去待办列表", "待办")
            }
        }
        .padding(16)
        .panel()
    }

    // MARK: 待办

    var todoSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                TextField("找一件事…", text: $query)
                    .textFieldStyle(.plain)
                    .font(pixel(12))
                    .foregroundStyle(Retro.ink)
                    .inputBox()
                Button("新建待办") { composer = Compose() }.buttonStyle(RetroButtonStyle(prominent: true))
            }
            if !store.reminderAllowed { connectButton("连接提醒事项与日历") { await store.connect() } }
            if activeList.isEmpty {
                if tab == "已完成" {
                    RetroEmpty(title: "还没有已完成的待办", detail: "完成一件待办后，它会归档到这里，仍可随时恢复为未完成。")
                } else {
                    RetroEmpty(title: store.reminderAllowed ? "这里暂时清清爽爽" : "你的待办，还没连接", detail: "新增、完成和截止时间都会写回 Apple 提醒事项。")
                }
            } else {
                VStack(spacing: 0) {
                    ForEach(activeList, id: \.calendarItemIdentifier) { r in
                        if tab == "已完成" { completedRow(r) } else { taskRow(r) }
                        Rectangle().fill(Retro.line).frame(height: 1)
                    }
                }
            }
            HStack(spacing: 10) {
                Text(tab == "已完成" ? "共 \(activeList.count) 件已完成 · 点勾选可恢复为未完成，不会删除" : "共 \(activeList.count) 件 · 完成会同步回 Apple 提醒事项")
                    .font(pixel(12)).foregroundStyle(Retro.dim)
                Spacer(minLength: 8)
                openButton("打开提醒事项", "Reminders")
            }
        }
        .padding(16)
        .panel()
    }

    // MARK: 日程

    var scheduleSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Button("上一周") { store.browseDate = store.dateAdding(days: -7, to: store.browseDate) }.buttonStyle(RetroButtonStyle())
                Button("今天") { store.browseDate = Date() }.buttonStyle(RetroButtonStyle())
                Button("下一周") { store.browseDate = store.dateAdding(days: 7, to: store.browseDate) }.buttonStyle(RetroButtonStyle())
                DatePicker("", selection: $store.browseDate, displayedComponents: .date)
                    .labelsHidden()
                    .datePickerStyle(.compact)
                    .font(pixel(12))
                    .help("选择要查看的日期，日程按所在整周读取")
                Spacer(minLength: 8)
                Text(store.browseWeekRangeText).font(pixel(12)).foregroundStyle(Retro.dim)
            }
            Text("浏览日期与“本周重点”统计互不影响；点“今天”可随时回到当周。").font(pixel(12)).foregroundStyle(Retro.dim)
            dayChips(start: store.browseWeek.start, selection: $store.browseDate)
            if !store.calendarAllowed { connectButton("连接日历") { await store.connect() } }
            if scheduleEvents.isEmpty {
                RetroEmpty(title: "这一页，还留着空白", detail: store.calendarAllowed ? (tab == "选中日" ? "这一天没有日程。给自己安排一段不被打扰的时间吧。" : "这一周没有日程。给自己安排一段不被打扰的时间吧。") : "授权后显示所选周的日程，点击日期切换。")
            } else {
                VStack(spacing: 8) {
                    ForEach(scheduleEvents, id: \.calendarItemIdentifier) { e in eventRow(e) }
                }
            }
            HStack(spacing: 10) {
                Text("新建日程默认提前 15 分钟提醒").font(pixel(12)).foregroundStyle(Retro.dim)
                Spacer(minLength: 8)
                openButton("打开日历", "Calendar")
            }
        }
        .padding(16)
        .panel()
    }

    func dayChips(start: Date, selection: Binding<Date>) -> some View {
        HStack(spacing: 6) {
            ForEach(0..<7, id: \.self) { offset in
                let day = store.dateAdding(days: offset, to: start)
                let active = Calendar.current.isDate(day, inSameDayAs: selection.wrappedValue)
                Button { selection.wrappedValue = day } label: {
                    VStack(spacing: 5) {
                        Text(["一", "二", "三", "四", "五", "六", "日"][offset]).font(pixel(12)).foregroundStyle(active ? Retro.bg : Retro.dim)
                        Text(day, format: .dateTime.day()).font(pixel(14)).foregroundStyle(active ? Retro.bg : Retro.ink)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(active ? Retro.accent : Retro.bg)
                    .overlay(Rectangle().stroke(active ? Retro.accent : Retro.line, lineWidth: 1))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("选择 " + Self.chipFormatter.string(from: day))
            }
        }
    }
    static let chipFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_Hans_CN")
        f.timeZone = .current
        f.dateFormat = "M 月 d 日 EEEE"
        return f
    }()

    // MARK: 备忘

    var memoSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Text(memoStatus).font(pixel(12)).foregroundStyle(Retro.dim)
                Spacer(minLength: 8)
                Button("新建备忘") { composer = Compose(kind: "备忘") }.buttonStyle(RetroButtonStyle(prominent: true))
            }
            if !store.notesConnected {
                connectButton("连接 Apple 备忘录") { await store.refreshNotes() }
                RetroEmpty(title: "想法不必一次写完整", detail: "读取近 30 天修改的非加锁备忘，最多 40 条。首次连接需允许自动化访问。")
            } else if store.memos.isEmpty {
                RetroEmpty(title: "等一个新想法", detail: "点右上角新建，写下第一条备忘。")
            } else {
                VStack(spacing: 10) {
                    ForEach(store.memos) { memo in memoCard(memo, compact: tab == "紧凑") }
                }
            }
            HStack(spacing: 10) {
                Text("共 \(store.memos.count) 条").font(pixel(12)).foregroundStyle(Retro.dim)
                Spacer(minLength: 8)
                openButton("打开备忘录", "Notes")
            }
        }
        .padding(16)
        .panel()
    }

    var memoStatus: String {
        if !store.notesConnected { return "尚未连接 Apple 备忘录" }
        return store.notesStale ? "同步失败 · 当前为上次读取的内容" : "近 30 天 · 最多 40 条 · 每 5 分钟刷新"
    }
}
@MainActor final class DesktopMode: ObservableObject {
    static let shared = DesktopMode()
    @Published var compact = true
}
struct DesktopRoot: View {
    @ObservedObject var mode = DesktopMode.shared
    var body: some View { Group { if mode.compact { DesktopWidget() } else { Workbench() } } }
}
struct DesktopWidget: View {
    @EnvironmentObject var store: DeskStore
    @State var now = Date()
    let timer = Timer.publish(every: 60, on: .main, in: .common).autoconnect()
    var upcoming: [EKReminder] { Array(store.important.prefix(4)) }
    var nextEvents: [EKEvent] { Array(store.events.filter { $0.endDate >= Date() }.prefix(3)) }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("DESKDAY").font(pixel(15)).tracking(2).foregroundStyle(Retro.ink)
                    Text("今日工作面板").font(pixel(11)).foregroundStyle(Retro.dim)
                }
                Spacer()
                Text(now, format: .dateTime.month().day().weekday()).font(pixel(11)).foregroundStyle(Retro.accent)
            }
            .padding(16)
            Rectangle().fill(Retro.line).frame(height: 1)
            VStack(alignment: .leading, spacing: 10) {
                HStack { Text(store.weekFocusLabel).font(pixel(13)).foregroundStyle(Retro.accent); Spacer(); Text("\(store.important.count) 件").font(pixel(11)).foregroundStyle(Retro.dim) }
                if upcoming.isEmpty { Text("/ 暂无重点任务").font(pixel(11)).foregroundStyle(Retro.dim).padding(.vertical, 6) }
                else { ForEach(upcoming, id: \.calendarItemIdentifier) { item in widgetTask(item) } }
            }.padding(14)
            Rectangle().fill(Retro.line).frame(height: 1)
            VStack(alignment: .leading, spacing: 10) {
                HStack { Text("接下来").font(pixel(13)).foregroundStyle(Retro.accent); Spacer(); Text("\(store.events.count) 场日程").font(pixel(11)).foregroundStyle(Retro.dim) }
                if nextEvents.isEmpty { Text("/ 暂无近期日程").font(pixel(11)).foregroundStyle(Retro.dim).padding(.vertical, 6) }
                else { ForEach(nextEvents, id: \.calendarItemIdentifier) { event in widgetEvent(event) } }
            }.padding(14)
            Rectangle().fill(Retro.line).frame(height: 1)
            VStack(alignment: .leading, spacing: 8) {
                Text("待办 / \(store.reminders.count)").font(pixel(12)).foregroundStyle(Retro.accent)
                ForEach(Array(store.reminders.prefix(2)), id: \.calendarItemIdentifier) { widgetTask($0) }
                if store.reminders.isEmpty { Text("暂无待办或尚未授权").font(pixel(12)).foregroundStyle(Retro.dim) }
                Text("随手备忘").font(pixel(12)).foregroundStyle(Retro.accent)
                if let memo = store.memos.first { Text(memo.title).font(pixel(12)).foregroundStyle(Retro.ink).lineLimit(2) }
                else { Text(store.notesConnected ? "暂无近期备忘" : "请在工作桌连接备忘录").font(pixel(12)).foregroundStyle(Retro.dim) }
            }.padding(14)
            Rectangle().fill(Retro.line).frame(height: 1)
            HStack(spacing: 7) {
                Rectangle().fill(store.lastSync == nil ? Retro.dim : Retro.accent).frame(width: 6, height: 6)
                Text(store.lastSync == nil ? "等待授权" : "已同步").font(pixel(10)).foregroundStyle(Retro.dim)
                Spacer()
                Button("打开工作桌") { openWorkbench() }.buttonStyle(.plain).font(pixel(12)).foregroundStyle(Retro.accent)
            }.padding(12)
        }
        .frame(width: 360, alignment: .leading)
        .background(Retro.panel)
        .overlay(Rectangle().stroke(Retro.line, lineWidth: 1))
        .preferredColorScheme(.dark)
        .alert("操作未完成", isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.error = nil } })) {
            Button("知道了") { store.error = nil }
        } message: { Text(store.error ?? "") }
        .task { await store.refresh() }
        .onReceive(timer) { tick in now = tick; Task { await store.refresh() } }
    }
    func widgetTask(_ item: EKReminder) -> some View {
        HStack(spacing: 8) {
            CompletionButton(reminder: item)
            Text(item.title ?? "未命名").font(pixel(11)).foregroundStyle(Retro.ink).lineLimit(2)
            Spacer(minLength: 0)
            Text(widgetDue(item)).font(pixel(10)).foregroundStyle(widgetOverdue(item) ? peach : Retro.dim).lineLimit(1).fixedSize()
        }
    }
    func widgetDue(_ item: EKReminder) -> String {
        guard let dc = item.dueDateComponents, let d = dc.date else { return "无截止时间" }
        return dc.hour == nil ? "截止 " + d.formatted(.dateTime.month().day()) : "截止 " + d.formatted(.dateTime.month().day().hour().minute())
    }
    func widgetOverdue(_ item: EKReminder) -> Bool {
        guard let dc = item.dueDateComponents, let d = dc.date else { return false }
        return dc.hour == nil ? d.addingTimeInterval(86399) < now : d < now
    }
    func widgetEvent(_ event: EKEvent) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Rectangle().fill(Retro.accent).frame(width: 3, height: 28)
            VStack(alignment: .leading, spacing: 3) {
                Text(event.title ?? "未命名").font(pixel(11)).foregroundStyle(Retro.ink).lineLimit(2)
                Text(widgetEventTime(event)).font(pixel(10)).foregroundStyle(Retro.dim).lineLimit(1).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
    func widgetEventTime(_ event: EKEvent) -> String {
        let day = event.startDate.formatted(.dateTime.month().day())
        if event.isAllDay { return day + " · 全天" }
        return day + " " + event.startDate.formatted(date: .omitted, time: .shortened) + "–" + event.endDate.formatted(date: .omitted, time: .shortened)
    }
    func openWorkbench() {
        DesktopMode.shared.compact = false
        if let window = NSApp.windows.first(where: { $0.title.hasPrefix("Deskday") }) {
            window.level = .normal; window.setContentSize(NSSize(width: 1240, height: 840)); window.center(); window.makeKeyAndOrderFront(nil)
        }
        NSApp.setActivationPolicy(.regular); NSApp.activate(ignoringOtherApps: true)
    }
}

@MainActor func configureDesktopWidgetWindow() {
    guard let window = NSApp.windows.first(where: { $0.title.hasPrefix("Deskday") }) else { return }
    DesktopMode.shared.compact = true
    window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
    window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
    window.isMovableByWindowBackground = true
    window.hasShadow = false
    window.titleVisibility = .hidden
    window.titlebarAppearsTransparent = true
    window.isOpaque = false
    window.backgroundColor = .clear
    window.setContentSize(NSSize(width: 360, height: 560))
    if let screen = NSScreen.main { window.setFrameOrigin(NSPoint(x: screen.visibleFrame.maxX - 390, y: screen.visibleFrame.maxY - 590)) }
    window.orderFrontRegardless()
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { configureDesktopWidgetWindow() }
        if let i = CommandLine.arguments.firstIndex(of: "--snapshot"), CommandLine.arguments.count > i + 1 {
            let path = CommandLine.arguments[i + 1]
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                if let view = NSApp.windows.first(where: { $0.title.hasPrefix("Deskday") })?.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                    view.cacheDisplay(in: view.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
                }
                NSApp.terminate(nil)
            }
        }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { if !flag { sender.windows.first?.makeKeyAndOrderFront(nil) }; return true }
}
@main struct DeskdayApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject var store = DeskStore()
    var body: some Scene {
        Window("Deskday", id: "main") { DesktopRoot().environmentObject(store) }.defaultSize(width: 360, height: 330).windowStyle(.hiddenTitleBar)
        MenuBarExtra("Deskday", systemImage: "square.grid.2x2") {
            Button("打开完整工作桌") { DesktopMode.shared.compact = false; NSApp.setActivationPolicy(.regular); NSApp.activate(ignoringOtherApps: true); if let w = NSApp.windows.first(where: { $0.title.hasPrefix("Deskday") }) { w.level = .normal; w.setContentSize(NSSize(width: 1240, height: 840)); w.center(); w.makeKeyAndOrderFront(nil) } }
            Button("回到桌面组件") { NSApp.setActivationPolicy(.accessory); configureDesktopWidgetWindow() }
            Button("刷新任务与日程") { Task { await store.refresh() } }
            Divider()
            Button("退出 Deskday") { NSApp.terminate(nil) }
        }
    }
}
