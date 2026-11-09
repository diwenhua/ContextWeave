# Local update feed

This empty feed is for development only. Serve it locally with:

```sh
python3 -m http.server 8765 --bind 127.0.0.1 --directory dev/update-feed
```

Run the packaged app and select **ContextWeave → Check for Updates…**. The feed contains no releases; checking should report that the app is up to date. The test feed and test key are not suitable for distributing updates. Before the first public release configure an HTTPS feed, a securely managed signing key, Developer ID signing, and notarization, then test the complete update flow.
