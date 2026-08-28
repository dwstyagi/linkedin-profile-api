# LinkedIn Profile API

A hosted HTTP API that accepts a LinkedIn profile URL and returns the profile as structured JSON.

It works by calling LinkedIn's own internal **Voyager** API — the endpoints the linkedin.com web app calls behind the scenes — authenticated with a session cookie supplied through the environment.

> **No browser is involved.** The running service makes plain HTTP requests to LinkedIn and nothing else. There is no headless Chrome, no Playwright, no Selenium, no automation driver anywhere in the dependency tree. The session cookie is obtained by hand once during setup and supplied as an environment variable.

---

## Contents

- [Quick start](#quick-start)
- [Obtaining a LinkedIn session](#obtaining-a-linkedin-session)
- [API reference](#api-reference)
- [Response schema](#response-schema)
- [How it works](#how-it-works)
- [Protecting the session](#protecting-the-session)
- [Recon tooling](#recon-tooling)
- [Testing](#testing)
- [Deployment](#deployment)
- [Configuration](#configuration)
- [Known limitations](#known-limitations)
- [Legal note](#legal-note)

---

## Quick start

Requires Ruby 4.0, Rails 8.1 and PostgreSQL.

```bash
bundle install
cp .env.example .env       # then fill in the values, see below
bin/rails db:prepare
bin/rails server
```

```bash
curl -H "X-API-Key: $API_KEY" \
  "http://localhost:3000/api/v1/profile?url=https://www.linkedin.com/in/some-person"
```

The API can also be demoed with no LinkedIn credentials at all — `bin/rails db:seed` loads one profile straight into the cache.

---

## Obtaining a LinkedIn session

There is no login code in this service, by design. Automating a LinkedIn login triggers CAPTCHAs, email verification and device confirmation, none of which a headless service can clear.

Instead the session is harvested once, by hand. Copy the **entire cookie header** from a real request rather than picking individual cookies out of the Cookies panel — that panel truncates long values, and `li_at` is long enough to be clipped:

1. Log into LinkedIn in a normal browser.
2. DevTools → **Network** → reload the page → right-click the first `www.linkedin.com` request → **Copy → Copy as cURL**.
3. From the pasted command, take the string inside `-b '...'`.
4. Put it in `.env` as `LINKEDIN_COOKIE`, on one line.

`LINKEDIN_LI_AT` and `LINKEDIN_JSESSIONID` are supported as an alternative, but the full header is more reliable: it carries `bcookie`, `bscookie` and `lidc`, whose absence makes LinkedIn redirect API calls back to themselves.

The client deliberately strips `li_g_recent_logout` before sending. It is the flag LinkedIn sets when a browser signs out, it is routinely present in a copied header, and replaying it next to a live session tells LinkedIn the session should not exist.

**Use a secondary LinkedIn account if you can.** Automated Voyager traffic can get an account restricted. Note the tradeoff, though: brand-new accounts are scrutinised much harder than aged ones, and in testing a freshly created account had its session invalidated within a dozen requests where an established account did not.

When the cookie dies, every request returns `503 linkedin_session_expired` and `GET /api/v1/health` reports the session as `expired`. Repeat the steps above and update the secret; no code deploy is needed.

---

## API reference

All endpoints except `/` and `/up` require an API key:

```
X-API-Key: <your key>
```

### `GET /api/v1/profile`

| Parameter | Required | Description |
| --- | --- | --- |
| `url` | yes | A LinkedIn member profile URL. Tracking parameters, missing scheme, trailing slashes and regional subdomains (`in.linkedin.com`) are all accepted. |
| `refresh` | no | `true` bypasses the cache and forces a fresh fetch. |

### `GET /api/v1/health`

Reports whether the session still authenticates and how much of the day's request budget is left. Costs one upstream request, so it sits behind the API key. Returns `503` when the session is dead.

```json
{
  "data": {
    "linkedin_session": "active",
    "cached_profiles": 12,
    "requests_today": 24,
    "requests_remaining_today": 76,
    "failures_today": 0
  }
}
```

### `GET /up`

Unauthenticated platform health check. Says nothing about LinkedIn.

### Errors

Every error has the same shape:

```json
{ "error": { "code": "profile_not_found", "message": "..." } }
```

| Status | Code | Meaning |
| --- | --- | --- |
| 401 | `unauthorized` | Missing or wrong `X-API-Key`. |
| 404 | `profile_not_found` | No such member, or the session cannot see them. |
| 422 | `invalid_url` | Not a `linkedin.com/in/...` member profile URL. |
| 429 | `rate_limited` | Either the inbound throttle, the daily outbound budget, or LinkedIn throttling us. Honours `Retry-After`. |
| 502 | `upstream_error` | LinkedIn returned something unexpected, was unreachable, or has retired the endpoint (HTTP 410). |
| 503 | `linkedin_session_expired` | The cookie is missing, invalid, challenged, or was cleared by LinkedIn. **An operator problem, not a caller problem** — which is why it is not a 401. |

---

## Response schema

The schema is this project's own design. Two guarantees:

1. **The key set is stable.** Absent data is `null` or `[]`, never a missing key.
2. **Every date is structured**, with a pre-rendered `text` field alongside the parts, so callers do not reimplement LinkedIn's partial-date handling.

```json
{
  "data": {
    "public_identifier": "ada-lovelace",
    "profile_url": "https://www.linkedin.com/in/ada-lovelace",
    "member_id": "99887766",
    "first_name": "Ada",
    "last_name": "Lovelace",
    "full_name": "Ada Lovelace",
    "headline": "Mathematician | Analytical Engine",
    "about": "Wrote the first algorithm intended for a machine.",
    "industry_urn": "urn:li:fsd_industry:4",
    "student": false,
    "verified": true,
    "location": {
      "name": null,
      "country_code": "gb",
      "postal_code": null,
      "geo_urn": "urn:li:fsd_geo:115918471"
    },
    "profile_picture": {
      "url": "https://media.licdn.com/dms/image/root/400_400/pic.jpg",
      "artifacts": [
        { "width": 100, "height": 100, "url": "https://media.licdn.com/dms/image/root/100_100/pic.jpg" },
        { "width": 400, "height": 400, "url": "https://media.licdn.com/dms/image/root/400_400/pic.jpg" }
      ]
    },
    "background_image": { "url": "...", "artifacts": [] },
    "experience": [
      {
        "title": "Analyst",
        "company_name": "Analytical Engine Co",
        "company_urn": "urn:li:fsd_company:1",
        "employment_type_urn": "urn:li:fsd_employmentType:12",
        "location": "London",
        "description": "Notes on the Analytical Engine.",
        "date_range": {
          "start": { "year": 1842, "month": 6, "day": null, "text": "June 1842" },
          "end": null,
          "current": true
        }
      }
    ],
    "education": [
      {
        "school_name": "Private Tutoring",
        "school_urn": "urn:li:fsd_school:1",
        "degree_name": "Mathematics",
        "field_of_study": "Mathematics",
        "grade": "A",
        "activities": null,
        "description": null,
        "date_range": {
          "start": { "year": 1832, "month": null, "day": null, "text": "1832" },
          "end": { "year": 1835, "month": null, "day": null, "text": "1835" },
          "current": false
        }
      }
    ],
    "skills": ["Mathematics", "Algorithms"],
    "certifications": [
      {
        "name": "Certificate of Merit",
        "authority": "Royal Society",
        "license_number": null,
        "url": "https://example.com/cert",
        "company_urn": null,
        "date_range": { "start": null, "end": null, "current": false }
      }
    ],
    "languages": [{ "name": "English", "proficiency": "NATIVE_OR_BILINGUAL" }]
  },
  "meta": {
    "cached": false,
    "fetched_at": "2026-08-28T05:10:00Z",
    "source": "linkedin_voyager"
  }
}
```

### Images

LinkedIn returns images as a *vector image*: a root URL plus size artifacts whose path segments are appended to it. This API does the joining and returns every rendition — largest as `url`, all sizes in `artifacts` — so a caller can pick a thumbnail without another round trip. Note that the signed URLs carry an expiry, so they are not durable references.

---

## How it works

### The endpoint problem

The obvious target, `identity/profiles/<slug>/profileView`, returned an entire profile in one call. **LinkedIn has retired it — it now answers HTTP 410 Gone**, as do `identity/profiles/<slug>`, `.../profileContactInfo`, `.../educations` and `.../skills`.

What replaced it is the `identity/dash/*` family: per-section finders keyed by the profile's URN rather than its public slug, returning Rest.li's *normalized* form (a flat `included` array of typed entities) when asked for with:

```
accept: application/vnd.linkedin.normalized+json+2.1
```

So a fetch is two stages, and six requests:

| Step | Endpoint | Yields |
| --- | --- | --- |
| 1 | `identity/dash/profiles?q=memberIdentity&memberIdentity=<slug>` | identity fields **and** the `urn:li:fsd_profile:...` URN |
| 2 | `identity/dash/profilePositions?q=viewee&profileUrn=<urn>` | experience |
| 3 | `identity/dash/profileEducations?q=viewee&profileUrn=<urn>` | education |
| 4 | `identity/dash/profileSkills?q=viewee&profileUrn=<urn>` | skills |
| 5 | `identity/dash/profileCertifications?q=viewee&profileUrn=<urn>` | certifications |
| 6 | `identity/dash/profileLanguages?q=viewee&profileUrn=<urn>` | languages |

A section that 404s or has been retired costs that section, not the whole profile. Session and rate-limit failures are fatal and propagate.

### Request flow

```
GET /api/v1/profile?url=...
  │
  ├─ Rack::Attack          throttle by API key (or IP)
  ├─ authenticate!         X-API-Key, constant-time compare      → 401
  ├─ ProfileUrl.parse      slug extraction + validation          → 422
  ├─ CachedProfile.fresh   cache hit? serve it, no network       → 200 (cached: true)
  ├─ RequestBudget         daily ceiling + spacing               → 429
  ├─ ProfileFetcher        1 + 5 requests to identity/dash/*     → 404 / 429 / 502 / 503
  ├─ ProfileNormalizer     included[] entities → our schema
  └─ CachedProfile.store!  persist normalized + raw              → 200 (cached: false)
```

Validation and the cache lookup both happen **before** any network call, so malformed input and repeat requests never cost an upstream request.

### Session handling

The client keeps a **cookie jar** rather than replaying a fixed string. `lidc` is a routing cookie carrying an expiry timestamp; once stale, LinkedIn answers with a redirect back to the same URL plus a `Set-Cookie` carrying a fresh one. A client that replays a fixed header works until it abruptly doesn't. So the client absorbs `Set-Cookie`, follows the redirect, and replays the original request.

One distinction matters: a redirect that *also* expires `li_at` is a rejection, not a refresh, and is reported as `503` immediately rather than retried. A revoked cookie is never written back into the jar.

Three headers are easy to get wrong:

- `csrf-token` must equal the `JSESSIONID` value **without** quotes, while the cookie keeps them. A mismatch produces a 401 that looks exactly like an expired cookie.
- `x-restli-protocol-version: 2.0.0` selects the protocol these endpoints expect.
- `x-li-track` carries the web client's version and device fingerprint. Its absence is one of the clearer signals that a request did not come from the LinkedIn app.

### Why cache, and why it is not co-located

The cache exists to protect the session, not to save milliseconds — each hit is six fewer requests against LinkedIn. Both the normalized document **and** the raw payloads are stored, so when LinkedIn changes shape the normalizer can be reworked and re-run against saved data offline, without spending fresh requests to debug.

The database is deliberately not co-located with the application. The deployed instance is ephemeral — no persistent disk, recycled on redeploy — so anything stored beside the app would be lost regularly. For the cache alone that would only mean wasted requests, but the `linked_in_requests` table is also the counter behind the daily outbound budget, and a rate limiter that resets whenever the container restarts does not limit anything. Managed Postgres keeps both durable.

### Layout

| Path | Responsibility |
| --- | --- |
| `app/services/linked_in.rb` | Namespace and error classes. |
| `app/services/linked_in/profile_url.rb` | URL → slug, with validation. |
| `app/services/linked_in/client.rb` | HTTP, cookie jar, redirects, status → error mapping. |
| `app/services/linked_in/request_budget.rb` | Outbound spacing and daily ceiling. |
| `app/services/linked_in/profile_fetcher.rb` | Which endpoints to call, and in what order. |
| `app/services/linked_in/profile_normalizer.rb` | `included[]` entities → published schema. |
| `app/services/linked_in/profile_service.rb` | Orchestration: validate, cache, fetch, store. |
| `app/models/linked_in_request.rb` | Append-only log of every upstream call. |

---

## Protecting the session

Two independent limiters, pointing in opposite directions.

**Inbound** (`Rack::Attack`) caps callers of this API, keyed by API key and falling back to IP.

**Outbound** (`LinkedIn::RequestBudget`) caps this API's calls to LinkedIn:

- a **minimum interval** between consecutive calls, with jitter, so traffic never arrives in the tight bursts that automated access looks like;
- a **daily ceiling**, so a runaway loop cannot spend the account in an afternoon.

Every upstream call is logged to `linked_in_requests` with its path, status and outcome. That table is both the counter behind the limiter and the evidence trail for how the session is holding up — it is what lets you answer "how many profiles can we actually fetch, and when did LinkedIn start refusing?"

```bash
bin/rails runner 'puts LinkedInRequest.today.group(:outcome).count.inspect'
```

The spacing is the dominant term in uncached latency: at six requests per profile, a 2.0s interval means roughly 13 seconds for a cache miss. Lower `LINKEDIN_MIN_REQUEST_INTERVAL` for a snappier demo, raise it to be gentler on the account.

---

## Recon tooling

Three rake tasks support working on the mapping without burning requests.

Call any endpoint and inspect the result — this is how the `dash` family above was found:

```bash
bin/rails "linkedin:probe[identity/dash/profileSkills?q=viewee&profileUrn=urn:li:fsd_profile:XXXX]"
```

Fetch a full profile and save every raw payload to `tmp/recon/` (gitignored — it holds real profile data):

```bash
bin/rails "linkedin:recon[https://www.linkedin.com/in/some-person]"
```

Re-run the normalizer against a saved payload and print a coverage report of which sections came through populated:

```bash
bin/rails "linkedin:normalize[tmp/recon/some-person.json]"
```

---

## Testing

```bash
bin/rails test
```

Twenty tests, needing no LinkedIn session: the fetcher is swapped for a double and normalization runs against a checked-in fixture in the real `dash` shape. Coverage focuses on what actually breaks — URL parsing edge cases, image URL assembly, ongoing-versus-past date ranges, the string-`"true"` booleans this format returns, sparse profiles, unavailable sections, cache hit and bypass, and the mapping from upstream failures to status codes.

`bin/ci` additionally runs RuboCop, Brakeman and a gem audit.

---

## Deployment

Deployed on Render from the Rails 8 Dockerfile, with Postgres hosted separately on Neon.

The split is deliberate. Render's free instances have no persistent disk and are recycled on redeploy, so a database co-located with the app would lose its contents regularly. That matters more here than it usually would: the profile cache and the outbound request log are what keep this service from over-calling LinkedIn, and a rate limiter whose counter resets on every restart is decorative. Pointing `DATABASE_URL` at managed Postgres keeps both intact.

**1. Database.** Create a free Postgres instance on [Neon](https://neon.tech) in the region nearest the app, and copy its connection string.

**2. Service.** Connect this repository to Render. [`render.yaml`](render.yaml) declares the service, so Render picks up the runtime, region, health check path and non-secret configuration automatically.

**3. Secrets.** Set these in the Render dashboard — they are marked `sync: false` in the blueprint and never live in the repository:

| Variable | Value |
| --- | --- |
| `DATABASE_URL` | Neon connection string |
| `RAILS_MASTER_KEY` | contents of `config/master.key` |
| `API_KEY` | a generated key; callers send it as `X-API-Key` |
| `LINKEDIN_COOKIE` | full cookie header from a logged-in browser |
| `LINKEDIN_USER_AGENT` | the user agent of that same browser |

The container's entrypoint runs `db:prepare` on boot, so migrations apply and the demo profile seeds on first deploy without a release step.

### A note on the free tier

Render spins a free service down after 15 minutes without traffic, and waking it takes around a minute. The free allowance is 750 instance hours per calendar month, which is just above the ~730 hours in a month — so an uptime monitor pinging `/up` every few minutes keeps the service warm and stays inside the allowance, at the cost of leaving no room for a second free service on the same account.

If you are evaluating this and the first request hangs, that is the instance waking rather than the API failing. Subsequent requests are immediate.

No secret is stored in this repository. `.env` is gitignored; `.env.example` documents every variable with empty values.

---

## Configuration

| Variable | Default | Purpose |
| --- | --- | --- |
| `API_KEY` | — | Required. Clients present it as `X-API-Key`. |
| `LINKEDIN_COOKIE` | — | Full cookie header. Preferred; takes precedence over the two below. |
| `LINKEDIN_LI_AT` | — | Session cookie, if not using the full header. |
| `LINKEDIN_JSESSIONID` | — | Session cookie and CSRF token source. |
| `LINKEDIN_USER_AGENT` | a Chrome UA | Should match the browser the cookie came from. |
| `LINKEDIN_TRACK` | a desktop web fingerprint | The `x-li-track` header value. |
| `PROFILE_CACHE_TTL_SECONDS` | `86400` | How long a profile is served from cache. |
| `THROTTLE_REQUESTS_PER_MINUTE` | `30` | Inbound rate limit per API key. |
| `LINKEDIN_MIN_REQUEST_INTERVAL` | `2.0` | Seconds between outbound calls. |
| `LINKEDIN_DAILY_REQUEST_LIMIT` | `100` | Outbound calls per day (≈16 uncached profiles). |
| `LINKEDIN_OPEN_TIMEOUT` | `5` | Connect timeout, seconds. |
| `LINKEDIN_READ_TIMEOUT` | `15` | Read timeout, seconds. |

---

## Known limitations

**`location.name` comes back null; related fields are returned as URNs.** LinkedIn identifies locations, industries, companies and schools by internal identifiers (`urn:li:fsd_geo:...`, `urn:li:fsd_industry:...`) rather than display names. For most of these that is fine — the URN is a stable reference and is passed through as-is. Location is the one place it costs something, because the profile entity carries `geoLocation.geoUrn` and a country code but no readable string, so `location.name` is null while `country_code` and `geo_urn` are populated.

Resolving it would need either a `decorationId` on the profiles call or a separate geo lookup. I probed for a geo endpoint and did not find one that answered, and rather than ship a guessed endpoint that might break, I left the URN exposed so a caller can resolve it themselves. This is the one field from the brief's list that is not fully delivered.

**Six requests per profile.** The retirement of `profileView` removed the one-call option. Combined with the outbound spacing this makes an uncached fetch take ~13 seconds. The cache absorbs it for repeat lookups, but it is a real cost of the current endpoint layout.

**Session expiry is the main failure mode.** The cookie expires or is invalidated and the service returns `503` until it is replaced by hand. Inherent to the approach: automating login is exactly what LinkedIn's CAPTCHA and device-verification flows exist to prevent. `GET /api/v1/health` makes this diagnosable in one request.

**Data depends on the session's relationship to the target.** LinkedIn shows different amounts of a profile by network distance and privacy settings. Out-of-network profiles can come back thin or redacted. The same URL fetched with a different account can legitimately return different data.

**Endpoints are unversioned and undocumented.** LinkedIn rotates them without notice, as the 410s here demonstrate. Raw payloads are retained precisely so the normalizer can be rebuilt against saved data when that happens.

**Sections not implemented.** Volunteering, projects, publications, honours and courses have `dash` finders following the same pattern but were not mapped. Contact details (email, phone, websites) sit behind a separate endpoint and are usually withheld.

**No CAPTCHA or checkpoint handling.** If LinkedIn serves a challenge, the client detects the non-JSON response and reports the session as blocked. It does not attempt to solve it.

**Single instance.** The inbound rate-limit counters live in process memory, so they are accurate for one machine and would under-count across several. The cache and the outbound request budget are already in Postgres and would work unchanged; scaling horizontally would mean moving the inbound counters to a shared store, and nothing else.

---

## Legal note

This project calls LinkedIn's internal endpoints with a member's own session, which is contrary to LinkedIn's Terms of Service. It was built as a hiring exercise in reverse engineering, at low request volume, with deliberate rate limiting. It is not intended for production use, bulk collection, or resale of scraped data.
