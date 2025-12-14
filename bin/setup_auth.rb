#!/usr/bin/env ruby
# One-time OAuth setup: generates Spotify authorization URL,
# exchanges auth code for refresh token

require 'json'
require 'uri'
require 'net/http'
require 'openssl'
require 'dotenv/load'

CLIENT_ID = ENV.fetch('SPOTIFY_CLIENT_ID')
CLIENT_SECRET = ENV.fetch('SPOTIFY_CLIENT_SECRET')
REDIRECT_URI = 'http://127.0.0.1:3000/callback'
SCOPES = %w[playlist-modify-public playlist-modify-private].join(' ')

AUTH_URL = "https://accounts.spotify.com/authorize?response_type=code&client_id=#{URI.encode_www_form_component(CLIENT_ID)}&scope=#{URI.encode_www_form_component(SCOPES)}&redirect_uri=#{URI.encode_www_form_component(REDIRECT_URI)}"
TOKEN_URL = URI('https://accounts.spotify.com/api/token')

puts "Authorize the app by visiting:\n\n#{AUTH_URL}\n"
print 'After authorizing, paste the returned `code` parameter here: '
code = STDIN.gets&.strip

if code.nil? || code.empty?
  warn 'No code provided. Exiting.'
  exit 1
end

req = Net::HTTP::Post.new(TOKEN_URL)
req['Content-Type'] = 'application/x-www-form-urlencoded'
req.basic_auth(CLIENT_ID, CLIENT_SECRET)
req.set_form_data({
  'grant_type' => 'authorization_code',
  'code' => code,
  'redirect_uri' => REDIRECT_URI
})

http = Net::HTTP.new(TOKEN_URL.host, TOKEN_URL.port)
http.use_ssl = true
http.verify_mode = OpenSSL::SSL::VERIFY_PEER

res = http.request(req)

unless res.is_a?(Net::HTTPSuccess)
  warn "Token exchange failed: #{res.code} #{res.message}\n#{res.body}"
  exit 1
end

body = JSON.parse(res.body)
refresh_token = body['refresh_token']
access_token = body['access_token']

puts "\nSuccess! Your refresh_token:\n#{refresh_token}\n"
puts "Temporary access_token (for debug):\n#{access_token}\n"

puts 'Store SPOTIFY_REFRESH_TOKEN in your environment or GitHub Secrets.'
