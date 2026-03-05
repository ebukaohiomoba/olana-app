# Olana

An urgency-aware calendar and task companion for iOS. Olana classifies events by how time-sensitive they are, surfaces what actually needs your attention, and pairs the experience with Olu — a mascot that checks in based on what your day looks like.

> **Status:** Active development. Targeting iOS 26.

---

## Overview

Most calendar apps treat every event the same. Olana doesn't. Every event you create or sync is automatically ranked into one of three urgency tiers — **Critical**, **Soon**, or **Later** — using an on-device CoreML pipeline that combines semantic classification, embedding-space k-NN over your correction history, calendar-category priors, and timing heuristics. Notifications, daily context, and Olu's check-ins all flex based on that urgency signal.

The result is a calendar that distinguishes "mom's surgery follow-up" from "coffee with a friend" without you ever telling it to.

---

## Features

- **Urgency-tiered events.** Every event gets a Critical / Soon / Later classification with a confidence-weighted rationale.
- **Natural-language event capture.** Type *"dentist tomorrow at 3pm"* or *"team retro every Thursday 2–3"* and Olana extracts the date, time, range, and recurrence using a hybrid `NSDataDetector` + regex + on-device language model pipeline.
- **Personalised classification.** When you correct an event's urgency, Olana stores the correction in a 512-dimensional embedding space and applies it to future similar events — instant adaptation with no retraining.
- **Multi-provider calendar sync.** First-class integration with Apple Calendar (EventKit), Google Calendar, and Microsoft Calendar. Events from all providers flow through the same urgency pipeline.
- **Olu — animated companion.** A Lottie-driven mascot whose state (idle, grateful, celebrate, resting, sleep) reflects what's happening in your day. Designed to feel present without being intrusive.
- **Live Activities and Dynamic Island.** Imminent events surface on the Lock Screen and Dynamic Island with countdowns, with background refresh keeping them up to date even when the app is suspended.
- **AlarmKit-backed reminders.** For Critical events, Olana can use the AlarmKit framework for full-volume, dismissable alarms — not just notifications.
- **Friends.** Add friends, see shared events, and lightweight social signals around your schedule.
- **Apple Intelligence integration.** On-device language model integration (Foundation Models framework) for novel-phrasing parse, title cleanup, and urgency reasoning on ambiguous events. Strictly opt-in based on device eligibility; deterministic pipeline serves as the floor for everyone else.
- **Privacy by default.** All classification, parsing, and urgency reasoning happen on-device. Calendar contents never leave the phone for AI processing.
- **Liquid Glass UI.** Built on the SwiftUI glass-effect APIs with accessibility-aware fallbacks for Reduce Transparency and Differentiate Without Color.

---

## Tech Stack

| Layer | Technology |
|---|---|
| Language | Swift 6 |
| UI | SwiftUI, Liquid Glass |
| Persistence | SwiftData + CloudKit sync |
| Authentication | Firebase Auth |
| Backend | Firebase Firestore + Cloud Functions |
| Push | Firebase Cloud Messaging + APNs |
| On-device ML | CoreML (`UrgencyTitleClassifier`, `UrgencyBucketModel`), NaturalLanguage embeddings |
| On-device LLM | Apple Foundation Models (iOS 26+) |
| Calendar providers | EventKit, Google Calendar REST, Microsoft Graph |
| Animations | Lottie |
| Background work | BGTaskScheduler, ActivityKit, AlarmKit |
| Voice input | SFSpeechRecognizer + AVAudioEngine |

---

## Requirements

- **iOS 26** or later
- **Xcode 26** or later
- **macOS Sequoia 15.0** or later (for development)
- Apple Developer account (for Push, AlarmKit, App Intents, CloudKit entitlements)
- Firebase project (for Auth, Firestore, FCM)
- Google Cloud project (for Google Calendar OAuth)
- Microsoft Entra ID app registration (for Microsoft Calendar OAuth)

Apple Intelligence features additionally require an eligible device (iPhone 15 Pro / 15 Pro Max, iPhone 16 series, iPhone 17 series, or M-series iPad).

