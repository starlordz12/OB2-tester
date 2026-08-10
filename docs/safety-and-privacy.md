# Safety and privacy

## Operator checklist

1. Close or save unrelated work before a live run.
2. Keep the game on the primary display, visible, unminimized, and unobscured.
3. Do not type, click, alt-tab, lock the desktop, or disconnect an RDP session during control.
4. Confirm the expected executable SHA before accepting results from a new build.
5. Stop the tester immediately if the visible craft or scene does not match the transcript.

The controller uses global Windows input APIs because the game consumes physical keyboard and mouse input. It verifies the foreground target before every event and always releases a key it pressed, but the safest operating assumption is still that the machine is dedicated to the test for the duration of a live attempt.

## Capture boundary

New evidence captures use the 1280x720 game client rather than the outer window. This avoids title-bar and rounded-corner desktop leakage. Screen capture still records anything drawn over the client, including notifications or overlapping windows, so keep the game unobscured.

The curated historical screenshots predate client-only capture and include the outer game window. They were visually reviewed for this private repository but should not be moved to a public repository without a fresh privacy review.

## Stored metadata

New transcripts use UTC timestamps, relative evidence paths, executable filename, and SHA-256. They do not intentionally store usernames, Codex workspace paths, absolute game paths, or process IDs. Mutable run directories and local learning state are ignored by Git.

Offline probe mode writes recognized OCR text. Only replay images that are safe to store in the chosen output directory.

## Ownership

The game executable and assets are not bundled. Evidence is retained solely for authorized private beta testing. See [NOTICE.md](../NOTICE.md).

