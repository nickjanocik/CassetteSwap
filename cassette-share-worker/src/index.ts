interface Env {
  CASSETTES: KVNamespace;
  PUBLIC_BASE_URL?: string;
  CASSETTE_TTL_SECONDS?: string;
  APPLE_TEAM_ID?: string;
  IOS_BUNDLE_ID?: string;
}

interface CassetteTrack {
  title: string;
  artistName: string;
  albumTitle?: string | null;
  isrc?: string | null;
}

interface CassettePayload {
  name: string;
  summary: string;
  artworkURLString?: string | null;
  sourceService: "spotify" | "appleMusic";
  senderName?: string | null;
  senderImageURLString?: string | null;
  senderImageDataBase64?: string | null;
  tracks: CassetteTrack[];
}

interface CassetteRecord {
  version: 1;
  createdAt: string;
  payload: CassettePayload;
}

const DEFAULT_TTL_SECONDS = 60 * 60 * 24 * 30;
const CORS_HEADERS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Methods": "GET,POST,OPTIONS",
  "Access-Control-Allow-Headers": "Content-Type"
};
const ID_ALPHABET = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789";

export default {
  async fetch(request, env): Promise<Response> {
    if (request.method === "OPTIONS") {
      return new Response(null, {
        status: 204,
        headers: CORS_HEADERS
      });
    }

    try {
      const url = new URL(request.url);

      if (request.method === "GET" && url.pathname === "/health") {
        return json({ ok: true }, 200);
      }

      if (request.method === "GET" && url.pathname === "/.well-known/apple-app-site-association") {
        return handleAppleAppSiteAssociation(env);
      }

      if (request.method === "POST" && url.pathname === "/cassette") {
        try {
          return await handleCreateCassette(request, env);
        } catch (error) {
          return json({ error: toErrorMessage(error) }, 400);
        }
      }

      const cassetteId = matchPath(url.pathname, "/cassette/");
      if (request.method === "GET" && cassetteId) {
        return handleGetCassette(cassetteId, env);
      }

      const shareId = matchPath(url.pathname, "/c/");
      if (request.method === "GET" && shareId) {
        return handleLandingPage(shareId, request, env);
      }

      return json({ error: "Not found." }, 404);
    } catch (error) {
      return json({ error: toErrorMessage(error) }, 500);
    }
  }
} satisfies ExportedHandler<Env>;

async function handleCreateCassette(request: Request, env: Env): Promise<Response> {
  const body = await request.json<unknown>();
  const payload = parseCassettePayload(body);

  const id = generateId(10);
  const createdAt = new Date().toISOString();
  const record: CassetteRecord = {
    version: 1,
    createdAt,
    payload
  };

  const publicBaseURL = resolvePublicBaseURL(request, env);
  const ttlSeconds = parseTTLSeconds(env.CASSETTE_TTL_SECONDS);

  await env.CASSETTES.put(kvKey(id), JSON.stringify(record), {
    expirationTtl: ttlSeconds
  });

  const shareUrl = new URL(`/c/${id}`, publicBaseURL).toString();
  const openUrl = buildCustomSchemeURL(id, publicBaseURL).toString();

  return json(
    {
      id,
      createdAt,
      expiresInSeconds: ttlSeconds,
      shareUrl,
      openUrl
    },
    201
  );
}

async function handleGetCassette(id: string, env: Env): Promise<Response> {
  const stored = await env.CASSETTES.get(kvKey(id));
  if (!stored) {
    return json({ error: "Cassette not found." }, 404);
  }

  const record = JSON.parse(stored) as CassetteRecord;
  return json(
    {
      id,
      createdAt: record.createdAt,
      payload: record.payload
    },
    200,
    {
      "Cache-Control": "public, max-age=60"
    }
  );
}