---

## Getting Started

### 1. Clone

```bash
git clone https://github.com/<your-org>/olana.git
cd olana
```

### 2. Configure Firebase

1. Create a Firebase project at [console.firebase.google.com](https://console.firebase.google.com/).
2. Add an iOS app and download `GoogleService-Info.plist`.
3. Place it at `Olana/GoogleService-Info.plist`.
4. Deploy Firestore rules and Cloud Functions:

```bash
firebase deploy --only firestore:rules,functions
```

### 3. Configure OAuth clients

Add your Google OAuth client ID and Microsoft client ID to the relevant `Info.plist` keys. URL schemes for OAuth redirects must be registered in the project's URL Types.

### 4. Open and build

```bash
open Olana.xcodeproj
```

Build target: **Olana**. Build for an iOS 26 simulator or a physical device.

On first build, Xcode may prompt to **Trust & Enable** macros from the Foundation Models package. Accept.

---

## Project Structure

```
Novel/
├── Olana/                       Main app source
│   ├── *.swift                  Views, managers, models
│   ├── Assets.xcassets          App assets
│   ├── Novel.xcdatamodeld       SwiftData schema
│   ├── *.mlmodel                CoreML urgency models
│   └── olu_*.json               Lottie animations
├── OlanaWidgets/                Widget extension target
├── functions/                   Firebase Cloud Functions (TypeScript)
├── firestore.rules              Firestore security rules
├── TrainUrgencyModel/           Training data + scripts for CoreML classifier
├── olana-website/               Marketing site
└── Olana.xcodeproj              Xcode project
```

---

## Architecture Highlights

### Urgency Pipeline

`UrgencyManager.classify(...)` runs a six-stage pipeline:

1. **Semantic classification** via `UrgencyTitleClassifier` (CoreML), with a sentence-embedding centroid fallback when confidence is low.
2. **Text-embedding k-NN** over user correction history in 512-dimensional space.
3. **Feature-space k-NN** over structural features (timing, duration, attendees).
4. **Calendar category prior** applied as a multiplicative bias.
5. **Score bias** from recent correction direction — instant personalisation without retraining.
6. **Timing rules and hard overrides** (past-due, emergency keywords).

A rationale string is generated alongside the classification for transparency in the UI.

### Calendar Sync

`CalendarSyncEngine` orchestrates per-provider `*Provider` types behind a uniform interface. Events flow into SwiftData, are classified on import, and synchronise back to providers when modified locally. Imported events use the deterministic urgency pipeline only — the Apple Intelligence path is reserved for natively-created events to keep energy use bounded.

### Live Activities

`NotificationEngine` schedules Live Activities for imminent events. A `BGAppRefreshTask` registered as `com.olana.liveActivityCheck` wakes the app to start the activity before the user's first interaction with the Lock Screen.

---

## Privacy

- All event content stays on-device for classification and AI processing.
- Firebase Auth stores only account-level identity (email, username, account creation date).
- Firestore stores profile metadata and social graph — no event content.
- OAuth tokens for Google and Microsoft Calendar are stored in the iOS Keychain.
- Telemetry, where present, uses event hashes — never raw event titles, locations, or attendee names.

---

## Roadmap

- [ ] Phase 1: Natural-language event capture with Foundation Models (in progress).
- [ ] Phase 2: Urgency reasoning augmentation for low-confidence classifier outputs.
- [ ] Phase 3: Olu daily brief and contextual voice generation.
- [ ] App Intents extension for Siri-driven event creation.
- [ ] iPad support.

---

## Contributing

This project is currently developed privately. Issue reports and feature ideas are welcome via GitHub Issues. Pull requests will be considered case-by-case until a contribution guide is published.

---

## License

TBD.

---

## Acknowledgments

- [Lottie](https://airbnb.io/lottie/) for the animation runtime.
- [Firebase](https://firebase.google.com/) for auth, storage, and messaging infrastructure.
- Apple's [Foundation Models framework](https://developer.apple.com/documentation/foundationmodels) for on-device language modelling.
- The Swift, SwiftUI, and SwiftData teams.
