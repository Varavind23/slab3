# Auth email through a Google account

Supabase Auth sends its own transactional mail — signup confirmation, password
reset, email-change confirmation. By default that goes through Supabase's shared
sender, which is rate-limited and comes from an address that is not ours. This
points it at a business Google Workspace account instead.

**Decided 2026-09-03.** Consumer Gmail + app password for now; the Workspace
relay is the upgrade once there is a domain. See "Which Google account" below.

---

## Read this first: today, nothing would send

Configuring SMTP on its own produces **no user-visible email**, because nothing
in the product currently asks Auth to send one:

| Email | Sends today? | Why |
|---|---|---|
| Signup confirmation | **No** | `enable_confirmations = false` in `config.toml` |
| Password reset | **No** | the app never calls `resetPasswordForEmail` — `AuthScreen` has log in / sign up and no "forgot password" |
| Email change | No | the app has no change-email screen |

So SMTP is the plumbing; at least one of these has to be turned on for a user to
receive anything. Each is a product decision, not a config one:

* **Signup confirmation** changes the sign-up flow — a new user cannot sign in
  until they click the link. That is a real gate on the first run of the app.
* **Password reset** needs a screen and a deep link back into the app
  (`additional_redirect_urls` must include the app's URL scheme).

Verify the plumbing with the smoke test below regardless; it does not depend on
either being enabled.

## Which Google account

Google has two ways in and they are NOT interchangeable — the relay is a
Workspace feature and a consumer account cannot reach it.

### Consumer Gmail + app password — what we use now

`smtp.gmail.com:587`, authenticated as the account itself.

* **Sends AS that address.** Gmail rewrites the From header to the authenticated
  account, so mail arrives from `<the-account>@gmail.com`. There is no way to send
  as `noreply@<domain>` from a consumer account; a "Send mail as" alias only works
  for an address you have already verified, which needs a domain anyway.
* **~500 messages/day**, with throttling above that. Not a constraint at
  TestFlight scale; it would become one with real user volume.
* **No DNS work.** Google signs its own domain, so SPF/DKIM/DMARC pass without us
  publishing anything. The DNS section below applies ONLY to a custom domain.
* Requires **2-Step Verification** on the account, then an **app password**
  (Google Account → Security → App passwords). The app password is the SMTP
  password; the full Gmail address is the SMTP username.

### Workspace SMTP relay — the upgrade path

`smtp-relay.gmail.com`, once there is a Workspace domain. Worth moving to when
the From address starts mattering more than the setup cost: it sends as **any
address in the domain** (`noreply@…`) and lifts the daily cap well above a
mailbox's. It needs a Workspace admin to enable the service, and it should
authenticate with **SMTP AUTH, not the IP allowlist** — Supabase's hosted egress
addresses are not static or published, so an allowlist would work until Supabase
moved hosts and then fail with no change of ours to blame it on.

Everything below is written for the consumer-Gmail path; the Workspace steps are
kept in the admin section for when it is time.

## 1a. Workspace admin — ONLY for the relay upgrade, skip for consumer Gmail

Admin console → **Apps → Google Workspace → Gmail → Routing → SMTP relay
service** → Add:

| Field | Value |
|---|---|
| Allowed senders | **Any address in my domains** (lets us send as `noreply@…`) |
| Authentication | tick **Require SMTP Authentication** (leave IP allowlist off — see above) |
| Encryption | tick **Require TLS encryption** |

Then create the account whose credentials the relay authenticates with — a
dedicated Workspace user, not a person's login, so rotating it never locks
someone out of their mail. Give it 2-step verification, then an **app password**
(Google Account → Security → App passwords). The app password is the SMTP
password; the user's full email address is the SMTP username.

## 2. DNS — ONLY for a custom domain, skip for consumer Gmail

Sending from `@gmail.com` needs none of this: Google publishes and signs its own
records, so SPF/DKIM/DMARC already pass. This applies the day mail moves to a
domain we own.

### The records

On the sending domain:

* **SPF** — one TXT at the root including Google:
  `v=spf1 include:_spf.google.com ~all`
  (If a TXT with `v=spf1` already exists, ADD the include to it. Two SPF records
  is itself an SPF failure.)
* **DKIM** — Admin console → Apps → Google Workspace → Gmail → Authenticate
  email → Generate new record → publish the TXT it gives → Start authentication.
* **DMARC** — a TXT at `_dmarc.<domain>`, starting permissive:
  `v=DMARC1; p=none; rua=mailto:dmarc@<domain>`
  Tighten to `p=quarantine` once the reports show our own mail passing.

## 3. Supabase (hosted)

Dashboard → **Project Settings → Authentication → SMTP Settings** → Enable:

| Field | Value |
|---|---|
| Host | `smtp.gmail.com` (relay: `smtp-relay.gmail.com`) |
| Port | `587` (STARTTLS) |
| Username | the full Gmail address |
| Password | its **app password** — NOT the account password |
| Sender email | **the same Gmail address.** Gmail rewrites From to the authenticated account, so anything else here is silently ignored and looks like a bug later |
| Sender name | `Slabs` |

Then raise **Auth → Rate Limits → emails per hour**, which is deliberately tiny
while the shared sender is in use and is what the relay exists to lift.

**Local development does NOT use this.** `supabase start` runs Mailpit at
http://127.0.0.1:54324 and catches every message, so local auth mail is readable
without credentials and without sending anything real. Do not enable
`[auth.email.smtp]` in `config.toml` — that would push local dev onto the live
relay and require the app password on every developer's machine.

## 4. Smoke test

With SMTP saved, and using an address you can read:

```sh
# Password recovery is the cheapest path that forces Auth to send mail, and it
# works whether or not confirmations are enabled.
curl -s -X POST "https://rrkvlrtohmylhslpzuvz.supabase.co/auth/v1/recover" \
  -H "apikey: <anon key from ios/Slab3/Backend/Backend.swift>" \
  -H 'Content-Type: application/json' \
  -d '{"email":"you@example.com"}' -w '\nHTTP %{http_code}\n'
```

`200` means Auth accepted it; the mail itself proves the relay. Check:

1. It **arrives** (relay + credentials are right).
2. It is **from the Gmail address** — expected on this path, and the reason to
   move to the relay later.
3. Gmail's **Show original** reports `SPF: PASS`, `DKIM: PASS` (Google's own, on
   the consumer path).
4. It is **not in spam**.

If Auth returns 200 and no mail arrives, the failure is between Supabase and
Google: check Dashboard → Logs → Auth for the SMTP error, which names the reason
(`535` = bad credentials, usually the account password used instead of an app
password, or 2-Step Verification not enabled; `550` relay denied = sender address
does not match the authenticated account).
