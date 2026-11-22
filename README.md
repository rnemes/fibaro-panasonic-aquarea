# Panasonic Comfort Cloud QuickApp for Fibaro HC3

A Fibaro Home Center 3 QuickApp that controls Panasonic heat pumps through
Panasonic Comfort Cloud: Aquarea air-to-water heat pumps (zones, hot water tank,
mode, quiet/powerful, energy meters, temperature sensors) and air conditioners.

Based on the original QuickApp by zadow28
([techbliss/HC3_Quickapp_Panasonic_cloud](https://github.com/techbliss/HC3_Quickapp_Panasonic_cloud)),
updated for the current Panasonic ID login (OAuth with PKCE, signed API calls).
The version history is at the top of [`src/main.lua`](src/main.lua).

## Which file to use

| File | For | Status |
| --- | --- | --- |
| `Panasonic_Aquarea_<version>.fqa` | Aquarea air-to-water heat pumps: on/off, heat/cool/auto, zone 1 and 2 temperatures and on/off, hot water tank, force hot water, quiet and powerful modes. Also creates child devices for outdoor, zone water and tank temperatures, and energy meters for heating, hot water and cooling. | Tested |
| `Panasonic_<version>.fqa` | Panasonic air conditioners (the original QuickApp's UI): on/off, mode, temperature, fan speed, swing, eco/quiet/powerful, nanoe. | **Not tested** |

Both files contain the same code; only the screen layout and variables differ.

**Tested on:** Panasonic Aquarea All-in-One WH-ADC0309H3E5, connected to Comfort Cloud,
with a Fibaro Home Center 3. Other Aquarea models that work in the Panasonic Comfort
Cloud app will probably work too, but haven't been tried.

**The air conditioner variant has not been tested.** It uses the same new login and
API code as the Aquarea variant, and the air conditioner commands are the ones from
the original QuickApp, but nobody has run it against a real air conditioner since the
2.x rewrite. If you try it, please open an issue with the result, working or not,
and the log if it fails.

## Install

1. Download the `.fqa` file from the [latest release](../../releases/latest).
2. In the HC3: Settings > Devices > Add device > Other device > Upload File.
3. Open the new device's Variables tab, set `Username` and `password` to your
   Panasonic ID login (the same as in the Panasonic Comfort Cloud app) and save.
4. Watch the QuickApp's console. A working login shows the unit being found and
   the status being read.

### Variables

| Variable | Meaning |
| --- | --- |
| `Username`, `password` | Your Panasonic ID login |
| `deviceName` | Optional: the name of the unit to control, as shown in the Comfort Cloud app. Default: the first unit |
| `pollSeconds` | Optional: how often the status is read, in seconds. Default 300, minimum 60 |
| `appVersion` | Optional: force the app version sent to Panasonic. Leave empty; it is looked up automatically |
| `energyStart` | Optional (Aquarea), `YYYYMMDD`: the energy meters count from this day. Default: the day the adapter was registered. Change it to recount once |
| `debugRaw` | Optional (Aquarea): `1` logs the raw data from Panasonic. The "Raw data log" button does the same |
| `loginUrl`, `authCode` | Used only for the one-time browser login below |
| `Heat start temp` etc. | Air conditioner only: the temperature set when you press a mode button |

### Keeping your login safe

- The HC3 stores QuickApp variables as plain text. Anyone with admin access to the
  HC3 can read your Panasonic password, and **it is included when you export the
  QuickApp** (`.fqa`) from the HC3. Don't share exported `.fqa` files, or blank the
  password in them first (`tools/unpack.py` does this for you).
- Better: create a second Panasonic ID just for the HC3 and share your unit with it
  from the Comfort Cloud app. Then the HC3 never holds your main password, and you
  can remove its access at any time. It also has to be an account without two-factor
  authentication, which the QuickApp can't do.
- After the login the QuickApp keeps its tokens in internal storage, which is not
  exported and never logged.

## Logging in

Normally the QuickApp logs in by itself with `Username` and `password`, then keeps
a refresh token in its internal storage, so it stays logged in across restarts and
doesn't need to log in again.

### One-time browser login

Sometimes Panasonic refuses the automatic login, for example when it wants a
captcha or a confirmation. The QuickApp then shows **ONE TIME LOGIN NEEDED** in the
console and puts a fresh login address in the `loginUrl` variable. You log in once
in a browser and hand the QuickApp the code that Panasonic sends back.

The code is only valid for a few minutes, so have the HC3 open in another tab
before you start, and always use the current `loginUrl` (it changes every time a
new browser login starts, and an old one won't work).

> **Copy the `loginUrl` from the QuickApp's Variables tab, not from the console log.**
> The console shows `&amp;` instead of `&`, and the login then fails. Also use the
> `loginUrl` and `authCode` of the same QuickApp: each QuickApp has its own login, so a
> code from another QuickApp's address won't work.

After logging in, Panasonic sends the browser to an address that starts with
`panasonic-iot-cfc://`. This is meant for the phone app, so the browser can't open
it, but the address contains the code. The steps below show how to catch it.

**Chrome or Edge**

1. Copy the address from the `loginUrl` variable (Variables tab).
2. Open a new tab, press F12 (Mac: Cmd+Option+I) and select the **Console** tab.
3. Paste the address into the address bar of that tab and log in with your Panasonic ID.
4. After the login, the page looks stuck or blank, and the console shows a red error
   like `Failed to launch 'panasonic-iot-cfc://authglb.digital.panasonic.com/android/...callback?code=XXXX&state=...'`.
5. Copy the whole `panasonic-iot-cfc://...` address from the error (or just the
   `code` value).

If the console shows nothing, use the **Network** tab instead, as in the Firefox steps.

**Firefox**

Firefox doesn't log the failed address in the console, so use the Network tab:

1. Copy the address from the `loginUrl` variable (Variables tab).
2. Open a new tab, press F12 (Mac: Cmd+Option+I) and select the **Network** tab.
3. Click the gear icon in the Network tab and turn on **Persist Logs**, so the list
   isn't cleared when the page changes.
4. Paste the address into the address bar of that tab and log in with your Panasonic ID.
   If Firefox asks which application should open a `panasonic-iot-cfc` link, cancel it.
   When the login is done, Firefox shows **"The address wasn't understood"**. That's
   expected: the login worked, and the code is in the address Firefox couldn't open.
5. In the filter box of the Network tab, type `code=`. Click the last matching
   request (usually a `302` from `authglb.digital.panasonic.com`, often the `resume`
   request) and open its **Headers**.
6. Under Response Headers, copy the value of `Location`. It starts with
   `panasonic-iot-cfc://` and contains `code=...`.

**Then, in the HC3**

1. Paste the copied address (or just the code) into the `authCode` variable and save.
2. Within a few seconds the console shows "Login code received, getting tokens" and
   then "Logged in". The QuickApp clears `authCode` and `loginUrl` by itself.
3. If it shows "Browser login failed", the code was too old or came from an older
   `loginUrl`. The QuickApp makes a new `loginUrl`; repeat the steps with it, a bit faster.

You only need to do this once. After that the saved refresh token keeps the
QuickApp logged in.

## Credits

- **zadow28** wrote the original QuickApp:
  [techbliss/HC3_Quickapp_Panasonic_cloud](https://github.com/techbliss/HC3_Quickapp_Panasonic_cloud).
  The air conditioner UI and commands come from it.
- **pcomfortcloud** by lostfields:
  [python-panasonic-comfort-cloud](https://github.com/lostfields/python-panasonic-comfort-cloud).
  The Panasonic ID login (OAuth with PKCE), the token refresh and the signed API
  headers follow the same flow as this library.
- **Panasonic Comfort Cloud for Home Assistant** by sockless-coding:
  [panasonic_cc](https://github.com/sockless-coding/panasonic_cc) and
  [aio-panasonic-comfort-cloud](https://github.com/sockless-coding/aio-panasonic-comfort-cloud),
  a reference for the login and the Aquarea (air-to-water) side of Comfort Cloud.
- **Claude** (Anthropic's AI assistant) wrote most of the 2.x code, the build
  tooling and this README, working with @rnemes, who tested every version on a real
  heat pump and HC3 and fed the logs back.

## Repository layout

| Path | What it is |
| --- | --- |
| `src/main.lua` | The QuickApp code (shared by both variants) |
| `quickapps/aquarea.json` | Aquarea variant: name, device type, UI layout, uiCallbacks, variables |
| `quickapps/aircon.json` | Air conditioner variant |
| `tools/build.py` | Builds the `.fqa` files into `dist/` |
| `tools/unpack.py` | Splits an `.fqa` exported from the HC3 back into the files above |
| `.luacheckrc`, `stylua.toml` | Lint and formatting rules for the Lua code |
| `.github/workflows/build.yml` | CI build, and release upload for `v*` tags |

`.fqa` files are build output and are not committed. Only Python 3 is needed, no packages.

## Build

```sh
python3 tools/build.py          # writes dist/Panasonic_Aquarea_<version>.fqa and dist/Panasonic_<version>.fqa
python3 tools/build.py --check  # validate only
```

The version comes from the `-- version X.Y.Z` line near the top of `src/main.lua`.
The build fails if `Username`, `password` or `authCode` has a value in a manifest,
so credentials can't end up in git or in a release.

### Lint and format

The GitHub Action checks the Lua code with [luacheck](https://github.com/lunarmodules/luacheck)
(no globals, no unused variables, lines up to 120 characters) and
[StyLua](https://github.com/JohnnyMorganz/StyLua) (formatting). To run them locally:

```sh
luacheck src                                        # install with: luarocks install luacheck
npx @johnnymorganz/stylua-bin@2.0.2 src             # formats the code; add --check to only check
```

## Changing the UI on the HC3

Edit the QuickApp on the HC3 (buttons, labels, variables), export it as `.fqa`, then:

```sh
python3 tools/unpack.py ~/Downloads/Panasonic_Aquarea.fqa --manifest quickapps/aquarea.json
git diff
```

The unpack always blanks `Username`, `password` and `authCode`. Variables that are
already in the manifest keep their committed value (so `deviceName`, `loginUrl` etc.
from your HC3 don't leak in); new variables take the exported value. Add
`--take-values` to take the exported values of existing variables too.

## Release

1. Bump `-- version X.Y.Z` (and add a changelog line) in `src/main.lua`, commit, push.
2. Tag and push: `git tag v2.6.1 && git push origin v2.6.1`

GitHub Actions checks the Lua syntax, builds both `.fqa` files, checks that the tag
matches the version in `src/main.lua`, and attaches the files to the GitHub release.

## License

The QuickApp code (`src/`, `quickapps/`) is free to use and adjust for personal use,
the same terms as zadow28's original. The build tooling (`tools/`, `.github/`) is MIT.
See [LICENSE](LICENSE) for details.
