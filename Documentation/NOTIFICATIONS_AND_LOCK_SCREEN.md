# Notifications and locked-session activities

NotchShot implements an app-owned Notification Center, an opt-in mirror of
notification banners that macOS is visibly presenting, and an optional,
display-only activity stack while the Mac session is locked. It does not read
hidden notification history, dismiss another app's notification, or send a
reply on another app's behalf, and it does not call the locked-session surface
a WidgetKit Lock Screen widget.

## Public API boundary

| Requested behavior | Public macOS support | NotchShot behavior |
| --- | --- | --- |
| Read delivered NotchShot notifications | Supported by `UNUserNotificationCenter` | Reconciles NotchShot-owned delivered and pending request identifiers into its local inbox. |
| Add actions or a text field to a NotchShot notification | Supported by `UNNotificationCategory`, `UNNotificationAction`, and `UNTextInputNotificationAction` | Offers **Mark Done** and **Reply in NotchShot**. The reply is stored locally against that NotchShot alert. |
| Read notifications posted by WhatsApp, Messages, Slack, or another app | Not exposed by `UserNotifications`; visible banner text may be available through the opt-in macOS Accessibility hierarchy | Mirrors only a newly visible banner while the session is unlocked. It does not read hidden history or Focus-suppressed notifications, and keeps the text in memory only. |
| Reply to a WhatsApp, Messages, Slack, or other third-party notification | The posting app owns its notification category, text-input action, and response callback | NotchShot can open a recognized source app so the user can reply there. It does not show an inline send control or claim that a message was sent. |
| Add an iPhone-style accessory widget to the Mac Lock Screen | WidgetKit does not offer the accessory Lock Screen families on macOS | Not implemented. |
| Start a native ActivityKit Live Activity from a macOS app | The macOS 26 SDK marks `ActivityAttributes`, `ActivityContent`, and `Activity` unavailable on macOS | Not implemented. A Mac may display activities originating on a paired iPhone; that is not a native NotchShot macOS activity. |
| Show the current song on the Mac Lock Screen | No supported API adds arbitrary app UI to the Mac Lock Screen. `canBecomeVisibleWithoutLogin` does not attach a normal app window to loginwindow's separate WindowServer Space. | Two surfaces, both opt-in. A soundless UserNotifications request, which macOS places and privacy-gates itself; and an experimental direct-distribution card. The card dynamically resolves private SkyLight Space functions, creates a screen-lock-level Space, and moves its mouse-transparent window there. Missing symbols or any WindowServer error fail open to the system notification. This private path is not App Store compatible and may break on any macOS update. |

Primary references:

- Apple says `UNUserNotificationCenter` manages notification-related activity
  for **your app or app extension**, and `getDeliveredNotifications` retrieves
  notifications delivered by **your app**:
  [UNUserNotificationCenter](https://developer.apple.com/documentation/usernotifications/unusernotificationcenter),
  [getDeliveredNotifications](https://developer.apple.com/documentation/usernotifications/unusernotificationcenter/getdeliverednotifications%28completionhandler%3A%29).
- Actions and text-input actions are registered through categories owned by the
  posting app:
  [Handling notifications and notification-related actions](https://developer.apple.com/documentation/usernotifications/handling-notifications-and-notification-related-actions).
- Apple describes `AXUIElement` as an assistive interface to information and
  actions exposed by another process's UI. It does not define Notification
  Center's banner hierarchy or a messaging reply protocol:
  [AXUIElement](https://developer.apple.com/documentation/applicationservices/axuielement).
- `NSWorkspace.OpenConfiguration.activates` is the supported handoff used to
  bring a recognized source app to the foreground:
  [activates](https://developer.apple.com/documentation/appkit/nsworkspaceopenconfiguration/3172704-activates).
- Apple's WidgetKit family table marks the accessory circular, rectangular, and
  inline Lock Screen families unavailable on Mac:
  [Developing a WidgetKit strategy](https://developer.apple.com/documentation/widgetkit/developing-a-widgetkit-strategy).
- Apple exposes whether this app's notifications may appear while locked through
  [`UNNotificationSettings.lockScreenSetting`](https://developer.apple.com/documentation/usernotifications/unnotificationsettings/lockscreensetting).
- AppKit's public
  [`NSWindow.canBecomeVisibleWithoutLogin`](https://developer.apple.com/documentation/appkit/nswindow/canbecomevisiblewithoutlogin)
  is a permission to become visible before login, not a Lock Screen widget or
  Space-placement API.
- `NSWorkspace.sessionDidResignActiveNotification` is retained for user-session
  switching; a normal Control-Command-Q lock is a different transition.

An Accessibility client can inspect and press some UI elements belonging to
other processes, but Notification Center's view hierarchy is not a documented
notification data or reply contract. NotchShot's optional mirror therefore
uses a deliberately narrow boundary: it reads only the text of a banner that
Notification Center is currently presenting, bounds the hierarchy and text,
keeps no cross-app notification database, ignores hidden history, and stops
before the session locks. The feature may break when Notification Center's
Accessibility hierarchy changes, and it never treats an Accessibility action
as a dependable cross-app reply channel.

## Implemented behavior

The Productivity Center contains a dedicated Notification Center with:

- a screenshot-inspired stack preview for media, a NotchShot alert, and Focus;
- immediate or delayed NotchShot-owned alerts with standard or high in-app
  priority;
- Mark Done, Delete, and Clear Finished lifecycle controls;
- a notification text-input action labelled **Reply in NotchShot**;
- a bounded local JSON inbox (100 items, 2 MB, reply length 2,000 characters)
  written atomically with mode `0600`;
- reconciliation with NotchShot's own pending and delivered system requests.

Settings also exposes **Mirror visible notifications in the notch**, off by
default and gated by Accessibility permission. A mirrored card shows the
source app's installed icon when it can be resolved, the sender/title, one-line
message preview, and compact age. Recognized Messages and WhatsApp cards offer
**Open [app] to reply**, which activates the installed app and dismisses the
transient NotchShot mirror. The action does not address a conversation or send
text; those operations stay in the messaging app that owns them.

"High" changes the NotchShot card's visual priority and ordering. It does not
request Critical Alert privileges or claim Apple's time-sensitive notification
semantics.

Settings exposes two independent options under Integrations:

1. **Show current song in Lock Screen notifications** submits the playing title
   and artist to macOS without drawing above the password screen.
2. **Show activity stack while Mac is locked** may show the current media
   title, Focus state, and latest due NotchShot alert.

Both are off by default. The song notification is removed after unlock, pause,
or opt-out and contains no controls. The experimental custom card is attached
to a screen-lock-level Space only after the dedicated loginwindow lock signal;
its panel is discarded and rebuilt in ordinary user Spaces after unlock. The
card and activity stack ignore pointer input while the session is inactive;
replies, playback controls, scheduling, captures, history, and settings remain
unavailable until unlock. No private notification database, screen scraping,
or cross-app action injection is involved.

## Runtime proof boundary

Source checks and automated tests can prove the app-owned state machine,
persistence bounds, private file mode, selection policy, and locked-window input
policy. A normal desktop launch can validate the unlocked visual composition.

Lock Screen notification delivery still depends on the user's macOS
Notifications settings. Source and tests can prove the opt-in, playing-state,
text-bounding, and cleanup policy, but physical delivery must be validated by
locking a test Mac after enabling **when screen is locked** and setting previews
to **Always**. Source and tests can also prove the custom bridge's symbol,
ordering, failure, and non-interaction policies. They cannot prove that
loginwindow displays the card on a particular OS build; that requires an
explicit physical lock/unlock test on the freshly built app.
