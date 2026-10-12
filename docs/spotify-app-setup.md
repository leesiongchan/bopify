# Spotify app setup for library features

Playback works out of the box. Favorites, Liked Songs and listening history
call the Spotify Web API, and for that Bopify needs a Spotify app that you
register yourself. It takes a few minutes and costs nothing.

## Why you need your own app

A Spotify app in Development Mode serves at most five allowlisted users, and
extended quota is limited to organizations with a large user base
([Quota modes](https://developer.spotify.com/documentation/web-api/concepts/quota-modes)).
Bopify cannot ship one shared app for everyone, so each user brings their own.
Playback is unaffected: it uses librespot's client ID and needs no setup.

## Setup

Open Library Access from the status menu (right-click the menu bar icon), or
click any Enable button for Favorites, Liked Songs or history. Then:

1. Open the [Spotify Developer Dashboard](https://developer.spotify.com/dashboard)
   and click **Create app**. Your Spotify account needs Premium.
2. Add this Redirect URI and tick **Web API**:

   ```
   http://127.0.0.1:8898/callback
   ```

3. Save the app. Under **User Management**, add your own Spotify account's
   name and email. Quota modes: "Each Spotify user who installs your app will
   need to be added to your app's allowlist". Spotify blocks anyone not on that
   list, owner included: they get a 403. The Favorite button shows that as its
   "forbidden" notice; Liked Songs, Recents and Explore show only their generic
   "couldn't load" text.
4. Copy the app's **Client ID** (not the Client secret) and paste it into
   Library Access, then Save. If you opened Library Access from an Enable
   button, Spotify then opens a consent page naming your app. If you opened it
   from the status menu, Save just closes the window; click Enable to consent.

## Troubleshooting

If Spotify shows INVALID_CLIENT instead of a consent page, check the Client ID
and the Redirect URI in the Dashboard, then Save again in Library Access and
click Enable.

## Renewing consent

Library consent expires and must be renewed every six months
([Refresh token expiration](https://developer.spotify.com/blog/2026-06-18-refresh-token-expiration)).
When it lapses, enable the library feature again to consent again.

## Playback

Playback uses librespot's first-party client ID with the redirect URI
`http://127.0.0.1:<port>/login` and the `streaming` scope. The account must
have Spotify Premium; librespot is Premium-only. This needs no setup from you.
