# Openhop

**Reach Mullvad through your own VPS when Mullvad's server IPs are blocked.**

Openhop turns a cheap VPS into a *dumb UDP relay*: your device runs the normal Mullvad WireGuard client, and the VPS only forwards already-encrypted packets to Mullvad. You connect only to your VPS's own IP, so a block on Mullvad's IPs never reaches you. The VPS holds no keys and can never read your traffic or resolve DNS on your behalf.

```
Your device (Mullvad WireGuard client)
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

## What this does and does not protect

| Who's watching | What they see | What they can't see |
|---|---|---|
| Your ISP / local network | A persistent UDP link from your device to your VPS. They can tell the VPS is yours: that link is **visible and unavoidable**. | Content, destinations, or DNS: all sealed inside the WireGuard tunnel before it leaves your device. |
| The VPS / its datacentre | Sealed WireGuard UDP it forwards but cannot decrypt. It performs only IP/UDP header rewriting, never plaintext inspection or DNS. | Your traffic or DNS lookups. With anonymous (Monero) payment, also not tied to your name in billing. |
| Mullvad | Your traffic exits here. Mullvad holds no identity on you and keeps no logs. | Your real identity / home IP (it sees only the VPS's IP). |
| Websites you visit | Mullvad's shared exit IP; you are one of thousands. | Your real IP. |

Be straight about three things:

1. **The ISP-to-VPS link is visible.** Openhop hides *what you do* (via encryption), not *that you use a VPS*.
2. **The VPS makes its own outbound connections** (for `apt` security updates, NTP, and its own DNS). The strong guarantee is that your *forwarded* traffic can only take the relay path; it is not a guarantee that the box has zero outbound of its own.
3. **The kill switch is your device's job.** Openhop ensures the VPS can't mis-route your traffic; it cannot stop your device from leaking if the tunnel drops and your WireGuard/Mullvad app's kill switch is off. Turn the kill switch **on**.

Monero payment is an optional datacentre-side paper-trail reduction, **not a core privacy pillar**; the visible connection is identical regardless of how you paid.

## Quickstart

On a fresh Ubuntu 22.04/24.04 VPS:

```bash
sudo bash setup.sh --mullvad-ip <mullvad_server_ip> --yes
sudo bash setup.sh show     # confirm the ruleset
```

On your device, take the WireGuard config from your Mullvad account and change one line (the `Endpoint`) to your VPS (see [`wg-client.conf.example`](wg-client.conf.example)):

```ini
Endpoint = <VPS_PUBLIC_IP>:51820
```

Connect. Done.

### Useful options

| Option | Default | Notes |
|---|---|---|
| `--mullvad-port` | `51820` | Mullvad also serves UDP `53` and `443`; use these if `51820` is also blocked. |
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

## License

GPLv3. Forks and improvements must stay open.
