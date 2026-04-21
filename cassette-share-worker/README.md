# Cassette Share Worker

Minimal Cloudflare Worker + KV backend for public cassette links.

## What it does

- `POST /cassette`
  Stores a cassette payload in KV and returns a short public URL.
- `GET /cassette/:id`
  Returns the stored cassette payload for the iOS app to load.
- `GET /c/:id`
  Serves a fallback landing page with an `Open in Cassette Swap` button.
- `GET /.well-known/apple-app-site-association`
  Serves the universal-link file once you set your Apple team and bundle ID.

## Why this is the low-overhead path

- One Worker
- One KV namespace
- No database
- No Durable Objects
- No list queries in the normal app path

That matches Cloudflare's current lowest-overhead path for this prototype shape.

## Current app contract

The iOS app sends the existing `CassettePayload` JSON directly to:

```text
POST /cassette
```

The Worker returns:

```json
{
  "id": "abc123XYZ0",
  "createdAt": "2026-04-21T20:00:00.000Z",
  "expiresInSeconds": 2592000,
  "shareUrl": "https://swap.yourdomain.com/c/abc123XYZ0",
  "openUrl": "cassette-swap://cassette?id=abc123XYZ0&base=https%3A%2F%2Fswap.yourdomain.com"
}
```

The iOS app fetches incoming cassettes from:

```text
GET /cassette/:id
```

Which returns:

```json
{
  "id": "abc123XYZ0",
  "createdAt": "2026-04-21T20:00:00.000Z",
  "payload": {
    "name": "Example",
    "summary": "",
    "artworkURLString": null,
    "sourceService": "spotify",
    "senderName": "Nick",
    "tracks": [
      {
        "title": "Example Song",
        "artistName": "Example Artist"
      }
    ]
  }
}
```

## Setup

1. From this folder, install dependencies:

```bash
npm install
```

2. Log in to Cloudflare:

```bash
npx wrangler login
```

3. Create the KV namespace:

```bash
npx wrangler kv namespace create CASSETTES
```

4. Copy the returned namespace ID into [wrangler.jsonc](/Users/nickjanocik/Documents/Masters/Cassette%20Swap/cassette-share-worker/wrangler.jsonc).

5. Set these values in [wrangler.jsonc](/Users/nickjanocik/Documents/Masters/Cassette%20Swap/cassette-share-worker/wrangler.jsonc):
- `PUBLIC_BASE_URL`
- `APPLE_TEAM_ID`
- `IOS_BUNDLE_ID`

6. Run locally:

```bash
npm run dev
```

7. Deploy:

```bash
npm run deploy
```

## Quick test

Create a cassette against your local Worker:

```bash
curl -X POST http://127.0.0.1:8787/cassette \
  -H "Content-Type: application/json" \
  -d '{
    "name": "Road Trip",
    "summary": "",
    "artworkURLString": null,
    "sourceService": "spotify",
    "senderName": "Nick",
    "tracks": [
      {
        "title": "Dreams",
        "artistName": "Fleetwood Mac"
      }
    ]
  }'
```

Then fetch it back with:

```bash
curl http://127.0.0.1:8787/cassette/<id>
```

## Domain / routing

Cheapest clean production setup:

- Put the Worker on a subdomain like `swap.yourdomain.com`
- Make the Worker the origin for that hostname
- Keep the API and public share links on the same hostname

Use that same base URL in the app's new `Public Share Base URL` field.

## Universal links

Once the Worker is on your real domain:

1. Add `applinks:swap.yourdomain.com` to Associated Domains in Xcode.
2. Make sure the Worker serves:

```text
https://swap.yourdomain.com/.well-known/apple-app-site-association
```

3. Set `APPLE_TEAM_ID` and `IOS_BUNDLE_ID` in `wrangler.jsonc`.
4. Use shared links in the form:

```text
https://swap.yourdomain.com/c/<id>
```

Without universal links, the `/c/:id` page still gives you a fallback `Open in Cassette Swap` button via the custom scheme.

## Cost controls

- Keep `CASSETTE_TTL_SECONDS` at 30 or 90 days
- Do not update cassettes after creation
- Do not log analytics to KV
- Do not use list requests in the app flow

At prototype scale this should stay near zero cost on Workers Free + KV.
