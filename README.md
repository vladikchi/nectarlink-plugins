# NectarLink for Noctalia — Linux

Compact phone panel for Noctalia: notifications, messages, calls, photos,
applications, Deck and phone controls. Fixed panel size: 860×470.

## Requirements

- Linux; tested with Noctalia 5.5.0, plugin API 52.
- Python 3, available as `python` in the Noctalia process environment.
- The companion NectarLink desktop fork with the extended authenticated local
  API (`/v1/page`, `/v1/page-action`, `/v1/sessions`, `/v1/phone-toggle`).
  An unmodified upstream build is not a supported substitute.
- An already paired Android phone and permissions for the features you use.

Windows/macOS are not supported targets of this integration release.

## Install the plugin

1. Install/build the companion desktop fork and enable its local API in its
   settings. Pair your phone in NectarLink; this plugin does not perform pairing.
2. Extract the plugin package into
   `~/.local/share/noctalia/local-plugins/nectarlink/`. `plugin.toml` must be
   directly inside that directory, not inside a second nested folder.
3. Enable `local/nectarlink` in Noctalia and add its `phone` widget to a bar.
4. In plugin settings, leave the executable empty if `nectarlink-desktop` is
   in PATH; otherwise select the installed binary by its absolute path.
   Leave the helper empty to use the bundled `colors.py`.

The `local/nectarlink` ID is intentionally provisional until the public author
namespace is chosen. No public registry installation is advertised yet.

## Connection and privacy

The desktop must use the default Linux data directory
`~/.local/share/Nectarlink/`; the plugin reads `api-token.json` there. Custom
data directories are not currently configurable. Do not copy that file from
another user's machine or include it in a bug report/release.

All API requests use authenticated loopback HTTP. The plugin does not read
NectarLink's database. Cached pages are in memory; the desktop maintains a
bounded private image cache. Disabling a feature does not grant Android
permissions. Existing data may be shown while refreshing.

App and Deck tiles execute on explicit click. SMS, dialing and original photo
downloads require confirmation. Consequential commands are never automatically
retried. Check the phone before manually repeating an unconfirmed action.

## Optional desktop palette

Noctalia's UI colors apply to the plugin automatically. The desktop fork's
external palette integration is separate and optional; the plugin does not
install shell templates, compositor rules or autostart entries for you.

## Troubleshooting

- No phone: check the desktop is running, its API is enabled and phone is online.
- Launch button fails: select the executable in plugin settings or fix PATH.
- Unsupported page: check that you installed the companion fork, not upstream.
- Unavailable control: check Android permissions in the native app.
- Large fonts/DPI: the compact layout is fixed-size; arbitrary scaling has not
  been comprehensively tested.

## Development

Run `lua test_panel.lua`, `lua test_pages.lua`, `lua test_service.lua`,
`lua test_cache.lua`, `lua test_widget.lua`, `lua test_warmup.lua`,
`python -m unittest test_colors.py`, then `noctalia plugins lint .`.
Tests are in the development workspace, not the minimal runtime package. They
use mocks and do not command a real phone. A passing mock suite is not a full
visual/security audit.

## License

GPL-3.0-or-later; see LICENSE. This is an unofficial integration, not a release
endorsed by the NectarLink or Noctalia projects.
