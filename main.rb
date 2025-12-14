#!/usr/bin/env ruby
# frozen_string_literal: true

require 'bundler/setup'

require 'set'
require 'json'
require 'uri'
require 'httparty'
require 'dotenv/load'
require 'rspotify'

CLIENT_ID = ENV.fetch('SPOTIFY_CLIENT_ID')
CLIENT_SECRET = ENV.fetch('SPOTIFY_CLIENT_SECRET')
REFRESH_TOKEN = ENV.fetch('SPOTIFY_REFRESH_TOKEN')
PLAYLIST_ID = ENV['PLAYLIST_ID']
PLAYLIST_URL = ENV['PLAYLIST_URL']
DRY_RUN = ENV['DRY_RUN'] == '1'
SHOW_ALL_MATCHES = ENV['SHOW_ALL_MATCHES'] == '1'

RSpotify.authenticate(CLIENT_ID, CLIENT_SECRET)

TOKEN_URL = URI('https://accounts.spotify.com/api/token')

# Exchange refresh token for a new access token
def refresh_access_token
  req = Net::HTTP::Post.new(TOKEN_URL)
  req['Content-Type'] = 'application/x-www-form-urlencoded'
  req.basic_auth(CLIENT_ID, CLIENT_SECRET)
  req.set_form_data({
    'grant_type' => 'refresh_token',
    'refresh_token' => REFRESH_TOKEN
  })

  http = Net::HTTP.new(TOKEN_URL.host, TOKEN_URL.port)
  http.use_ssl = true
  res = http.request(req)
  raise "Token refresh failed: #{res.code} #{res.message} #{res.body}" unless res.is_a?(Net::HTTPSuccess)
  JSON.parse(res.body)['access_token']
end

ACCESS_TOKEN = refresh_access_token
SPOTIFY_API_BASE = 'https://api.spotify.com/v1'

# Fetch all track URIs currently in the playlist to avoid duplicates
def fetch_existing_track_uris(playlist_id)
  uris = Set.new
  url = "#{SPOTIFY_API_BASE}/playlists/#{playlist_id}/tracks"
  loop do
    res = HTTParty.get(url, headers: { 'Authorization' => "Bearer #{ACCESS_TOKEN}" })
    raise "Failed to fetch playlist tracks: #{res.code} #{res.body}" unless res.code == 200
    items = res.parsed_response['items'] || []
    items.each do |item|
      track = item['track']
      next unless track
      uris.add(track['uri']) if track['uri']
    end
    next_url = res.parsed_response.dig('next')
    break unless next_url
    url = next_url
  end
  uris
end

FOREM_ARTICLES_URL = 'https://music.forem.com/api/articles?username=musicfrorem&tag=musicmonday'

def fetch_recent_articles(limit: 10)
  res = HTTParty.get(FOREM_ARTICLES_URL)
  raise "Forem articles fetch failed: #{res.code} #{res.body}" unless res.code == 200
  articles = res.parsed_response
  articles.first(limit)
end

def fetch_comments(article_id)
  url = "https://music.forem.com/api/comments?a_id=#{article_id}"
  res = HTTParty.get(url)
  if res.code == 429
    puts "Rate limited on article #{article_id}, waiting 2 seconds..."
    sleep 2
    res = HTTParty.get(url)
  end
  if res.code != 200
    warn "Forem comments fetch failed (a_id=#{article_id}): #{res.code} #{res.body}"
    return []
  end
  res.parsed_response
end

# Recursively extract body_html from nested comment tree
def collect_body_html(comment_tree, acc)
  return unless comment_tree
  if comment_tree.is_a?(Array)
    comment_tree.each { |c| collect_body_html(c, acc) }
    return
  end
  html = comment_tree['body_html']
  acc << html if html
  children = comment_tree['children'] || []
  children.each { |child| collect_body_html(child, acc) }
end

# Regex to match Spotify track links and embeds
SPOTIFY_TRACK_REGEX = %r{https?://open\.spotify\.com/(?:track|embed/track)/([a-zA-Z0-9]+)}
# Regex to match YouTube links and embeds
YOUTUBE_REGEX = %r{https?://(?:www\.)?(?:youtube\.com/(?:watch\?v=|embed/)|youtu\.be/)([\w-]+)}

def extract_spotify_track_ids_from_html(html)
  ids = []
  html.scan(SPOTIFY_TRACK_REGEX) { |m| ids << m[0] }
  ids
end

# Fetch YouTube video title using oEmbed API (no auth required)
def fetch_youtube_title(video_id)
  url = "https://www.youtube.com/oembed?url=https://www.youtube.com/watch?v=#{video_id}&format=json"
  res = HTTParty.get(url)
  return nil unless res.code == 200
  res.parsed_response['title']
rescue => e
  warn "Failed to fetch YouTube title for #{video_id}: #{e.message}"
  nil
end

def normalize(str)
  str.downcase.gsub(/[^a-z0-9\s]/, ' ').squeeze(' ').strip
end

def parse_title_artist(title)
  cleaned = title.dup
  cleaned.gsub!(/\([^)]*\)/, ' ') # remove parentheses content
  cleaned.gsub!(/\[[^\]]*\]/, ' ') # remove brackets content
  parts = cleaned.split('-').map(&:strip)
  if parts.size >= 2
    artist = parts[0]
    song = parts[1..].join(' ')
  else
    artist = nil
    song = cleaned
  end
  [artist, song]
