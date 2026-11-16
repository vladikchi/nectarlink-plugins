# NectarLink plugins

Personal Git source for the unofficial [NectarLink Noctalia plugin](nectarlink/README.md).
This is a custom source, not an accepted entry in Noctalia's default community catalog.

## Install through Noctalia

No ZIP extraction or terminal commands are needed on the receiving computer:

1. Open **Settings → Plugins → Sources → Add source**.
2. Choose **Git**. Set the name to `nectarlink` and the repository URL to
   `https://github.com/vladikchi/nectarlink-plugins`.
3. Save the source, then open the **Plugin Store** and search for **NectarLink**.
4. Open its card and choose **Add**. Noctalia fetches and activates the plugin.
5. Add the **phone** widget (`vladikchi/nectarlink:phone`) to your bar.

Noctalia needs Git available for Git sources and an internet connection to fetch
the repository. Plugin API **32** is required. Noctalia **5.3** is a test target;
native visual/device verification on that version is still pending.

Without the separate application, the plugin can load, show its guide/settings,
and report that its API file is unavailable. It should not repeatedly notify or
attempt to install or launch the application automatically.

Full phone functionality requires the **extended-API application fork**, paired
Android and appropriate permissions. The application is a separate prerequisite;
adding this source does not install it. See [requirements and limitations](nectarlink/README.md).

## Development

The single plugin lives in `nectarlink/`; `catalog.toml` is its store index.
The source history includes the original development layout before publication.
Run its tests from the plugin directory, not the repository root:

```sh
cd nectarlink
for test in tests/test_*.lua; do
    [ "$test" = tests/test_runtime.lua ] && continue
    lua "$test" || exit 1
done
noctalia plugins lint .
```

The plugin is licensed **GPL-3.0-or-later**; see [LICENSE](nectarlink/LICENSE).
