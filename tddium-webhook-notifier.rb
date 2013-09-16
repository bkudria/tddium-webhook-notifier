require 'sinatra'
require 'yaml'

set :cache, Dalli::Client.new

Pony.options = {
  reply_to:  ENV['NOTIFICATION_EMAIL'],
  from:      "Tddium Notifier <notifier@#{ENV['HEROKU_APP']}.herokuapp.com>",
  via:       :smtp,
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
  return [401, 'Specify auth_token parameter'] unless params[:auth_token] == ENV['AUTH_TOKEN']

  begin
    payload_hash = JSON.parse(request.body.read)
  rescue JSON::ParserError
    debug "Could not parse as JSON:\n#{request.body.to_s.inspect}"
    return [400, "Cannot parse body as JSON"]
  end

  all_keys     = %w(xid event status branch repository)
  has_all_keys = all_keys.all? {|key| payload_hash[key]}
  unless has_all_keys
    puts "Error with payload: #{request.body}"
    return [400, "Must include all keys: #{all_keys * ','}"]
  end

  cache   = settings.cache
  payload = OpenStruct.new(payload_hash)
  debug "Received request with payload:\n\n#{payload_hash.to_yaml}"

  unless %w(stop test).include? payload.event
    debug "Not an event we care about, doing nothing."
    return 200
  end

  hook_key = "hook-#{payload.xid}"
  build_status_key = "build-#{payload.repository['name']}-#{payload.branch}"

  if cache.get(hook_key) # We've already handled this request
    puts "Skipping work because we've handled this event (#{hook_key}) before"
  else
    debug "Handling event #{hook_key} for the first time"

    status = cache.get(build_status_key)
    debug "Cached status for #{build_status_key} is #{status.inspect}"
    if status == payload.status # nothing changed, carry on
      debug "Fetched status for #{build_status_key} matches payload status #{payload.status.inspect}"
    else
      debug "Sending notification and storing new status #{payload.status.inspect}"
      send_notification!(payload)
      cache.set(build_status_key, payload.status)
    end

    debug "Marking event #{hook_key} handled"
    cache.set(hook_key, true)
  end

  return 200
end

def debug(string)
  puts string if DEBUG
end

def send_notification!(payload)
  build_name    = "#{payload.repository['name']}/#{payload.branch}"
  fail_count    = payload.counts['failed'].to_i
  build_status  = {passed: 'passing.', failed: "failing. (#{fail_count} test#{fail_count == 1 ? '' : 's'})", error: 'failing with an error!'}[payload.status.to_sym]
  status_symbol = {passed: '✓', failed: '✘', error: '✱'}[payload.status.to_sym]
  committers_to = payload.committers.join(', ')
  who_to_notify = committers_to.empty? ? ENV['NOTIFICATION_EMAIL'] : committers_to
  Pony.mail(
    to:        who_to_notify,
    subject:   "#{status_symbol} #{build_name} is now #{build_status} [tddium]",
    html_body: haml(:email,
                    format: :html5,
                    locals: {
                      session:  payload.session,
                      commit:   payload.commit_id,
                      org:      payload.repository['org_name'],
                      repo:     payload.repository['name'],
                      payload:  payload.to_h.to_yaml,
                      debug:    DEBUG
                    })
  )
end
