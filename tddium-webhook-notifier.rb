require 'sinatra'
require 'yaml'

set :cache, Dalli::Client.new

Pony.options = {
  to:  ENV['NOTIFICATION_EMAIL'],
  via: :smtp,
  via_options: {
    address:         ENV['MAILGUN_SMTP_SERVER'],
    port:            ENV['MAILGUN_SMTP_PORT'],
    user_name:       ENV['MAILGUN_SMTP_LOGIN'],
    password:        ENV['MAILGUN_SMTP_PASSWORD'],
    domain:          "#{ENV['HEROKU_APP']}.herokuapp.com",
    authentication:  :plain,
  }
}

DEBUG = ENV['DEBUG'] == 'true'

post '/' do
  return 403 unless params[:auth_token] == ENV['AUTH_TOKEN']
  payload_hash = JSON.parse(request.body.read)
  has_all_keys = %w(xid event status branch repository).all? {|key| payload[key]}
  unless (payload_hash && has_all_keys)
    puts "Error with payload: #{request.body}"
    return 400
  end

  cache   = settings.cache
  payload = OpenStruct.new(payload_hash)
  debug "Received request with payload:\n\n#{payload.to_yaml}"

  return 200 unless payload.event == 'test'

  hook_key = "hook-#{payload.xid}"
  build_status_key = "build-#{payload.repository['name']}-#{payload.branch}"

  if cache.get(hook_key) # We've already handled this request
    puts "Skipping work because we've handled this event (#{hook_key}) before"
  else
    debug "Handling event #{hook_key} for the first time"

    status = cache.get(build_status_key)
    debug "Stored status for #{build_status_key}: #{status.inspect}"
    if status == payload.status # nothing changed, carry on
      debug "Fetched status for #{build_status_key} matches payload status #{payload.status.inspect}"
    else
      debug "Sending notification and storing new status #{payload.status.inspect}"
      send_notification!(payload)
      cache.set(build_status_key, payload.status)
    end

    debug "Marking event #{hook_key} handled"
    cache.set(hook_key)
  end

  return 200
end

def debug(string)
  puts string if DEBUG
end

def send_notification!(payload)
  build_name   = "#{payload.repository['name']}/#{payload.branch}"
  fail_count   = payload.counts['failed'].to_i
  build_status = {passed: 'passing. :)', failed: "failing. (#{fail_count} test#{fail_count != 1 && 's'}", error: 'failing with an error!'}[payload.status.to_sym]
  Pony.mail(
    subject:   "[tddium] #{build_name} is now #{build_status}.",
    html_body: haml(:email,
                    format: :html5,
                    locals: {
                      session:  payload.session,
                      commit:   payload.commit_id,
                      org:      payload.repository['org_name'],
                      repo:     payload.repository['name'],
                      payload:  payload_hash.to_yaml
                    })
  )
end
