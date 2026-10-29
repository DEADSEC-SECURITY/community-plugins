# 0.3.0 verification

## Completed

- Python helper unit suite: 13 tests, covering typed message decoding, legacy
  tuples, Unicode, attachments, vCards, multi-number contacts, cache isolation,
  pagination, thread replies, expired notifications, offline actions, and errors.
  vCard coverage includes quoted-printable soft lines, base64 names and legacy charsets.
  Avatar coverage includes embedded raster decoding, limits, remote URI rejection,
  private runtime cache permissions, replacement/removal, and fallback without a cache.
  Large Unicode snapshots are framed into lines below the host's 64 KiB limit
  and reconstructed without altering their contents.
- Mocked Lua model, service, and panel suites; existing panel/service regressions.
  Coverage includes duplicate/out-of-order messages, loaded-message search,
  failed-send draft retention, duplicate sends, device changes, reconnects,
  subscribing before history requests, and late notification snapshots.
  Panel tests also check every default-page option, invalid-setting fallback,
  collapsed contact rows, expansion, and selecting a particular phone number.
- 1,000-contact panel regression: bounded rows, page navigation, full-list search,
  and reuse of the watched translation snapshot. Loaded history is also paged
  in both directions without unnecessary backend requests.
- 2,000-conversation panel regression: search by contact name, number and message
  text without rereading shared message state; replacement watch snapshots,
  coalescing update bursts into one frame, and updates while the panel is closed.
  Service tests verify that a 700-message sync burst publishes once per tick,
  pending send state remains immediate, and incomplete snapshot frames are not applied.
- Repository validation: 299 manifests passed. Plugin lint: no errors; the
  existing `migrated_notice` unused-setting warning remains.
- Native Noctalia 5.4.0 on Hyprland, KDE Connect 26.08.2, 1.333 display scaling.
  All four tabs, wide/compact layouts, and the compact composer were inspected.
  Screenshots use synthetic data with phone actions disabled.
- All three panel entries passed native open/preview/compact/close smoke checks.
- Native stress test: 302 contacts, 102 conversations, and 102 loaded messages,
  switching repeatedly through the tabs without callback timeouts.
- Live cached contact list (265 contacts with phone numbers): repeated tab
  switching without timeout errors after caching translations and paging rows.
  Decoding the 20 quoted-printable formatted names leaves no raw hex sequences
  in the displayed names; the contact cache itself is unchanged.
  The cache supplies embedded photos for 32 of these contacts. Native tab
  switching with avatars produced no image-load errors or callback timeouts.
- Rollback: removing only the local override symlink restored community 0.2.1;
  restoring the symlink loaded local 0.3.0. Settings file was unchanged, with
  exactly one bridge watcher after restoration.
- On October 29, KDE Connect supplied 700 conversations and 13 active
  notifications. Opening Messages and typing previously exceeded the host's
  callback budget because every render decoded the full shared state again.
  The panel now retains watch-delivered snapshots, coalesces state updates, and
  renders 25 conversation/message rows at a time (history requests remain 50).
  The service batches incoming signals and opening populated conversations
  reuses the subscribed cache. All three placements passed live checks in wide
  and compact mode: nine open/close cycles, 90 search changes and 36 tab changes,
  with no new callback timeouts.

## Still requiring live verification

The phone reports the required plugins as available, and the user reports that
permissions should be enabled. Contacts, conversations and notifications now
load. The caches were empty during the initial October 28 inspection but were
populated on October 29. Display and search have been checked against this live
data; the actions below still need confirmation on the phone.

- Receive/send an SMS with a user-chosen test recipient; confirm on the phone.
- Load and verify actual conversation history and older pages.
- Reply to and dismiss an actual mirrored notification; confirm on the phone.
- Phone disconnect/reconnect, incoming/missed calls, and daemon restart with
  nonempty message/notification caches.
- Manual keyboard focus, scrolling and composing; higher UI/font scaling and
  all placements under the user's preferred shell settings.

Keep the pull request as a draft until the required live checks pass.
