# Session codes

Codes describe an offline schedule, not a server-side room. Both applications
must use the same work duration, break duration, and whole-second UTC anchor.
Changing settings during a session remains disabled.

## Presets: unchanged, six Base32 characters

Alphabet: `ABCDEFGHIJKLMNOPQRSTUVWXYZ234567`, most-significant group first.

```text
30 bits = work preset index (4) | break preset index (4) | anchor modulo (22)
work:  [15, 600, 1200, 1800] seconds
break: [5, 15, 20, 60] seconds
anchor modulo: floor(Unix seconds) % 4,194,304
```

All sixteen preset combinations retain their original byte-for-byte encoding.
Unused preset indices are rejected instead of silently substituting defaults.

## Custom values: eleven Base32 characters

Each duration is an integer from 1 through 86,400 seconds, inclusive. When either
value is outside its preset table, pack the two durations with mixed radix:

```text
settings = (workSeconds - 1) * 86,400 + (breakSeconds - 1)
payload = (settings << 22) | anchorModulo
code = payload as exactly 11 Base32 characters (55 bits, zero-padded)
```

Decode with `work = settings / 86,400 + 1` and
`break = settings % 86,400 + 1`. Reject settings at or above `86,400²`.
The length distinguishes the format; no version field or service is needed.
The macOS share dialog groups custom codes as `XXXXX-XXXXXX`. Copy uses the raw
code; both join dialogs accept spaces, hyphens, and lowercase Base32.

There are `86,400² × 2²²` schedules and anchors to represent. This requires
55 bits, so eleven Base32 characters are the minimum fixed length while retaining
this range and the existing anchor precision/window. Six characters provide only
30 bits and cannot preserve all of this information without a lookup server or
reducing precision, range, or the sharing window.

## Timing and compatibility

Resolve the anchor to the timestamp nearest to the joining device's clock,
using the same modulo wrap logic as previous versions. The unambiguous sharing
window remains approximately ±24.3 days; this is not a perpetual invitation.
Devices still need reasonably aligned system clocks. Hosts use the same floored
anchor they share, preventing fractional-second disagreement between devices.

Preset codes work with earlier six-character clients. Custom codes require the
updated client on both platforms. Do not truncate a custom code to six
characters. The old `Base64(work:break:absoluteUnixAnchor)` import path remains,
with validation of finite, positive, whole-second durations in the supported
range and a finite nonnegative anchor before year 10000.

These codes have no checksum or authentication, as in the original format.
The join dialog displays the decoded schedule for review. Invalid lengths,
characters, reserved preset indices, out-of-range settings, and invalid legacy
values do not change the active schedule.

## Verification

`Tests/PauselyCoreTests/Fixtures/session-codes.json` is shared by Swift and C#.
It includes every preset combination, custom-only work and break cases, both
limits, modulo rollover, and timestamps beyond the signed 32-bit Unix limit.
Both suites also sweep every second of each field, test entry and adjustment
synchronization, and exercise countdown/cycle boundaries.

Before releasing, check on both desktops:

- Open Custom from each menu; type `37`, `2:37`, and `24:00:00`, then use the
  adjustment buttons. The editable display must update immediately.
- Clear the field or enter `0`, `1:60`, or `86401`. Save and adjustments must be
  disabled with inline input guidance.
- Save and restart; the exact value and custom checkmark must survive. Cancel,
  Escape, and closing the editor must preserve the previous setting.
- Host 37s work / 13s break; copy to the other platform, verify the preview, and
  join. Verify synchronized work/break transitions and restored values on leave.
- Repeat with presets (six characters) and the 1s / 1s boundary schedule.
- Check keyboard navigation, VoiceOver/Narrator labels, macOS light/dark mode,
  and Windows display scaling. PR macOS tests attach native dialog snapshots.
