// UpdateCheckService was removed to comply with App Review guideline
// 2.4.5(vii): the Mac App Store notifies customers of updates and lets
// them update from the App Store app, so an app must not provide its own
// update checks. The previous implementation polled Apple's iTunes
// Lookup API and surfaced an "Update available" alert; all of that
// networking and UI has been deleted. This file is intentionally left
// with no type so nothing in the binary performs update checks.
