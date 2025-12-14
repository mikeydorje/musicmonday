# MusicMonday Sync

Automatically syncs music from the MusicMonday series at [music.forem.com/musicfrorem/series/34176](https://music.forem.com/musicfrorem/series/34176) to a Spotify playlist. Extracts tracks from YouTube and Spotify links/embeds in article comments.

## Requirements
- Ruby 3.1+
- Spotify app credentials ([create one here](https://developer.spotify.com/dashboard))

## Local Setup

1. Install dependencies:
```bash
bundle install
```

2. Create `.env` file:
```bash
SPOTIFY_CLIENT_ID=your_client_id
SPOTIFY_CLIENT_SECRET=your_client_secret
SPOTIFY_REFRESH_TOKEN=
PLAYLIST_ID=your_playlist_id
```

3. Get refresh token:
   - Add `http://127.0.0.1:3000/callback` to your app's Redirect URIs in [Spotify Dashboard](https://developer.spotify.com/dashboard)
   - Run `ruby bin/setup_auth.rb`
   - Authorize in browser, copy the `code` from the redirect URL
   - Paste code in terminal, copy the refresh token to `.env`

4. Run sync:
```bash
ruby main.rb
```

## GitHub Actions
Runs automatically every Monday at 12:00 UTC. Set repository secrets in Settings → Secrets → Actions:
- `SPOTIFY_CLIENT_ID`
- `SPOTIFY_CLIENT_SECRET`
- `SPOTIFY_REFRESH_TOKEN`
- `PLAYLIST_ID`

## How It Works
- Fetches recent articles from `music.forem.com/api/articles?username=musicfrorem&tag=musicmonday`
- Parses comments for Spotify and YouTube links/embeds
- YouTube videos: fetches title via oEmbed, searches Spotify for match
- Adds new tracks to playlist (deduplicates automatically)

## Contributing
Open source and contributor-friendly. Test locally with `ruby main.rb` before submitting PRs. Don't commit `.env`.
