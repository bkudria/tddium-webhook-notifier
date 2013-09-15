require "rubygems"
require "bundler"
Bundler.require

$stdout.sync = true

require './tddium-webhook-notifier'
run Sinatra::Application
