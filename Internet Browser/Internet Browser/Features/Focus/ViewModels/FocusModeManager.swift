//
//  FocusModeManager.swift
//  Cherry Browser
//

import Foundation
import Observation

@Observable
final class FocusModeManager {
    static let shared = FocusModeManager()

    private init() {
        focusModeEnabled = UserDefaults.standard.bool(forKey: "focusModeEnabled")
        blockedDomains = UserDefaults.standard.stringArray(forKey: "focusModeBlockedDomains") ?? []
        timerEnabled = UserDefaults.standard.bool(forKey: "focusModeTimerEnabled")
        let stored = UserDefaults.standard.integer(forKey: "focusModeTimerDuration")
        timerDurationMinutes = stored > 0 ? stored : 25
    }

    // MARK: - Persisted State

    var focusModeEnabled: Bool = false {
        didSet { UserDefaults.standard.set(focusModeEnabled, forKey: "focusModeEnabled") }
    }

    var blockedDomains: [String] = [] {
        didSet { UserDefaults.standard.set(blockedDomains, forKey: "focusModeBlockedDomains") }
    }

    var timerEnabled: Bool = false {
        didSet { UserDefaults.standard.set(timerEnabled, forKey: "focusModeTimerEnabled") }
    }

    var timerDurationMinutes: Int = 25 {
        didSet { UserDefaults.standard.set(timerDurationMinutes, forKey: "focusModeTimerDuration") }
    }

    // MARK: - Timer State

    var sessionEndDate: Date? = nil
    var timeRemaining: TimeInterval = 0
    private var countdownTimer: Timer?

    var timeRemainingFormatted: String {
        let total = max(0, Int(timeRemaining))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        if hours > 0 { return String(format: "%d:%02d:%02d", hours, minutes, seconds) }
        return String(format: "%02d:%02d", minutes, seconds)
    }

    // MARK: - Start / Stop

    func startFocusMode() {
        focusModeEnabled = true
        overrideExpiries.removeAll()
        if timerEnabled {
            let duration = Double(timerDurationMinutes) * 60
            sessionEndDate = Date().addingTimeInterval(duration)
            timeRemaining = duration
            startCountdownTimer()
        } else {
            sessionEndDate = nil
            timeRemaining = 0
        }
    }

    func stopFocusMode() {
        focusModeEnabled = false
        sessionEndDate = nil
        timeRemaining = 0
        countdownTimer?.invalidate()
        countdownTimer = nil
        overrideExpiries.removeAll()
    }

    func toggleFocusMode() {
        if focusModeEnabled { stopFocusMode() } else { startFocusMode() }
    }

    private func startCountdownTimer() {
        countdownTimer?.invalidate()
        countdownTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self, let endDate = self.sessionEndDate else { return }
            let remaining = endDate.timeIntervalSinceNow
            if remaining <= 0 {
                DispatchQueue.main.async { self.stopFocusMode() }
                NotificationCenter.default.post(name: .focusModeSessionEnded, object: nil)
            } else {
                self.timeRemaining = remaining
            }
        }
    }

    // MARK: - Domain Management

    var overrideExpiries: [String: Date] = [:]

    func addDomain(_ input: String) {
        let cleaned = cleanDomain(input)
        guard !cleaned.isEmpty, !blockedDomains.contains(cleaned) else { return }
        blockedDomains.append(cleaned)
        blockedDomains.sort()
    }

    func removeDomain(_ domain: String) {
        blockedDomains.removeAll { $0 == domain }
    }

    func isDomainBlocked(_ host: String) -> Bool {
        guard focusModeEnabled else { return false }
        let lowerHost = host.lowercased()
        let now = Date()
        overrideExpiries = overrideExpiries.filter { $0.value > now }
        // Check temporary override (matches exact host or any subdomain)
        for (overrideDomain, expiry) in overrideExpiries {
            if expiry > now && (lowerHost == overrideDomain || lowerHost.hasSuffix(".\(overrideDomain)")) {
                return false
            }
        }
        return blockedDomains.contains { blocked in
            lowerHost == blocked || lowerHost.hasSuffix(".\(blocked)")
        }
    }

    func overrideDomain(_ host: String, minutes: Int = 5) {
        let base = cleanDomain(host)
        guard !base.isEmpty else { return }
        overrideExpiries[base] = Date().addingTimeInterval(Double(minutes) * 60)
    }

    func cleanDomain(_ input: String) -> String {
        var domain = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let range = domain.range(of: "://") {
            domain = String(domain[range.upperBound...])
        }
        if let slashIdx = domain.firstIndex(of: "/") {
            domain = String(domain[..<slashIdx])
        }
        if domain.hasPrefix("www.") {
            domain = String(domain.dropFirst(4))
        }
        return domain
    }
}
