# TokenBar

TokenBar is a lightweight macOS menu bar app for monitoring local Codex activity and token usage. It reads Codex's local session data and keeps the current status and today's token count visible without opening the Codex app.

## Features

- Shows whether Codex is working, waiting for input, idle, unavailable, or ended with an error
- Displays today's token count directly in the menu bar
- Summarizes token usage and estimated API-equivalent cost for today and the last 30 days
- Charts daily usage by supported model
- Shows threads started and agent runtime for today and the last 30 days
- Reports five-hour and weekly usage limits when Codex provides them
- Identifies Pro 5× and Pro 20× plans and shows 30-day subscription value
- Refreshes automatically every two seconds, with a manual refresh option
- Keeps a local usage-history cache for faster launches

## Requirements

- macOS 26.5 or later
- Xcode 26.6 or later to build from source
- Codex with readable local data at `~/.codex`

TokenBar expects Codex's `state_5.sqlite` database and `sessions` directory to be present. If either is unavailable, the menu bar status is shown as unavailable.

## Build and run

1. Clone the repository:

   ```sh
   git clone https://github.com/Binary67/TokenBar.git
   cd TokenBar
   ```

2. Open `TokenBar.xcodeproj` in Xcode.
3. Select the `TokenBar` scheme and the **My Mac** destination.
4. Build and run the app.

TokenBar runs as a menu bar accessory, so it does not appear in the Dock. Click its menu bar item to view usage details, refresh the data, or quit.

## How it works

TokenBar reads Codex's local SQLite index and session rollout files. It incrementally processes new session records to determine activity, token usage, rate-limit windows, and model-specific usage. A 30-day cache is stored at:

```text
~/Library/Application Support/TokenBar/usage-history.json
```

All monitoring and caching happen locally. TokenBar does not send usage data over the network.

## Cost estimates

Displayed costs are API-equivalent estimates, not charges from an OpenAI bill. Estimates currently cover these models:

- `gpt-5.6-sol`
- `gpt-5.6-terra`
- `gpt-5.6-luna`

Token usage from other models contributes to the menu bar's total for today but is excluded from model-specific history and cost estimates. Rates are defined in the source and may differ from current API pricing.

## Subscription value

When Codex reports a `prolite` or `pro` plan, TokenBar identifies it as Pro 5× or Pro 20× respectively. It compares the last 30 days of API-equivalent usage with the plan's current monthly price:

- Pro 5× (`prolite`): $100 per month
- Pro 20× (`pro`): $200 per month

The resulting multiple is an estimate of API-equivalent value received, not a billing amount or guaranteed savings.

## Tests

Run the test target from Xcode with **Product > Test**, or from the repository root:

```sh
xcodebuild test \
  -project TokenBar.xcodeproj \
  -scheme TokenBar \
  -destination 'platform=macOS'
```

The tests cover token formatting, cost calculations, daily history, status detection, rate-limit parsing, caching, and incremental session processing.

## Project structure

```text
TokenBar/
├── TokenBarApp.swift       # Menu bar UI and application lifecycle
└── CodexMonitor.swift      # Local Codex data monitoring and usage calculations

TokenBarTests/
└── CodexMonitorTests.swift # Monitor and formatter tests
```
