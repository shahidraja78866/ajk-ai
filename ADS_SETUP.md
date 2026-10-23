# AJK AI — Advertising setup (Google AdMob)

Ads in AJK AI are served by **Google AdMob** into the **owner's own AdMob
account** — all ad revenue is Google's contract with the owner, paid to the
owner's verified bank account. Nothing about ads works until the owner's
accounts exist; the code shipped in this repo is **preparation only** and is
inert (fail-closed) until then.

## Policy (already implemented)

- Ads are shown to **free-tier users only**. Any active paid plan
  (Weekly / Normal / Pro / Extra Pro) is **ad-free** — this is also a
  selling point for subscriptions.
- **No ads** on the admin panel, the Buy Credits / payment screens, the
  login screens, or the privacy page.
- Web placements prepared: `studio_bottom` and `home_native` (empty,
  hidden slot containers in `public/index.html`). They render **nothing**
  unless ads are enabled server-side **and** the signed-in user is a
  free-tier, non-admin user — and even then they show only a neutral
  "Advertisement" placeholder on the web. Real ad rendering (banner,
  native, interstitial, rewarded) arrives with the **Android app build**
  and the AdMob SDK; there are deliberately **no** ad-network scripts or
  AdSense tags in the web app.
- Server config (environment only — never in code, never in chat):

  | Variable | Meaning |
  |---|---|
  | `ADS_ENABLED` | Master switch. Must be exactly `1` for ads to be reported enabled. Default off. |
  | `ADMOB_PUBLISHER_ID` | The owner's AdMob publisher id, format `pub-` + 16 digits. Anything else is treated as "not configured". |
  | `ADMOB_APP_ADS_TXT` | Optional. A full custom app-ads.txt line, served verbatim at `/app-ads.txt` instead of the generated snippet. |

  `GET /api/config` exposes an `ads` block (`enabled`, `configured`,
  `provider`, `free_tier_only`, `placements`, `note`) — flags only, never
  the publisher id. `GET /app-ads.txt` serves
  `google.com, pub-XXXXXXXXXXXXXXXX, DIRECT, f08c47fec0942fa0` (or the
  override) when configured, and **404** otherwise.

## Owner checklist — in this order

Only the owner can do these steps: they involve his own Google account,
identity documents, postal address and bank account.

1. **Create the AdMob account** at admob.google.com with the owner's own
   Google account. Complete the account information and add **payment
   details** (name, individual/organization, payment address). The
   account is not ready for monetization — and the app will not be
   reviewed — until payment information is present.
2. **Verify identity and address.** When earnings reach the verification
   threshold (US$10 equivalent), Google requires identity verification,
   then mails a **PIN** to the payment address; enter the PIN in AdMob to
   verify the address. No PIN = no payouts.
3. **Publish the app on Google Play first.** An Android app must be
   **publicly available** in a supported store before it can be linked to
   AdMob, and app-ads.txt verification reads the developer website from
   the store listing. (This is the Play Developer account + closed-testing
   path already tracked for AJK AI — ads come after it, not before.)
4. **Link the app in AdMob and pass the readiness review.** In AdMob:
   Apps → Add app → Android → "Yes, it's listed on a supported app
   store", then link the Play listing. All new apps undergo an **app
   readiness review** before they can fully serve ads.
5. **Create the ad units** in AdMob for the placements (banner/native for
   `home_native` and `studio_bottom`; interstitial/rewarded units only if
   the Android phase adds them). Then set the values as **Render
   environment variables** on the backend service — `ADMOB_PUBLISHER_ID`
   first, `ADS_ENABLED=1` last — and redeploy. The publisher id and unit
   ids are set via env, **never** pasted into code, files, or chat.
6. **Verify app-ads.txt in AdMob.** After the deploy, open
   `https://ajk-ai.onrender.com/app-ads.txt` and confirm it shows the
   google.com line with the owner's publisher id, then check the
   app-ads.txt status page in AdMob (Apps → app-ads.txt). Allow at least
   24 hours for Google to crawl and verify it. The domain in the Play
   listing's developer-website field must match the domain serving the
   file.
7. **Payouts.** AdMob pays **monthly, on or around the 21st**, only when
   the finalized balance has crossed the **US$100 payment threshold**
   (balances below it roll over to the next month), and only to the
   owner's **verified bank account** via the payment method selected in
   the AdMob payments profile. Reaching US$10 first triggers the identity
   + address-PIN verification in step 2 — do it as soon as it is offered,
   not when the first $100 is due.

## Invalid-traffic rules (account-ending if broken)

- **Never click your own ads**, and never ask friends, family or users to
  click ads. Clicks must come from genuine user interest only.
- **No incentivized clicks**: never offer credits, rewards or unlocks in
  exchange for clicking an ad, and never word a button or label so it
  tricks users into tapping an ad (no accidental-click engineering).
- **Keep ads away from buttons**: ad units must not sit next to, under,
  or overlapping the Generate button or other controls where users
  routinely tap — accidental clicks are invalid traffic even without
  intent.
- Invalid traffic can get the AdMob account limited or permanently
  disabled, and earnings clawed back. When in doubt, fewer, clearly
  separated placements beat clever ones.

## EEA / UK consent (Android phase)

When the Android app ships with the AdMob SDK, users in the EEA/UK must
be shown a consent flow (Google's **User Messaging Platform — UMP**) and
ads must respect the consent state (personalized vs. non-personalized)
before ad requests are made. This is part of the Android integration
phase, not the web groundwork; a certified consent management platform
message is created in the AdMob console (Privacy & messaging) at that
time.

## Go-live sequence (summary)

AdMob account + payments → identity/PIN verification → Play publishing →
link app + readiness review → ad units → set Render env
(`ADMOB_PUBLISHER_ID`, then `ADS_ENABLED=1`) → verify app-ads.txt status
in AdMob → ads live for free-tier users; paid plans stay ad-free.
