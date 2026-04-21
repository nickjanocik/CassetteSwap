# Cassette Swap

Minimal SwiftUI iOS app that takes a public Spotify or Apple Music playlist URL and recreates it on the other service.

## What it does

- Reads a public Spotify playlist and recreates it in Apple Music.
- Reads a public Apple Music playlist and recreates it in Spotify.
- Preserves track order when the destination service can resolve the tracks.
- Copies the playlist description when the API supports it.
- Attempts to copy artwork when the destination is Spotify.
- Can turn one of your own playlists into a shareable "cassette" link.
- Supports short public cassette links when you configure the optional Cloudflare Worker backend.

## Important API limits

- Spotify still requires OAuth access for this workflow, even when the source playlist is public.
- Apple Music still requires MusicKit user permission for this workflow.
- Apple Music only exposes library playlist creation here. It does not expose public-profile publishing or custom artwork upload for user library playlists.
- Track matching is best-effort. It tries ISRC first and then falls back to title and artist matching.

## Setup

1. Install Xcode on the Mac that will build the app.
2. Open [`Cassette Swap.xcodeproj`](/Users/nickjanocik/Documents/Masters/Cassette%20Swap/Cassette%20Swap.xcodeproj).
3. Set your signing team and bundle identifier if needed.
4. In the Apple Developer portal, enable the MusicKit App Service for the app's App ID.
5. In the Spotify Developer Dashboard, create an app and add `cassette-swap://spotify-callback` as an allowed redirect URI.
6. Build and run the app on an iPhone or iPad signed into Apple Music.
7. Paste the Spotify client ID from your Spotify app into the app's setup field.

## Notes

- The app stores the Spotify access token in the app's local `UserDefaults` container.
- The app stores the optional public share base URL in local `UserDefaults` too.
- The project targets iOS 17.
- This machine did not have a full Xcode installation available during creation, so the project files were generated directly and not compiled here.

## Optional Public Share Backend

If you want cross-device public cassette links, there is now a Worker scaffold in:

- [cassette-share-worker](/Users/nickjanocik/Documents/Masters/Cassette%20Swap/cassette-share-worker)

That Worker stores cassette JSON in Cloudflare KV and returns short links like:

- `https://swap.yourdomain.com/c/<id>`

The app's sign-in screen now includes a `Public Share Base URL` field. Set it to your deployed Worker base URL, for example:

- `https://swap.yourdomain.com`

If that field is empty, the app falls back to the old local custom-scheme share link.
