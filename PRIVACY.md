# Privacy

Theatre connects to the Jellyfin server address you enter. Your credentials are sent to that server to sign in; Theatre stores the server-issued session token in the macOS Keychain and does not save your password. The server address and application preferences are stored locally. Sign Out removes the saved session.

Browsing, playback reporting, watch-status changes, downloads, and progress synchronization send requests to your Jellyfin server. An HTTP server connection is not encrypted; HTTPS uses the server’s certificate validation. Your Jellyfin server and its operators control their own logs and retention.

Artwork and downloaded media, metadata, subtitles, and pending watch progress are cached on your Mac. Downloads are separated by server and account. Signing out hides that account’s downloads; it does not delete them. Use the download removal controls to delete saved media.

Remote trailers supplied by Jellyfin can contact their external providers. YouTube trailer cards load thumbnails from YouTube’s image service; opening a trailer uses YouTube’s embedded player. Those providers have their own privacy policies. Theatre does not forward Jellyfin authorization headers to trailer providers.

Theatre includes no analytics, advertising, or third-party crash-reporting service. It does not upload your library to a Theatre-operated service. macOS and your configured servers or trailer providers may independently collect diagnostic or request information under their own settings and policies.
