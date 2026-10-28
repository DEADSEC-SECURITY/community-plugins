# 0.3.0 verification

## Completed

- Python helper unit suite: 10 tests, covering typed message decoding, legacy
  tuples, Unicode, attachments, vCards, multi-number contacts, cache isolation,
  pagination, thread replies, expired notifications, offline actions, and errors.
  vCard coverage includes quoted-printable soft lines, base64 names and legacy charsets.
- Mocked Lua model, service, and panel suites; existing panel/service regressions.
  Coverage includes duplicate/out-of-order messages, loaded-message search,
  failed-send draft retention, duplicate sends, device changes, reconnects,
  subscribing before history requests, and late notification snapshots.
- 1,000-contact panel regression: bounded rows, page navigation, full-list search,
  and a single translation-table read per render. Loaded history is also paged
  in both directions without unnecessary backend requests.
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
- Rollback: removing only the local override symlink restored community 0.2.1;
  restoring the symlink loaded local 0.3.0. Settings file was unchanged, with
  exactly one bridge watcher after restoration.

## Still requiring live verification

The phone reports the required plugins as available, and the user reports that
permissions should be enabled. Contacts load. Conversation and notification
caches were empty, including after a direct sync request and opening KDE
Connect's own SMS application. This is an unresolved synchronization check,
not evidence that a particular permission is missing.

- Receive/send an SMS with a user-chosen test recipient; confirm on the phone.
- Load actual conversation history and older pages.
- Reply to and dismiss an actual mirrored notification; confirm on the phone.
- Phone disconnect/reconnect, incoming/missed calls, and daemon restart with
  nonempty message/notification caches.
- Manual keyboard focus, scrolling and composing; higher UI/font scaling and
  all placements under the user's preferred shell settings.

Keep the pull request as a draft until the required live checks pass.
