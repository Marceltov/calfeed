# CalFeed

Serves the calendars your Mac already syncs (Exchange/CalDAV, iCloud, Google, …) as **iCal feeds that only this Mac
can reach**. Built to show your meetings in [Super Productivity](https://super-productivity.com), next to your tasks,
without passwords, server setup or public calendar links. Any app that subscribes to an iCal URL works.

CalFeed reads the calendars through macOS (EventKit), so it sees exactly what the Calendar app shows.

## Install

### Homebrew (recommended)

```bash
brew install marceltov/tap/calfeed
brew services start calfeed
```

Homebrew builds CalFeed on your Mac and runs it in the background (also after a restart). Update with
`brew upgrade calfeed`. Remove with `brew services stop calfeed && brew uninstall calfeed`.

### Script

```bash
git clone https://github.com/Marceltov/calfeed.git && cd calfeed
./install.sh                 # or: PORT=9000 ./install.sh
```

This puts `CalFeed.app` into `~/Applications` and registers it as a login item. Remove it with
`./install.sh --uninstall`.

Both ways need the Xcode command line tools (`xcode-select --install`).

## First start

1. macOS asks once whether **CalFeed** may access your calendars. Click **Allow** and choose full access. If you
   missed the prompt, turn CalFeed on under *System Settings → Privacy & Security → Calendars*.
2. Open <http://localhost:8765/>. The setup page lists every calendar with a two-letter label and its feed URL.

## Use it in Super Productivity

In the right panel, click **+** → **Other (iCal)** and paste one URL per calendar you want to see. Recommended
settings: tick **Reference calendar**, untick **Auto import events as tasks**, and leave the notification empty.

Super Productivity labels each calendar tab with the first two characters of the URL's host. That's why every feed
has its own `*.localhost` host name, starting with its label (for example `ac-apple-calendar.localhost`). You can
change a label on the setup page, and then copy the new URL.

If you sync Super Productivity to other devices (for example an iPhone), tick **Disable in web or Android app** on
CalFeed calendars, because other devices can't reach your Mac's `localhost`.

## Details

- Feed: `http://<label>-<name>.localhost:8765/calendar.ics?id=<calendar id>`. macOS resolves every `*.localhost` name
  to this Mac, so you don't need `/etc/hosts` entries. All calendars at once: `http://localhost:8765/calendar.ics`.
- Covers 14 days back and 90 days ahead, and leaves out meetings you declined.
- Listens only on `127.0.0.1` and `::1`. Nothing leaves your Mac.
- Labels are stored in `~/Library/Application Support/CalFeed/labels.json` and don't change when you add calendars.
- Logs: `~/Library/Logs/CalFeed.log` (script) or `$(brew --prefix)/var/log/calfeed.log` (Homebrew).
- Calendar ids differ on every Mac, so everyone generates their own URLs on their own Mac.

## Development

```bash
scripts/build-app.sh build      # → build/CalFeed.app
build/CalFeed.app/Contents/MacOS/CalFeed --port 9000
```

To release, put the version into `VERSION`, merge, then push a tag `vX.Y.Z`. CI builds every push and pull request.

## License

MIT