async function handleLandingPage(id: string, request: Request, env: Env): Promise<Response> {
  const stored = await env.CASSETTES.get(kvKey(id));
  if (!stored) {
    return html(notFoundPage(), 404);
  }

  const record = JSON.parse(stored) as CassetteRecord;
  const publicBaseURL = resolvePublicBaseURL(request, env);
  const openUrl = buildCustomSchemeURL(id, publicBaseURL).toString();
  const title = escapeHTML(record.payload.name);
  const senderName = record.payload.senderName?.trim() || record.payload.sourceService;
  const escapedSenderName = escapeHTML(senderName);
  const trackCount = record.payload.tracks.length;
  const senderImageURL = safeImageURL(record.payload.senderImageURLString);
  const senderInlineImageURL = safeInlineImageDataURL(record.payload.senderImageDataBase64);
  const heroImageURL = safeImageURL(record.payload.senderImageURLString) ?? safeImageURL(record.payload.artworkURLString);
  const senderImageMarkup = senderImageURL || senderInlineImageURL
    ? `<img class="avatar" src="${escapeHTML(senderImageURL ?? senderInlineImageURL ?? "")}" alt="${escapedSenderName} profile photo">`
    : `<div class="avatar avatar-fallback" aria-hidden="true">${escapeHTML(senderName.charAt(0).toUpperCase() || "C")}</div>`;
  const heading = escapeHTML(`${senderName} sent you a Cassette!`);

  return html(
    `<!doctype html>
<html lang="en">
  <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>${title} | Cassette Swap</title>
    <meta name="description" content="${heading}">
    <meta property="og:title" content="${title}">
    <meta property="og:description" content="${heading} ${trackCount} tracks.">
    <meta property="og:type" content="website">
    ${heroImageURL ? `<meta property="og:image" content="${escapeHTML(heroImageURL)}">` : ""}
    <style>
      body {
        margin: 0;
        font-family: ui-rounded, system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
        background: linear-gradient(145deg, #12091f 0%, #21103a 52%, #0f1b3d 100%);
        color: #fff;
        min-height: 100vh;
        display: grid;
        place-items: center;
      }
      .card {
        width: min(560px, calc(100vw - 32px));
        background: rgba(10, 8, 22, 0.82);
        border: 1px solid rgba(255, 255, 255, 0.08);
        border-radius: 24px;
        padding: 28px;
        box-shadow: 0 24px 60px rgba(0, 0, 0, 0.4);
        text-align: center;
      }
      .avatar {
        width: 84px;
        height: 84px;
        border-radius: 50%;
        object-fit: cover;
        border: 2px solid rgba(255, 255, 255, 0.14);
        display: block;
        margin: 14px auto 16px;
      }
      .avatar-fallback {
        display: grid;
        place-items: center;
        background: linear-gradient(135deg, #ff5ba7 0%, #4db0ff 100%);
        font-size: 32px;
        font-weight: 800;
      }
      .eyebrow {
        color: #ff72aa;
        font-size: 12px;
        font-weight: 700;
        letter-spacing: 0.16em;
        text-transform: uppercase;
      }
      h1 {
        margin: 12px 0 8px;
        font-size: clamp(28px, 6vw, 40px);
        line-height: 1.05;
      }
      p {
        color: rgba(255, 255, 255, 0.72);
        line-height: 1.45;
      }
      .button {
        display: inline-block;
        margin-top: 16px;
        padding: 14px 20px;
        border-radius: 999px;
        text-decoration: none;
        color: #fff;
        font-weight: 700;
        background: linear-gradient(90deg, #ff5ba7 0%, #4db0ff 100%);
      }
      .meta {
        margin-top: 18px;
        font-size: 13px;
        color: rgba(255, 255, 255, 0.55);
      }
    </style>
  </head>
  <body>
    <main class="card">
      <div class="eyebrow">Cassette Swap</div>
      ${senderImageMarkup}
      <p>${heading}</p>
      <h1>${title}</h1>
      <p>Open this cassette in the app to recreate the playlist.</p>
      <p>${trackCount} tracks are waiting inside this cassette.</p>
      <a class="button" href="${escapeHTML(openUrl)}">Open in Cassette Swap</a>
      <div class="meta">If the app does not open automatically, install it first and try again.</div>
    </main>
  </body>
</html>`,
    200
  );
}

function handleAppleAppSiteAssociation(env: Env): Response {
  const teamID = env.APPLE_TEAM_ID?.trim();
  const bundleID = env.IOS_BUNDLE_ID?.trim();
  const appIDs = teamID && bundleID ? [`${teamID}.${bundleID}`] : [];

  return new Response(
    JSON.stringify({
      applinks: {
        details: [
          {
            appIDs,
            components: [
              {
                "/": "/c/*"
              }
            ]
          }
        ]
      }
    }),
    {
      status: 200,
      headers: {
        "Content-Type": "application/json",
        "Cache-Control": "public, max-age=3600"
      }
    }
  );
}

function parseCassettePayload(input: unknown): CassettePayload {
  if (!input || typeof input !== "object") {
    throw new Error("Cassette payload must be a JSON object.");
  }

  const payload = input as Record<string, unknown>;
  const name = requireString(payload.name, "name");
  const summary = typeof payload.summary === "string" ? payload.summary : "";
  const sourceService = requireMusicService(payload.sourceService);
  const senderName = optionalString(payload.senderName);
  const senderImageURLString = optionalString(payload.senderImageURLString);
  const senderImageDataBase64 = optionalBase64String(payload.senderImageDataBase64);
  const artworkURLString = optionalString(payload.artworkURLString);

  if (!Array.isArray(payload.tracks) || payload.tracks.length === 0) {
    throw new Error("Cassette payload must include at least one track.");
  }

  const tracks = payload.tracks.map((track, index) => parseTrack(track, index));

  return {
    name,
    summary,
    artworkURLString,
    sourceService,
    senderName,
    senderImageURLString,
    senderImageDataBase64,
    tracks
  };
}

