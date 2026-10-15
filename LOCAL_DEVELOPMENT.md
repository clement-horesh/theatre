# Local workspace

The app repository is the `mac` folder. The optional Jellyfin server, media, and server-management scripts belong to its parent workspace and are not part of a fresh clone.

In the original development workspace:

- `../Media/` is the Jellyfin media folder.
- `../LocalJellyfin/` holds the local server, configuration, cache, and logs.
- `../Scripts/setup-local-jellyfin.sh`, `start-local-jellyfin.sh`, and `stop-local-jellyfin.sh` manage that optional server.
- Its web interface is at `http://127.0.0.1:8096` while running.

For another checkout, run a Jellyfin server separately, add your media library there, and connect Theatre to its address. No parent folder or local-server script is required to build or use the app.
