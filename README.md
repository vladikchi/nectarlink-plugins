# NectarLink for Noctalia

The NectarLink plugin lets you control an Android phone from your PC through Noctalia. Use the widget to check the battery level or open the panel to read notifications, see recent calls, send SMS, dial a number, or answer an incoming call. You can also mirror the phone's screen and type on the phone with your computer keyboard.

Use the phone as a webcam or open its camera to take a photo. Audio works both ways: listen to phone audio on your PC or use the phone as a speaker for your computer. The same panel gives you access to photos, file sharing, and clipboard sharing.

[NectarLink](https://github.com/thtbee/nectarlink) connects the phone to the computer and handles those commands. The plugin provides the controls in Noctalia, so the app needs to be running. Use [NectarLink for Noctalia](https://github.com/vladikchi/nectarlink-noctalia): the upstream build does not include the required local API routes.

![NectarLink panel in Noctalia with demo data](nectarlink/screenshot.webp)

## Installation

You need Noctalia with **Plugin API 32** and an Android phone paired with NectarLink.

1. Install [NectarLink for Noctalia](https://github.com/vladikchi/nectarlink-noctalia#installation-on-linux) on the PC. Start the app, pair your phone, and enable **Local automation API** under **Settings → Connection & About**. Run NectarLink and Noctalia as the same user.
2. In Noctalia, open **Settings → Plugins → Sources → Add source**, choose **Git**, and enter `https://github.com/vladikchi/nectarlink-plugins`. This is a custom source, not part of Noctalia's default catalog.
3. In the **Plugin Store**, find **NectarLink**, add it, and make sure it is enabled.
4. In Noctalia settings, open **Panels**, select your panel, and open **Widgets**. Add the NectarLink widget (`vladikchi/nectarlink:phone`), then click it on the bar to open the plugin panel.

If **Open application** cannot find NectarLink, set **NectarLink executable** to the absolute path of the AppImage or `nectarlink-desktop` binary.

## What you can do from the panel

- **Home:** select a phone, check its battery, read notifications, and see recent activity. Ring the phone to find it, use the flashlight or Do Not Disturb, and manage Wi-Fi, Bluetooth, hotspot, and ringer mode.
- **Screen, camera, and audio:** mirror the phone's screen on your PC, open its camera to take a photo, or use it as a webcam. Play phone audio on the PC or use the phone as a PC speaker. You can also open supported video from the PC on the phone.
- **Typing and sharing:** type on the phone with your PC keyboard, or open NectarLink's file and clipboard sharing tools. The file and clipboard shortcuts are available when exactly one phone is online.
- **Messages and calls:** read SMS and notification-based chats, send SMS, reply through an active notification, browse call history, dial a number, or manage an active call.
- **Photos:** browse albums and thumbnails and request the original photo on your PC.
- **Apps and Deck:** open supported phone apps on the PC and run Deck tiles already configured in NectarLink.

Available actions depend on the phone and its Android permissions. Notification-based chats are not a full conversation history. Sending messages, making calls, requesting original photos, and turning off Wi-Fi require confirmation. If an action times out, the plugin does not resend it; check the phone or PC before trying again.

## If the panel cannot connect

- **No connection to the app:** make sure NectarLink for Noctalia is running, its local API is enabled, and both programs run as the same user. The plugin looks for the API file in the default profile at `~/.local/share/Nectarlink/`.
- **Phone is missing:** check pairing and connectivity in NectarLink. **Check connection** refreshes the panel without sending commands to the phone.
- **Phone is visible but an action is unavailable:** check Android permissions and whether your phone supports that feature.

[How the plugin works](nectarlink/README.md) — architecture, local API, caching, settings, and tests.