function parseTrack(input: unknown, index: number): CassetteTrack {
  if (!input || typeof input !== "object") {
    throw new Error(`Track ${index + 1} is invalid.`);
  }

  const track = input as Record<string, unknown>;
  return {
    title: requireString(track.title, `tracks[${index}].title`),
    artistName: requireString(track.artistName, `tracks[${index}].artistName`),
    albumTitle: optionalString(track.albumTitle),
    isrc: optionalString(track.isrc)
  };
}

function requireMusicService(input: unknown): CassettePayload["sourceService"] {
  if (input === "spotify" || input === "appleMusic") {
    return input;
  }

  throw new Error("Cassette payload sourceService must be spotify or appleMusic.");
}

function requireString(input: unknown, fieldName: string): string {
  if (typeof input !== "string" || input.trim() === "") {
    throw new Error(`Cassette payload field ${fieldName} is required.`);
  }

  return input;
}

function optionalString(input: unknown): string | null {
  return typeof input === "string" && input.trim() !== "" ? input : null;
}

function optionalBase64String(input: unknown): string | null {
  if (typeof input !== "string") {
    return null;
  }

  const trimmed = input.trim();
  if (trimmed === "" || /^[A-Za-z0-9+/=]+$/.test(trimmed) === false) {
    return null;
  }

  return trimmed;
}

function parseTTLSeconds(rawValue: string | undefined): number {
  const parsed = Number.parseInt(rawValue ?? "", 10);
  return Number.isFinite(parsed) && parsed > 0 ? parsed : DEFAULT_TTL_SECONDS;
}

function resolvePublicBaseURL(request: Request, env: Env): URL {
  const configured = env.PUBLIC_BASE_URL?.trim();
  if (configured) {
    return new URL(configured.replace(/\/+$/, ""));
  }

  return new URL(new URL(request.url).origin);
}

function buildCustomSchemeURL(id: string, publicBaseURL: URL): URL {
  const components = new URL("cassette-swap://cassette");
  components.searchParams.set("id", id);
  components.searchParams.set("base", publicBaseURL.toString().replace(/\/+$/, ""));
  return components;
}

function safeImageURL(rawValue: string | null | undefined): string | null {
  if (!rawValue) {
    return null;
  }

  try {
    const url = new URL(rawValue);
    return url.protocol === "https:" ? url.toString() : null;
  } catch {
    return null;
  }
}

function safeInlineImageDataURL(rawValue: string | null | undefined): string | null {
  if (!rawValue) {
    return null;
  }

  return /^[A-Za-z0-9+/=]+$/.test(rawValue)
    ? `data:image/jpeg;base64,${rawValue}`
    : null;
}

function kvKey(id: string): string {
  return `cassette:${id}`;
}

function generateId(length: number): string {
  const bytes = crypto.getRandomValues(new Uint8Array(length));
  let output = "";

  for (let index = 0; index < bytes.length; index += 1) {
    output += ID_ALPHABET[bytes[index] % ID_ALPHABET.length];
  }

  return output;
}

function matchPath(pathname: string, prefix: string): string | null {
  if (!pathname.startsWith(prefix)) {
    return null;
  }

  const value = pathname.slice(prefix.length).split("/")[0];
  return value || null;
}

function json(payload: unknown, status = 200, extraHeaders: Record<string, string> = {}): Response {
  return new Response(JSON.stringify(payload), {
    status,
    headers: {
      "Content-Type": "application/json",
      ...CORS_HEADERS,
      ...extraHeaders
    }
  });
}

function html(content: string, status = 200): Response {
  return new Response(content, {
    status,
    headers: {
      "Content-Type": "text/html; charset=utf-8"
    }
  });
}

function escapeHTML(value: string): string {
  return value
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll("\"", "&quot;")
    .replaceAll("'", "&#39;");
}

function toErrorMessage(error: unknown): string {
  if (error instanceof Error) {
    return error.message;
  }

  return "Unexpected error.";
}

function notFoundPage(): string {
  return `<!doctype html>
<html lang="en">
  <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>Cassette not found</title>
    <style>
      body {
        margin: 0;
        min-height: 100vh;
        display: grid;
        place-items: center;
        font-family: ui-rounded, system-ui, sans-serif;
        background: #100b1a;
        color: white;
      }
      .card {
        width: min(480px, calc(100vw - 32px));
        padding: 28px;
        border-radius: 24px;
        background: rgba(255, 255, 255, 0.04);
        border: 1px solid rgba(255, 255, 255, 0.08);
      }
      p {
        color: rgba(255, 255, 255, 0.7);
      }
    </style>
  </head>
  <body>
    <main class="card">
      <h1>Cassette not found</h1>
      <p>This share link is missing or expired.</p>
    </main>
  </body>
</html>`;
}
