# Detection — why a service might flag "VPN/Proxy detected"

Changing the network-layer exit IP (what this whole project does) is only
one of several signals apps and sites use to flag proxy/VPN usage. This
doc covers what else to check, how to check it, and what's actually fixable
versus what's an inherent limitation of this architecture.

## The four things to check, in order of how common/severe they are

### 1. IP reputation / proxy classification databases

Many anti-fraud and geo-enforcement services don't just look at the IP's
ASN/location — they query a reputation database (IP2Proxy, IPQualityScore,
MaxMind's GeoIP2 Anonymous IP DB, Spur, Scamalytics, etc.) that classifies
the IP by *type*: residential, datacenter/hosting, "server", known VPN
exit, known public proxy, and so on. A paid SOCKS5 proxy's exit IP can get
classified as a non-residential type even when its ASN is a genuine
consumer ISP — the classification tracks how the IP is actually *used*
(e.g. leased out for proxying), not just who owns the IP block.

**How to check**: free lookup at `https://scamalytics.com/ip/<the-ip>` (no
account needed) shows a fraud score plus explicit flags (`Server`,
`Residential Proxy`, `Anonymizing VPN`, `Public Proxy`, etc.) and often an
explicit note like *"this is a commercial server which could be proxying
traffic from another geographical location."* That note, or a `Server:
Yes` flag, is very likely enough on its own to trip a service's "VPN
detected" check, independent of the numeric fraud score.

**Fix — rotate to a cleaner IP on the same account.** If the proxy
provider offers more than one exit IP (check how many ports/IPs your plan
includes), test each one's reputation *before* committing to it as the
live exit — this varies a lot IP-to-IP even within the same provider and
plan. See Operations → "Changing the proxy provider or exit location" for
how to switch without any router-side changes. This is not a permanent
fix in the sense that a clean IP can get flagged later (IP reputation
changes over time based on how it's used across all of a provider's
customers, not just you) — treat it as something to re-check periodically,
not a one-time task.

### 2. Timezone / locale mismatch

Many services compare the browser's JS-reported timezone
(`Intl.DateTimeFormat().resolvedOptions().timeZone`, which reads the
*operating system's* clock setting) against the timezone implied by the
IP's geolocation. If the exit IP geolocates to a different region than the
OS clock's timezone, that mismatch alone is a strong, independent "this
traffic is proxied" signal — this has nothing to do with the IP's
reputation and would flag even a perfectly clean residential IP.

**How to check**: open the browser console and run
`Intl.DateTimeFormat().resolvedOptions().timeZone` — compare it to the exit
IP's geolocated timezone (shown on most IP-lookup sites, including
Scamalytics above).

**What does *not* work, confirmed by direct testing on Windows**: setting
the `TZ` environment variable before launching Chrome. Chromium on Windows
reads the timezone from the Windows API, not the `TZ` env var — this
approach works on Linux/macOS but not here, despite being a commonly
suggested trick. Don't rely on it without testing on the actual target OS.

**Actual options, in order of how invasive they are:**
- Leave it and accept the mismatch as a known detection vector.
- Chrome DevTools' Sensors panel (`Emulation.setTimezoneOverride`) works,
  but only for as long as DevTools stays attached to that tab — not
  practical for normal day-to-day browsing.
- A browser extension that overrides `Intl`/`Date` at the JS level can
  make this persistent without touching the OS — but means trusting a
  third-party extension with page-script-level access, which is a real
  tradeoff for a project whose whole point is not leaking information to
  third parties. Vet carefully before installing anything for this
  specific purpose.
- Changing the OS timezone itself is the only fully persistent,
  no-extra-software option, at the cost of every other app/clock on that
  machine showing the "wrong" local time while it's set.

This is a setting change on the machine itself, not something to automate
unattended — whichever option is chosen, apply it manually.

### 3. WebRTC leaks

WebRTC's ICE/STUN negotiation can reveal a device's real public IP even
when all other browser traffic is correctly proxied, because many setups
only proxy TCP, not UDP — and WebRTC's STUN requests are UDP. This is one
of the most common and severe leaks for exactly this class of setup
(SOCKS5-over-TUN).

**How to check**: in a browser console, open an `RTCPeerConnection` with a
public STUN server and log the ICE candidates it gathers:

```js
const pc = new RTCPeerConnection({iceServers:[{urls:'stun:stun.l.google.com:19302'}]});
pc.createDataChannel('x');
const candidates = [];
pc.onicecandidate = e => e.candidate && candidates.push(e.candidate.candidate);
pc.createOffer().then(o => pc.setLocalDescription(o));
// wait a few seconds, then inspect `candidates`
```

A `srflx` (server-reflexive) candidate containing a public IP that doesn't
match the proxy's exit IP is a leak. In this deployment's case, no `srflx`
candidate ever came back at all — the STUN request's UDP traffic is
effectively blackholed by the tunnel (consistent with `tun2socks`/this
SOCKS5 provider not supporting the SOCKS5 UDP ASSOCIATE command). That's
good news here (no leak), but it's incidental to how the tunnel handles
UDP, not a deliberate WebRTC-specific protection — re-test this after any
change to the tunnel software or provider, rather than assuming it still
holds.

**If a leak is ever found**: disabling WebRTC entirely in the browser
(`chrome://flags` has had WebRTC-related flags move around across
versions — check what's current) or via an extension is the usual fix,
at the cost of breaking real WebRTC use cases (video calls, etc.) for
that browser.

### 4. IPv6 bypass

This whole setup is IPv4-only (the router's policy routing and the VM's
`tun2socks` tunnel both only handle IPv4). If a LAN device has a routable
*global* IPv6 address (not just a link-local `fe80::` one) and the site
being accessed supports IPv6, most OSes and browsers prefer IPv6 by
default (Happy Eyeballs) — meaning traffic goes out directly over IPv6,
completely bypassing the proxy, with no kill-switch protection at all
(the kill switch is IPv4-only policy routing).

**How to check**: from the LAN device in question, check for a global
(non-`fe80::`) IPv6 address (`ipconfig` on Windows, `ip -6 addr` on
Linux), and try fetching an IPv6-only test endpoint, e.g.
`https://api6.ipify.org?format=json` — if that succeeds, IPv6 is live and
unprotected.

**In this deployment, as of the date of this doc**: no global IPv6 was
present on the LAN at all (the ISP connection doesn't appear to hand out
IPv6), so this specific device wasn't leaking — but that's because IPv6
isn't available right now, not because anything here actively blocks it.
**Treat this as a latent risk, not a solved problem.** If the ISP ever
enables IPv6 (a firmware update, a plan change, etc.), this setup would
start leaking over IPv6 immediately with no warning, since nothing
currently monitors for it.

**Fix, if/when IPv6 shows up**: disable IPv6 entirely on the router's LAN
side (simplest, matches this setup's IPv4-only design), or extend the kill
switch to cover IPv6 too (more work, only worth it if the proxy provider
itself supports an IPv6 path, which most SOCKS5 proxy services don't).

### 5. HTTP header leaks (X-Forwarded-For, Via, Proxy-Connection)

Some proxy software — especially HTTP/HTTPS-forwarding proxies like Squid
— adds or forwards headers that directly announce an intermediary is
involved. If a destination server sees `X-Forwarded-For`, `Via`, or
`Proxy-Connection`, that's direct proof of a proxy, independent of
anything IP-related.

**How to check**: fetch an endpoint that echoes back the exact headers it
received, e.g. `https://httpbin.org/headers`, through the tunnel.

**In this deployment**: verified clean — only `Accept`, `Host`, and
`User-Agent` arrive at the destination, nothing proxy-revealing. This is
architectural, not a configuration choice that could regress: this setup
is a SOCKS5 tunnel at the TCP/IP layer, not an HTTP-forwarding proxy, so
there's no HTTP proxy software in the path with headers to add or forward
in the first place.

### 6. TCP/IP (p0f) and TLS (JA3/JA4) fingerprinting

**TLS (JA3/JA4)**: checked directly against `https://tls.peet.ws/api/all`
in the actual Chrome browser going through the tunnel. The JA3/JA4 hash,
cipher list, extension order, and GREASE/ECH/post-quantum key-share
details all matched a completely genuine, current Chrome — because a
SOCKS5 proxy relays raw TCP bytes without terminating or re-negotiating
TLS itself, the ClientHello a destination server sees is byte-for-byte
what the browser generated. There is no "proxy's TLS fingerprint" that
could give this away, structurally, as long as the proxy stays SOCKS5
(not an HTTPS-intercepting/MITM proxy, which would generate its own
ClientHello and fail this check).

**TCP/IP (p0f — TTL, window size, MSS, option order)**: same check showed
the actual TCP SYN packet reaching the destination has a *source IP* of
the proxy's exit IP, not the VM's or the host PC's — meaning the
TCP/IP-level fingerprint a destination sees is the **proxy provider's own
server's** network stack, not anything on this LAN. This is inherent to
how SOCKS5 (or any real proxy) works — the proxy opens its own new TCP
connection to the destination — and isn't something configurable from
this side at all. It's worth knowing this is a Decodo-side characteristic
if it ever becomes suspicious-looking (e.g. if an exit node's TCP
fingerprint doesn't look like a normal consumer OS), since the fix there
would be asking the provider or switching exit IPs again, not changing
anything in this repo.

## What's not realistically fixable here

Beyond the above, there are fingerprinting signals this kind of
network-layer setup fundamentally can't address: TLS/JA3 fingerprint,
canvas/WebGL rendering fingerprint, installed fonts, browser/extension
inventory, and general behavioral fingerprinting. These don't depend on
the IP at all. If a service is determined to flag a *browser* as
automated/suspicious independent of its IP, no amount of proxy/VM/router
configuration fixes that — it would need a different, browser-fingerprint
focused tool, which is a different problem than this repo solves.
