# NectarLink for Noctalia

Check your Android phone's battery from the Noctalia bar. Open the NectarLink panel to read notifications and recent activity, send SMS, manage calls, browse photos, or launch supported phone apps.

The plugin requires [NectarLink for Noctalia](https://github.com/vladikchi/nectarlink-noctalia) to be running on your PC with your phone paired.

![NectarLink panel](nectarlink/screenshot.webp)

## Installation

You need **Noctalia 5.2.0 or later** and an Android phone paired with NectarLink. No custom Android build is required.

1. Choose an AppImage, `.deb`, or `.rpm` from the [Nightly 12 for Noctalia release](https://github.com/vladikchi/nectarlink-noctalia/releases/tag/v0.1.6-nightly.12%2Bnoctalia). Start the desktop app, pair your phone, and enable **Local automation API** under **Settings → Connection & About**. Run NectarLink and Noctalia as the same user.
2. In Noctalia, open **Settings → Plugins → Sources → Add source**, choose **Git**, and enter `https://github.com/vladikchi/nectarlink-plugins`. This is a custom source, not part of Noctalia's default catalog.
3. In the **Plugin Store**, find **NectarLink**, add it, and make sure it is enabled.
4. In Noctalia settings, open **Panels**, select your panel, and open **Widgets**. Add the NectarLink widget (`vladikchi/nectarlink:phone`), then click it on the bar to open the plugin panel.

If **Open application** cannot find NectarLink, set **NectarLink executable** to the absolute path of the AppImage or `nectarlink-desktop` binary.

On desktop builds with a **Notifications and messages** toggle under **Local automation API**, enable it if you want the plugin to read either. It is separate from the main API switch.

## What you can do from the panel

- **Home:** select a phone, check its battery, read notifications, and see recent activity. Ring the phone to find it, use the flashlight or Do Not Disturb, and manage Wi-Fi, Bluetooth, hotspot, and ringer mode.
- **Screen, camera, and audio:** mirror the phone's screen on your PC, open its camera to take a photo, or use it as a webcam. Play phone audio on the PC or use the phone as a PC speaker. You can also open supported video from the PC on the phone.
- **Typing and sharing:** type on the phone with your PC keyboard, or open NectarLink's file and clipboard sharing tools. These sharing shortcuts require a single paired phone, and it must be online.
- **Messages and calls:** read SMS and notification-based chats, send SMS, reply through an active notification, browse call history, dial a number, or manage an active call.
- **Photos:** browse albums and thumbnails and request the original photo on your PC.
- **Apps and Deck:** open supported phone apps on the PC and run Deck tiles already configured in NectarLink.

Available actions depend on the phone and its Android permissions. Notification-based chats are not a full conversation history. Action buttons send requests directly, without a confirmation dialog from the plugin. Entering or selecting a number does not dial. Turning off Wi-Fi can disconnect the phone. If an action times out, the plugin does not resend it; check the phone or PC before trying again.

With the desktop API that advertises `pageCacheV2`, returning to Messages, Photos, or Apps can show the last loaded page while it refreshes. In Messages, ↻ updates the conversation list and the open chat without resetting their pages. Photos show the grid and cached previews before requesting missing thumbnails. Older API builds use standard page reads.

## If the panel cannot connect

- **No connection to the app:** make sure NectarLink for Noctalia is running, its local API is enabled, and both programs run as the same user. The plugin looks for the API file in the default profile at `~/.local/share/Nectarlink/`.
- **Phone is missing:** check pairing and connectivity in NectarLink. Use **Check connection** on the setup screen or **Refresh** on **Home** to update the panel without taking any action on the phone.
- **Notifications or messages are unavailable:** check the desktop privacy toggle and Android permissions. Apps hidden in NectarLink stay hidden from the plugin on desktop builds that report notification rules.
- **Phone is visible but an action is unavailable:** check Android permissions and whether your phone supports that feature.

[Plugin settings and IPC commands](nectarlink/README.md)
