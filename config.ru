require "rubygems"
require "bundler"
Bundler.require

require './tddium-webhook-notifier'
run Sinatra::Application
