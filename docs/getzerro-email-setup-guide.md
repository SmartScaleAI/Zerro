# Setting up a getzerro.app mailbox on your existing Google Workspace

This adds **getzerro.app** as a *secondary domain* to your current Workspace (the one on smartaiscaling.com) and creates a mailbox for your marketing hire at `name@getzerro.app`. No second subscription — you only pay for her one user seat.

**Before you start, you'll need:**

- Super administrator access to the Workspace (admin.google.com)
- Access to getzerro.app's DNS settings at whatever registrar/host it's on (GoDaddy, Cloudflare, Namecheap, Squarespace, etc.)
- About 30 minutes of active work, plus waiting time for DNS to propagate

Total wall-clock time is a day or two, because DMARC should only be switched on after SPF and DKIM have been authenticating for ~48 hours. She can start using the mailbox well before that; the authentication steps are what protect deliverability once she starts sending marketing email.

---

## Part 1 — Add getzerro.app as a secondary domain

1. Go to **admin.google.com** and sign in with a super-admin account.
2. In the left menu: **Account → Domains → Manage domains**.
3. Click **Add a domain**.
4. Enter `getzerro.app`.
5. For domain type, choose **Secondary domain** — *not* "User alias domain."
   - **Secondary domain** = you can create separate users with their own `@getzerro.app` addresses. This is what you want.
   - **Alias domain** = every existing smartaiscaling.com user automatically also gets a `@getzerro.app` address (mirrors your current users). Not what you want here.
6. Click **Add domain & start verification**.

## Part 2 — Verify you own the domain

1. Google will show you a **TXT record** to prove ownership.
2. In a separate tab, open getzerro.app's DNS settings at your registrar.
3. Add the TXT record exactly as Google provides it (host/name is usually `@` or blank for the root domain).
4. Save at the registrar, return to the Admin console, and click **Verify**.
   - Propagation is usually minutes but can take a few hours. If it fails the first time, wait and retry.

## Part 3 — Turn on Gmail for the new domain (MX records)

For getzerro.app to *receive* mail, add Google's mail (MX) record at the registrar:

| Type | Host/Name | Value | Priority |
|------|-----------|-------|----------|
| MX | `@` (root) | `smtp.google.com` | 1 |

That single MX record is Google's current standard for new domains. (If your DNS host won't accept it, the older five-record set — ASPMX.L.GOOGLE.COM plus the ALT1–ALT4 servers — also works.) Delete any pre-existing MX records for getzerro.app so mail isn't split.

## Part 4 — Set up email authentication (do this before she sends marketing)

A brand-new domain has zero sending reputation, and Google/Yahoo now require SPF + DKIM + DMARC for anyone sending in volume. Set all three up.

**SPF** — add one TXT record at the registrar:

| Type | Host/Name | Value |
|------|-----------|-------|
| TXT | `@` (root) | `v=spf1 include:_spf.google.com ~all` |

**DKIM** — generate the key inside Workspace:

1. Admin console: **Apps → Google Workspace → Gmail → Authenticate email**.
2. Select **getzerro.app** from the domain dropdown.
3. Click **Generate new record** (choose the 2048-bit key; prefix `google`).
4. Copy the TXT record it gives you and add it at your registrar (host is usually `google._domainkey`).
5. Wait up to ~1 hour, then come back and click **Start authentication**.

**DMARC** — only after SPF and DKIM have been live and passing for ~48 hours, add a TXT record:

| Type | Host/Name | Value |
|------|-----------|-------|
| TXT | `_dmarc` | `v=DMARC1; p=none; rua=mailto:dmarc@getzerro.app` |

Start with `p=none` (monitor only) so you can watch the reports without risking legitimate mail being blocked. Once you've confirmed everything authenticates cleanly for a couple of weeks, you can tighten to `p=quarantine` and later `p=reject`.

## Part 5 — Create her mailbox

1. Admin console: **Directory → Users → Add new user**.
2. Enter her first and last name.
3. For the primary email, type the username and **select `getzerro.app`** from the domain dropdown (e.g. `marketing@getzerro.app` or `firstname@getzerro.app`).
4. Set a temporary password (or auto-generate) and finish creating the account.
5. Send her the login details. She signs in at **mail.google.com** and gets a normal Gmail inbox on the getzerro.app address.

Optional: if you ever want her to also receive mail at a smartaiscaling.com address, you can add that as an alias on her account later (**Users → her name → Add alternate emails**).

---

## Quick verification checklist

- [ ] getzerro.app shows **Verified** under Manage domains
- [ ] MX record points to Google; a test email sent *to* her address arrives
- [ ] SPF, DKIM show **Authenticating** in the Gmail settings
- [ ] A test email *from* her address passes SPF/DKIM (check "Show original" in a received Gmail — look for `PASS`)
- [ ] DMARC record added after 48h and reports look clean before tightening the policy

## Warm-up note

Don't send a large marketing blast on day one from a fresh domain. Have her send normal one-to-one email for a week or two first, then ramp volume gradually. This builds sending reputation and keeps getzerro.app out of spam filters.

## One .app-specific note

The `.app` TLD is on the HSTS preload list, so **any website** on getzerro.app must be served over HTTPS. This has no effect on email — it only matters if/when you host the marketing site on that domain.
