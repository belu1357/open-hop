# Openhop

**Reach Mullvad through your own VPS when Mullvad's server IPs are blocked.**

Openhop turns a cheap VPS into a *dumb UDP relay*: your device runs the normal WireGuard client, and the VPS only forwards already-encrypted packets to Mullvad. You connect only to your VPS's own IP, so a block on Mullvad's IPs never reaches you. Because the tunnel begins and ends on your own hardware, the VPS never holds a key and physically cannot read your traffic or resolve DNS on your behalf.

```
Your device (WireGuard client pointing at your VPS)
        |   WireGuard-encrypted on YOUR hardware
        v
Your VPS (dumb UDP relay)
        |   nftables DNAT + masquerade, forwards sealed UDP only
        v
Mullvad (decrypts here; runs its own DNS)
        |
        v
Internet
```

## Why this exists

VPN access is increasingly restricted by blocking the VPN provider's own servers: a network operator or authority takes the provider's published IP ranges and drops traffic to them. When that happens the app still runs, but its servers are simply unreachable.

Openhop routes around that one specific failure. Because your device connects to *your* VPS (an ordinary server IP that isn't on any provider blocklist) and the VPS forwards your already-encrypted packets onward, a block on the provider's IPs never touches the address you actually connect to. You become your own reachable entry point.

This is deliberately narrow. It restores *reachability* when provider IPs are blocked; it is not a tool for hiding that you use a VPN, and it targets no specific system or entity. It's built on a simple principle: access to a service shouldn't depend on that service's servers being reachable from your network. When a provider's own IPs get blocked, having your own entry point keeps the route open.

Why it works, plainly: blocks usually target a provider's *known* server addresses. Openhop doesn't rely on those. You connect to your own ordinary server, which isn't on any blocklist, and it passes your already-encrypted traffic through to Mullvad. There is no known VPN address for a filter to catch.

It's also preemptive by design. The lesson from places where access is heavily restricted is that you want a route in place *before* it's needed, not after. We think keeping an open route to the internet, on hardware you control, is worth protecting. Mullvad put the wider concern well in writing that age-based access controls are, in effect, <a href="https://mullvad.net/en/blog/age-verification-for-social-media-the-beginning-of-the-end-for-a-free-internet">"the beginning of the end for a free internet"</a>. Their post is a good read for the bigger picture. Openhop is one small, practical response: keep a route open.

## What this does and does not protect

| Who's watching | What they see | What they can't see |
|---|---|---|
| Your ISP / local network | A persistent UDP link from your device to your VPS. They can tell the VPS is yours: that link is **visible and unavoidable**. | Content, destinations, or DNS: all sealed inside the WireGuard tunnel before it leaves your device. |
| The VPS / its datacentre | Sealed WireGuard UDP it forwards but cannot decrypt. It performs only IP/UDP header rewriting, never plaintext inspection or DNS. | Your traffic or DNS lookups. |
| Mullvad | Your traffic exits here. Mullvad holds no identity on you and keeps no logs. | Your real identity / home IP (it sees only the VPS's IP). |
| Websites you visit | Mullvad's shared exit IP; you are one of thousands. | Your real IP. |

Be straight about four things:

1. **The ISP-to-VPS link is visible.** Openhop hides *what you do* (via encryption), not *that you use a VPS*.
2. **The VPS makes its own outbound connections** (for `apt` security updates, NTP, and its own DNS). The strong guarantee is that your *forwarded* traffic can only take the relay path; it is not a guarantee that the box has zero outbound of its own.
3. **The kill switch is your device's job.** Openhop ensures the VPS can't mis-route your traffic; it cannot stop your device from leaking if the tunnel drops and your WireGuard/Mullvad app's kill switch is off. Turn the kill switch **on**.
4. **The relay port is open by default.** Anyone who guesses your `VPS_IP:51820` can push UDP through your relay, but it is useless to them without your Mullvad key (Mullvad authenticates the peer), so abuse is bounded to your bandwidth. Pass `--allow-source <your IP>` to restrict it.

## Quickstart

On a fresh Ubuntu 22.04/24.04 VPS:

```bash
sudo bash setup.sh --mullvad-ip <mullvad_server_ip> --yes
sudo bash setup.sh show     # confirm the ruleset
sudo bash setup.sh confirm  # keep the rules (cancels the 10-min auto-revert)
```

With `--yes` the install is non-interactive and **arms a 10-minute lockout guard**: do nothing and the firewall reverts to open after 10 min (so a bad rule can't brick SSH). The `confirm` line above cancels it. For a fully unattended install (e.g. cloud-init) that keeps the rules immediately, pass `--guard-mins 0` instead.

On your device, take the WireGuard config from your Mullvad account and change one line (the `Endpoint`) to your VPS (see [`wg-client.conf.example`](wg-client.conf.example)):

```ini
Endpoint = <VPS_PUBLIC_IP>:51820
```

Connect. Done.

## Full setup guide (from scratch)

If you're newer to this, here's the whole thing start to finish. It takes about 20-30 minutes and needs no prior server experience.

### 1. Rent a VPS

A VPS is just a small Linux computer you rent in a datacentre. Any provider works; these are cheap, reliable, and easy to start with:

- **Hetzner** - very cheap, well regarded. A "CX22" or the smallest instance is plenty.
- **DigitalOcean** - beginner-friendly interface, good docs. Smallest "Droplet" is fine.
- **Vultr** or **Linode** - similar, widely available regions.

When creating it, choose **Ubuntu 22.04 or 24.04** as the operating system and the smallest size. Pick a location in a country where VPN use is allowed, and whose network isn't the one blocking you. After it's created, the provider shows you the server's **public IP address** (four numbers like `198.199.121.238`) - note it down, you'll need it. Most providers (DigitalOcean, Hetzner, Vultr) also give you a **web console**: a button that opens a black terminal window in your browser and logs you straight in, so you don't have to set up SSH. Use that if you'd rather not SSH.

### 2. Get a Mullvad WireGuard config

Before touching the server, grab a config from Mullvad's website (this reuses your existing keys - it doesn't use up a new one):

1. Go to Mullvad's [WireGuard config generator](https://mullvad.net/en/account/wireguard-config) and log in.
2. You'll see dropdowns to **select an exit location**. Pick a **country** and a **city** (any is fine - somewhere near your VPS is good). Leave the third dropdown on **All servers**, or pick one specific server; it doesn't matter.
3. Leave the **Content Blocking** checkboxes unchecked for now.
4. Click **Download zip archive** and open the zip. Inside are several `.conf` files, one per server, named like `us-lax-wg-002.conf`.
5. **Pick any one** of them and open it in any **text editor**. You'll see something like:

   ```ini
   [Interface]
   PrivateKey = ...
   Address = ...
   DNS = 10.64.0.1

   [Peer]
   PublicKey = ...
   Endpoint = 23.234.72.127:51820
   ```

6. **Note the IP in the `Endpoint` line** (here, `23.234.72.127`) - that's your Mullvad server IP for the next step. Keep this file open; you'll edit it in step 4.

### 3. Install Openhop on the VPS

Open your VPS's **web console** (or SSH in), then paste these one at a time. Replace `<mullvad_server_ip>` with the Endpoint IP you noted in step 2:

```bash
git clone https://github.com/belu1357/openhop.git
cd openhop
sudo bash setup.sh --mullvad-ip <mullvad_server_ip> --yes
sudo bash setup.sh confirm
```

The setup prints `openhop relay up` and even tells you the exact `Endpoint` line to set next. The `confirm` line locks the firewall rules in (otherwise they auto-revert after 10 minutes, which is a safety net so a bad rule can't lock you out).

### 4. Install WireGuard and point your config at your VPS

On the device you'll actually browse from, install the **standalone WireGuard app** from [wireguard.com/install](https://www.wireguard.com/install/) (desktop) or the **WireGuard** app from your phone's app store.

> **Not the Mullvad app.** The Mullvad app only connects to Mullvad's own servers and can't import a custom config - so it can't point at your VPS. You need the plain WireGuard app, which lets you load and edit a config. The Mullvad [Windows](https://mullvad.net/en/help/wireguard-app-windows) / [Linux](https://mullvad.net/en/help/easy-wireguard-mullvad-setup-linux) guides are useful background on WireGuard itself.

Now edit the `.conf` file you opened in step 2. Find the `Endpoint` line and change **only the IP** to your VPS's public IP (leave the `:51820` port and everything else exactly as-is, especially `DNS = 10.64.0.1`):

```ini
Endpoint = <VPS_PUBLIC_IP>:51820
```

Save the file. Then load it into WireGuard:

- **Desktop:** open WireGuard → **Add Tunnel** / **Import tunnel(s) from file** → choose your edited `.conf`.
- **Phone:** open WireGuard → **+** → **Create from file or archive** (get the edited file onto your phone first).

Click **Activate / Connect**.

### 5. Check it works

First, understand the checkpoint: Mullvad's own check sites (like `am.i.mullvad.net`) **won't load unless you're connected through Mullvad** - so if one fails while you're disconnected, that's expected, not a fault.

- **Before connecting**, visit [https://dnsleaktest.com](https://dnsleaktest.com) - it shows your **real home IP and location**. Note it.
- **Connect the tunnel** (step 4), then reload [https://dnsleaktest.com](https://dnsleaktest.com) - the IP and location should now be **your Mullvad exit** (the city you picked), not your home. Your real IP has vanished.
- For extra confirmation, visit [https://am.i.mullvad.net](https://am.i.mullvad.net) - it should now load and say **"You are using Mullvad VPN"** with the server name.
- In the WireGuard app itself, a **recent "Latest handshake"** time and rising **Transfer** numbers are proof the relay is forwarding correctly.

If the IP changed to your Mullvad city, it works - you're reaching Mullvad through your own server.

### Useful options

| Option | Default | Notes |
|---|---|---|
| `--mullvad-port` | `51820` | Mullvad also serves UDP `53` and `443`; use these if `51820` is also blocked. |
| `--listen-port` | `51820` | Port on the VPS your client connects to (the port in your `Endpoint` line). |
| `--check` | | Render the config and `nft -c` syntax-check it; do not apply. |
| `--allow-source <cidr>` | *(any)* | Restrict the relay to a source IP/CIDR (e.g. your home IP). |
| `--ssh-port` | `22` | Admin port kept open. |
| `--guard-mins` | `10` | Lockout-guard window; `0` disables it. |

## Verify it works

After connecting, check for leaks and fail-closed behaviour:

- **DNS / IP leak:** with the tunnel up, a site like dnsleaktest.com should show a Mullvad exit and resolver, **not** your ISP. `dig +short @10.64.0.1 whoami.akamai.net` should resolve.
- **Fail closed:** with the kill switch on, disconnect the tunnel; browsing must fail and `dig @10.64.0.1` must fail (resolver unreachable). Nothing should fall back to your bare connection.
- **VPS isolation:** `sudo nft list ruleset` shows only SSH + the relay. From a third host, only `udp/51820` (and SSH) respond.

## Rebuild story

If your VPS IP gets blocked, recovery is: deploy a new VPS, run `sudo bash setup.sh --mullvad-ip <ip> --yes`, change the `Endpoint` line, reconnect. **Back up `setup.sh` and your WireGuard config offline** (USB + encrypted cloud); those two files are your entire setup.

## Troubleshooting

- **No handshake:** try `--mullvad-port 53` or `--mullvad-port 443` (some networks block 51820).
- **Locked out of SSH:** don't panic: the guard reverts the firewall to open after 10 minutes (`--guard-mins`). Reconnect and re-run `setup.sh`.
- **DNS not resolving:** confirm `DNS = 10.64.0.1` is still in your client config.
- **Relay silently stopped after working before:** if you used `--allow-source` and your source IP later changes (e.g. new home IP), the relay stops until you re-run `setup.sh` with the new `--allow-source` (or drop the restriction).

## Roadmap

Openhop is built in tiers, matched to how access restrictions escalate. Each rung keeps the same architecture (your own server, off any provider blocklist) and adds a layer of disguise on top. As blocking methods evolve, we plan to keep Openhop current, adding the layer needed to meet each new class of restriction as it appears.

- **v1: beats IP-blocking (available now).** Defeats the most common restriction: blocking a VPN provider's published server IPs. You connect to your own ordinary VPS IP, so a block on Mullvad's addresses never reaches the address you actually use. This is the method most likely to be used where VPN use itself is still legal.
- **v2: obfuscation mode (planned).** Adds traffic-shape disguise (e.g. `udp2raw` or AmneziaWG-style wrapping) so the tunnel doesn't carry a recognisable WireGuard signature. This targets networks that use deep packet inspection to detect VPN traffic by its shape rather than its destination.
- **v3: stealth masquerade (planned).** Adds a mode that disguises the connection as a genuine visit to a normal website (e.g. VLESS+Reality), to withstand active probing, where the network connects to your server to test whether it behaves like a VPN.

v1 is deliberately kept clean and minimal so the core relay is easy to audit. The obfuscation tiers are optional layers on top, not rewrites, so you can run only what your situation needs.

## A note on Mullvad

Openhop is an independent, community project. It is **not affiliated with, endorsed by, or supported by Mullvad**. It simply works alongside Mullvad's standard WireGuard client. Please don't direct Openhop support questions to Mullvad.

## License

GPLv3. Forks and improvements must stay open.
