# Post-publish hook: publish_to_docs.rb
#
# Runs after the ai-summary format is published. Reads ai-summary.md and
# publishes it as a child document in a La Suite Numérique "Docs" space,
# under the parent identified by meta_bbb-docs-document-id.
#
# Because the Docs API does not accept markdown directly as a subdocument,
# the upload is performed in three steps:
#   1. POST /api/v1.0/documents/          — upload md as a temporary doc,
#                                           capture 'content' from the response
#   2. DELETE /api/v1.0/documents/<id>/   — remove the temporary doc
#   3. POST /api/v1.0/documents/<parent>/children/
#                                         — create the child with that content
#
# Keycloak client-credentials flow is used to obtain the Bearer token.
#
# Meeting creation — set at /create time:
#   meta_bbb-docs-document-id=<parent-document-uuid>
#
# Config: docs: section in /usr/local/bigbluebutton/core/scripts/ai-summary.yml
#
# BBB pipeline usage (run automatically by the recording worker):
#   ruby post_publish/publish_to_docs.rb -m <meeting_id> -f <format>
#
# Logs to: $log_dir/ai-summary/post_publish-docs-<meeting_id>.log

require File.expand_path('../../../lib/recordandplayback', __FILE__)
require 'optimist'
require 'yaml'
require 'net/http'
require 'uri'
require 'json'
require 'logger'
require 'fileutils'
require 'securerandom'
require 'nokogiri'

opts = Optimist::options do
  opt :meeting_id, 'Meeting ID',                          type: String
  opt :format,     'Recording format (e.g. ai-summary)',  type: String
end

meeting_id  = opts[:meeting_id]
format_name = opts[:format]

Optimist::die :meeting_id, 'is required' if meeting_id.nil? || meeting_id.strip.empty?

unless format_name == 'ai-summary'
  puts "Format '#{format_name}' is not ai-summary — skipping docs upload."
  exit 0
end


# Recursively merges +override+ into +base+, combining nested hashes key-by-key
# so that only the keys present in +override+ are changed.
def deep_merge_hashes(base, override)
  base.merge(override) do |_key, base_val, override_val|
    if base_val.is_a?(Hash) && override_val.is_a?(Hash)
      deep_merge_hashes(base_val, override_val)
    else
      override_val
    end
  end
end

# Reads ai-summary.yml from +config_path+, applies an optional operator
def load_docs_config(config_path, logger)
  unless File.exist?(config_path)
    logger.info("ai-summary.yml not found at #{config_path} — skipping docs upload.")
    return nil
  end

  full_config = YAML.safe_load(File.read(config_path)) || {}

  override_path = '/etc/bigbluebutton/ai-summary.yml'
  if File.exist?(override_path)
    override = YAML.safe_load(File.read(override_path)) || {}
    full_config = deep_merge_hashes(full_config, override)
    logger.info("Applied config override from #{override_path}")
  end

  full_config['docs']
end

bbb_props     = BigBlueButton.read_props
log_dir       = bbb_props['log_dir']       || '/var/log/bigbluebutton'
recording_dir = bbb_props['recording_dir'] || '/var/bigbluebutton/recording'
publish_dir   = '/var/bigbluebutton/published/ai-summary'.freeze

FileUtils.mkdir_p("#{log_dir}/ai-summary")
logger = Logger.new("#{log_dir}/ai-summary/post_publish-docs-#{meeting_id}.log", 'daily')
BigBlueButton.logger = logger

logger.info('=== publish_to_docs post_publish ===')
logger.info("Meeting ID : #{meeting_id}")
logger.info("Format     : #{format_name}")

cfg = load_docs_config('ai-summary.yml', logger)
if cfg.nil?
  logger.info('No docs: section in ai-summary.yml — skipping docs upload.')
  exit 0
end

unless cfg.fetch('enabled', true)
  logger.info('docs.enabled is false — skipping docs upload.')
  exit 0
end

docs_host     = cfg['docs_host'].to_s.chomp('/')
keycloak_host = cfg['keycloak_host']
realm         = cfg['realm']
client_id     = cfg['client_id']
client_secret = cfg['client_secret']

raw_dir          = "#{recording_dir}/raw/#{meeting_id}"
meeting_metadata = BigBlueButton::Events.get_meeting_metadata("#{raw_dir}/events.xml")

parent_id    = meeting_metadata['bbb-docs-document-id'].to_s
meeting_name = (meeting_metadata['meetingName'] || meeting_metadata['name']).to_s
meeting_name = 'Meeting Summary' if meeting_name.empty?

events_doc       = Nokogiri::XML(File.read("#{raw_dir}/events.xml"))
start_ts_ms      = events_doc.at_xpath('//event/timestampUTC')&.text.to_i
meeting_start    = Time.at(start_ts_ms / 1000.0).utc
meeting_date_str = "(#{meeting_start.strftime('%Y-%m-%d %H:%M:%S %Z')})"
document_title   = "#{meeting_name} #{meeting_date_str}"

