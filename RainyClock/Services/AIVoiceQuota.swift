import Foundation

/// How many spoken alarms a device may generate.
///
/// Three are free, and after that each one costs a rewarded video. The count
/// lives entirely on the device: there is no account to attach it to, and
/// keeping it local means the feature adds no data collection to a privacy label
/// that currently declares none.
///
/// It is written to the keychain as well as `UserDefaults`, so that deleting
/// and reinstalling the app does not hand out three more. Through 1.6.8 it did,
/// and that was described here as a deliberate trade against "an identifier
/// that survives deletion" — but a counter is not an identifier: nothing leaves
/// the phone, nothing is unique, and nothing links this install to any other.
/// The privacy argument was for the server-side alternatives, not for this.
///
/// `UserDefaults` stays as the mirror, not just for migration: a process that
/// may not use the keychain (an unsigned build, a read before first unlock)
/// gets `nil` back, and treating that as zero would make the allowance
/// unlimited exactly when it is least observable. The read prefers the
/// keychain and falls back to the mirror; a reinstall has only the keychain,
/// which is the case this exists for.
@MainActor
enum AIVoiceQuota {
    static let freeGenerations = 3

    private static let usedKey = "aiVoiceGenerationsUsed"
    private static let creditsKey = "aiVoiceEarnedCredits"

    /// Replaceable so tests can count against a throwaway service rather than
    /// the app's real counters.
    static var store = KeychainCounters(service: "com.shukaihu.RainyClock.aiVoiceQuota")

    private static var used: Int {
        get { value(forKey: usedKey) }
        set { setValue(newValue, forKey: usedKey) }
    }

    /// Generations bought with a completed rewarded video, and not yet spent.
    private static var credits: Int {
        get { value(forKey: creditsKey) }
        set { setValue(newValue, forKey: creditsKey) }
    }

    /// The keychain value when there is one, else the mirror — which is also
    /// where a count written by 1.6.8 is found and carried into the keychain.
    private static func value(forKey key: String) -> Int {
        if let stored = store.integer(forKey: key) {
            return stored
        }
        let mirrored = UserDefaults.standard.integer(forKey: key)
        if mirrored != 0 {
            store.set(mirrored, forKey: key)
        }
        return mirrored
    }

    private static func setValue(_ value: Int, forKey key: String) {
        store.set(value, forKey: key)
        UserDefaults.standard.set(value, forKey: key)
    }

    static var freeRemaining: Int { max(0, freeGenerations - used) }

    static var remaining: Int { freeRemaining + credits }

    static var canGenerate: Bool { remaining > 0 }

    /// Spends one, taking the free allowance first so an earned credit is never
    /// burned while a free one is still available.
    static func consume() {
        if freeRemaining > 0 {
            used += 1
        } else if credits > 0 {
            credits -= 1
        }
    }

    /// Called the moment the ad network says the reward is earned — not when the
    /// audio arrives.
    ///
    /// This ordering is the whole point. Unity's Rewarded Ad Inventory Policy
    /// requires that a promised reward is actually delivered, and generation can
    /// fail afterwards for reasons that have nothing to do with the user: the
    /// model returns a 500, the content filter fires on a benign sentence, the
    /// network drops. Storing a credit means the retry is free and the promise is
    /// kept; handing over the audio instead would break it every time.
    static func grantCredit() {
        credits += 1
    }
}