end

# Search Spotify for best matching track with simple heuristic scoring
def search_spotify_track(query)
  artist, song = parse_title_artist(query)
  base_query = [artist, song].compact.join(' ')
  url = "#{SPOTIFY_API_BASE}/search"
  params = { q: base_query, type: 'track', limit: 5 }
  res = HTTParty.get(url, headers: { 'Authorization' => "Bearer #{ACCESS_TOKEN}" }, query: params)
  return nil unless res.code == 200
  tracks = res.parsed_response.dig('tracks', 'items')
  return nil if tracks.nil? || tracks.empty?

  target_artist = normalize(artist || '')
  target_song = normalize(song || '')

  scored = tracks.map do |t|
    name = normalize(t['name'] || '')
    artists = (t['artists'] || []).map { |a| normalize(a['name'] || '') }
    artist_score = target_artist.empty? ? 0 : (artists.any? { |a| a.include?(target_artist) || target_artist.include?(a) } ? 2 : 0)
    title_score = target_song.empty? ? 0 : (name.include?(target_song) || target_song.include?(name) ? 2 : 0)
    partial_title = target_song.split.first(2).join(' ')
    title_score += 1 if !partial_title.empty? && name.include?(partial_title)
    { uri: t['uri'], score: artist_score + title_score }
  end

  best = scored.max_by { |s| s[:score] }
  return nil if best.nil? || best[:score] < 2 # require at least weak match
  best[:uri]
rescue => e
  warn "Spotify search failed for '#{query}': #{e.message}"
  nil
end

# Process articles and comments to get track URIs

# Extract track URIs from article comments (Spotify links + YouTube → Spotify search)
def collect_new_track_uris(articles, existing_uris)
  new_uris = []
  articles.each do |article|
    comments = fetch_comments(article['id'])
    bodies = []
    collect_body_html(comments, bodies)

    bodies.each do |html|
      # Parse direct Spotify links/embeds
      extract_spotify_track_ids_from_html(html).each do |track_id|
        uri = "spotify:track:#{track_id}"
        if existing_uris.include?(uri)
          puts "Found Spotify track (already in playlist): #{uri}" if SHOW_ALL_MATCHES
          next
        end
        new_uris << uri
        puts "Found Spotify track: #{uri}"
      end

      # Parse YouTube links/embeds, search Spotify by title
      yt = html.scan(YOUTUBE_REGEX).map { |m| m[0] }
      yt.each do |yt_id|
        title = fetch_youtube_title(yt_id)
        next unless title
        puts "YouTube video: #{title}"
        uri = search_spotify_track(title)
        if uri.nil?
          puts "  → No Spotify match found"
          next
        end
        if existing_uris.include?(uri)
          puts "  → Matched Spotify (already in playlist): #{uri}" if SHOW_ALL_MATCHES
          next
        end
        new_uris << uri
        puts "  → Matched Spotify: #{uri}"
      end
    end
  end
  new_uris.uniq
end

# Add track URIs to playlist (supports dry-run mode)
def add_tracks_to_playlist(playlist_id, uris)
  return if uris.empty?
  url = "#{SPOTIFY_API_BASE}/playlists/#{playlist_id}/tracks"
  body = { uris: uris }
  if DRY_RUN
    puts "DRY_RUN: Would add #{uris.size} tracks to playlist #{playlist_id}:"
    uris.each { |u| puts "  - #{u}" }
    return
  end
  res = HTTParty.post(url,
                      headers: { 'Authorization' => "Bearer #{ACCESS_TOKEN}", 'Content-Type' => 'application/json' },
                      body: JSON.dump(body))
  raise "Failed to add tracks: #{res.code} #{res.body}" unless res.code.between?(200, 299)
  puts "Added #{uris.size} tracks to playlist #{playlist_id}."
end

# Extract playlist ID from Spotify playlist URL
def playlist_id_from_url(url)
  return nil unless url
  m = url.match(%r{open\.spotify\.com/playlist/([a-zA-Z0-9]+)})
  m && m[1]
end

begin
  pid = PLAYLIST_ID || playlist_id_from_url(PLAYLIST_URL)
  raise 'PLAYLIST_ID missing. Set PLAYLIST_ID or PLAYLIST_URL in env.' unless pid

  existing_uris = fetch_existing_track_uris(pid)
  puts "Existing tracks in playlist: #{existing_uris.size}"

  articles = fetch_recent_articles(limit: 10)
  puts "Fetched #{articles.size} recent articles."

  new_uris = collect_new_track_uris(articles, existing_uris)
  puts "Collected #{new_uris.size} new track URIs."

  add_tracks_to_playlist(pid, new_uris)
rescue => e
  warn e.message
  warn e.backtrace.join("\n")
  exit 1
end