if parent_id.empty?
  logger.info('meta_bbb-docs-document-id not set for this meeting — skipping docs upload.')
  exit 0
end

logger.info("Parent document ID : #{parent_id}")
logger.info("Meeting name       : #{meeting_name}")

md_path = "#{publish_dir}/#{meeting_id}/ai-summary.md"

unless File.exist?(md_path)
  logger.error("Markdown file not found: #{md_path}")
  exit 1
end

markdown_content = File.read(md_path, encoding: 'UTF-8')
logger.info("Read #{markdown_content.bytesize} bytes from #{md_path}")

def http_for(uri)
  http              = Net::HTTP.new(uri.host, uri.port)
  http.use_ssl      = (uri.scheme == 'https')
  http.open_timeout = 10
  http.read_timeout = 30
  http
end

def check!(response, step, logger)
  return if response.is_a?(Net::HTTPSuccess)

  logger.error("#{step} failed: HTTP #{response.code} — #{response.body.to_s[0, 500]}")
  exit 1
end

def fetch_keycloak_access_token(keycloak_host, realm, client_id, client_secret, logger)
  logger.info('Obtaining Keycloak access token...')

  token_uri = URI.parse("https://#{keycloak_host}/realms/#{realm}/protocol/openid-connect/token")
  token_req = Net::HTTP::Post.new(token_uri.request_uri)
  token_req['Content-Type'] = 'application/x-www-form-urlencoded'
  token_req.body = URI.encode_www_form(
    client_id:     client_id,
    client_secret: client_secret,
    grant_type:    'client_credentials',
    scope:         'openid email'
  )

  token_res = http_for(token_uri).request(token_req)
  check!(token_res, 'Keycloak token request', logger)

  access_token = JSON.parse(token_res.body)['access_token']
  if access_token.nil? || access_token.empty?
    logger.error('Keycloak response did not include an access_token')
    exit 1
  end

  access_token
end

def get_access_token(meeting_metadata, keycloak_host, realm, client_id, client_secret, logger)
  meta_token = meeting_metadata['la-suite-numerique-docs-access-token'].to_s
  unless meta_token.empty?
    logger.info('Using access token from meta_la-suite-numerique-docs-access-token.')
    return meta_token
  end

  fetch_keycloak_access_token(keycloak_host, realm, client_id, client_secret, logger)
end

logger.info('Step 1: Obtaining access token...')
access_token = get_access_token(meeting_metadata, keycloak_host, realm, client_id, client_secret, logger)
logger.info('Access token obtained.')

logger.info('Step 2: Uploading markdown as temporary document...')

boundary   = "----RubyFormBoundary#{SecureRandom.hex(10)}"
upload_uri = URI.parse("#{docs_host}/api/v1.0/documents/")

multipart_body = [
  "--#{boundary}\r\n",
  "Content-Disposition: form-data; name=\"file\"; filename=\"ai-summary.md\"\r\n",
  "Content-Type: text/markdown\r\n",
  "\r\n",
  markdown_content,
  "\r\n--#{boundary}--\r\n"
].join

upload_req = Net::HTTP::Post.new(upload_uri.request_uri)
upload_req['Authorization'] = "Bearer #{access_token}"
upload_req['Content-Type']  = "multipart/form-data; boundary=#{boundary}"
upload_req.body             = multipart_body

upload_res = http_for(upload_uri).request(upload_req)
check!(upload_res, 'Document upload', logger)

upload_json  = JSON.parse(upload_res.body)
temp_doc_id  = upload_json['id']
doc_content  = upload_json['content']

logger.info("Temporary document created: #{temp_doc_id}")

logger.info('Step 3: Deleting temporary document...')

delete_uri = URI.parse("#{docs_host}/api/v1.0/documents/#{temp_doc_id}/")
delete_req = Net::HTTP::Delete.new(delete_uri.request_uri)
delete_req['Authorization'] = "Bearer #{access_token}"

delete_res = http_for(delete_uri).request(delete_req)
check!(delete_res, 'Temporary document deletion', logger)
logger.info('Temporary document deleted.')

logger.info("Step 4: Creating child document under parent #{parent_id}...")

child_uri = URI.parse("#{docs_host}/api/v1.0/documents/#{parent_id}/children/")
child_req = Net::HTTP::Post.new(child_uri.request_uri)
child_req['Authorization'] = "Bearer #{access_token}"
child_req['Content-Type']  = 'application/json'
child_req.body             = JSON.generate({ title: document_title, content: doc_content })

child_res = http_for(child_uri).request(child_req)
check!(child_res, 'Child document creation', logger)

child_doc = JSON.parse(child_res.body)
logger.info("Child document created: #{child_doc['id']} — '#{child_doc['title']}'")

logger.info('=== publish_to_docs complete ===')
