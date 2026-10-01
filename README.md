<p align="center"><img src="assets/icon.png" width="128" alt="Wallpad icon"></p>

# Wallpad

Turn your phone into a remote for the Macs behind your office TVs. Print a QR code, stick it on the TV,
scan it, and your phone becomes an Apple TV–style remote: one big trackpad, a keyboard, ⌃ ⌥ ⌘ modifier keys,
volume, and the function keys.

No app to install on phones: it's a web page served by the Mac on your local network.

## How it works

1. **Install Wallpad on the TV's Mac** with one Terminal command (see [Add a TV](#add-a-tv)).
2. **Allow it** in System Settings → Privacy & Security → Accessibility, so it can move the pointer and type.
3. **Print the QR code** it saves to the Mac's Desktop and **stick it on the TV**.
4. **Scan it** with your phone's camera while on the office Wi‑Fi.
5. **The first time**, type the 4-digit code shown on the TV. Your phone is remembered for 30 days.

The QR code points at a tiny router (a Cloudflare Worker) that knows each Mac's current local address, so
printed codes keep working when IPs change. It checks that your phone is on the same network as the TV and
tells you to join the office Wi‑Fi if it isn't, then hands your phone over to the Mac directly.

### The remote

- **Trackpad**: drag to move, tap to click, two-finger tap to right-click, two fingers to scroll,
  touch and hold then drag to drag.
- **⌃ ⌥ ⌘**: tap for the next action only, double-tap to lock (tap again to release).
- **Keyboard**, **volume**, and an **Fn** sheet with F1–F12, arrows, Mission Control and Launchpad.

## Security

Controlling a Mac's keyboard and mouse is powerful, so:

- **Each QR code holds a secret** for its TV. Without it the Mac accepts no input.
- **A new phone must also type a code shown on the TV**, so a photo of the QR code isn't enough: you have to
  be in the room. Phones are remembered for 30 days, 5 wrong guesses end the attempt.
- **Same network only.** The router hands out a TV's address only to phones on that TV's network, and the
  Mac only listens on the local network.
- **Per-TV keys.** Each Mac reports its address with its own key; the router only stores its hash and only
  accepts private (RFC 1918) addresses. The admin key never leaves your machine: installs use one-time
  enrollment codes (valid 1 hour, single use).
- **Signed updates.** Macs update themselves, but only to builds signed by the same Apple developer team.

What it doesn't protect against: traffic on the local network is plain HTTP / WebSocket (browsers won't trust
a self-signed certificate on a LAN IP), so someone on the same Wi‑Fi who can sniff traffic could capture a
paired phone's credentials. Use a Wi‑Fi network you trust, and run the TV Macs under a separate macOS user
with nothing sensitive logged in.

## Set it up

You need a Cloudflare account (the free plan is fine) and an Apple Development certificate in your keychain
(any Apple ID can create one in Xcode → Settings → Accounts).

```bash
git clone https://github.com/Altimor/wallpad && cd wallpad

# 1. The router
cd worker
cp wrangler.example.toml wrangler.toml
npx wrangler kv namespace create TVS          # paste the id into wrangler.toml
openssl rand -hex 32 > ~/wallpad-admin-key    # keep this; move it to ~/Library/Application Support/Wallpad/admin-key
npx wrangler secret put ADMIN_KEY < ~/wallpad-admin-key
npx wrangler deploy                           # note the https://wallpad.<you>.workers.dev URL
cd ..

# 2. The Mac app
echo "https://wallpad.<you>.workers.dev" > .router
scripts/package.sh                            # builds, signs and stages Wallpad.app for the router
(cd worker && npx wrangler deploy)            # publishes it
```

## Add a TV

```bash
scripts/install-command.sh "Lobby TV"   # copies the install command (with a one-time code)
```

Paste it into Terminal on the TV's Mac, allow Wallpad under Accessibility, print the QR card from its Desktop.
Re-running the installer keeps the same QR code. `~/Applications/Wallpad.app/Contents/MacOS/wallpad qr`
regenerates the card.

## Ship a change

`scripts/package.sh && (cd worker && npx wrangler deploy)`. Every Mac picks it up within 15 minutes.

## Layout

- `agent/`: the Mac app (Swift, no dependencies): input injection, the remote page (`remote.html`), pairing,
  address reporting, self-update, QR cards.
- `worker/`: the router (Cloudflare Worker + KV).
- `scripts/`: packaging, installer, install-command helper.

Local testing: `WALLPAD_HOME=<scratch dir> WALLPAD_DRYRUN=1 agent/.build/release/wallpad` logs input (and the
pairing code) instead of injecting it.

## License

MIT
