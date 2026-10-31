# Legal and responsible use

This repo is **infrastructure configuration and documentation** — router
rules, a systemd service definition, scripts. It doesn't provide a proxy,
doesn't operate any network, and doesn't collect or transmit anything on
its own. Using it still means you're responsible for three separate sets
of terms, none of which this repo can satisfy for you.

## 1. Your proxy provider's terms of service

A SOCKS5/residential/ISP proxy service is a commercial product with its
own acceptable-use policy. Providers commonly prohibit things like:
credential stuffing or brute-forcing, large-scale unauthorized scraping,
spamming or abuse, circumventing another service's anti-fraud/security
controls, and reselling or exceeding the plan's device/bandwidth limits.
**Read your specific provider's AUP and stay inside it** — this repo
making the proxy transparent to every device on a LAN doesn't change what
you're allowed to do through it.

## 2. The terms of whatever you connect to

Changing your apparent exit IP doesn't exempt you from the terms of
service of the sites and apps you reach through it. Many services
(streaming platforms, banks, social platforms) explicitly prohibit VPN/
proxy use in their ToS, independent of whether doing so is illegal in
your jurisdiction. Expect that some services will detect and block this
regardless (see [DETECTION.md](DETECTION.md)), and that using it to evade
such a block may violate that service's terms even when no law is broken.
That's a contract matter between you and that service, not something this
project resolves.

## 3. The law in your jurisdiction

Using a proxy or VPN is legal in most countries, but **not all** — some
jurisdictions restrict or require licensing for this kind of traffic
redirection. You are responsible for knowing and following the law where
you live and where your traffic exits. This project is published for
lawful, personal/home-network use (the kind of use documented throughout
this repo: a stable exit IP for your own household's devices). It is
explicitly **not** intended for, and must not be used for: evading
sanctions, unauthorized access to systems you don't own or have permission
to test, fraud, harassment, or any other illegal activity. Nothing here
grants permission to do any of that, and the authors take no
responsibility for uses outside what's documented.

## Privacy note: who can see what

This setup changes what the **destination** sees (your exit IP), not what
your **proxy provider** sees. The provider's infrastructure is a real
intermediary for all of this traffic — it can see destination
hosts/SNI for everything, and the full plaintext content of anything not
itself end-to-end encrypted (most modern web traffic is HTTPS, so this is
usually limited to metadata, but don't assume it for every connection).
Choosing a reputable provider with its own clear privacy policy matters
for this reason — this repo's kill switch and DNS-leak fix protect you
from leaking to your *local* ISP, not from your *proxy provider's*
visibility into the traffic it's relaying.

If this is deployed on a shared household/office network, other people's
traffic goes through the same proxy provider as a consequence of the
network-wide design — consider whether the people on that network should
know that.

## No warranty

Licensed under MIT (see [LICENSE](../LICENSE)) — provided as-is, with no
warranty of any kind, including fitness for a particular purpose. The
failure modes, timing numbers, and detection findings throughout these
docs reflect one real deployment at one point in time; your router
firmware version, proxy provider, and local network will differ. Verify
behavior on your own setup, especially the kill switch, before relying on
it for anything where a leak would matter.
