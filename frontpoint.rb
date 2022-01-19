#!/usr/bin/env ruby
# frozen_string_literal: true

require 'thor'
require 'fileutils'
require 'logger'
require 'rest-client'
require 'json'
require 'influxdb'
require 'date'
require 'yaml'

# see https://github.com/elahd/pyalarmdotcomajax/tree/master/pyalarmdotcomajax
# file:///home/jeff/.local/lib/python3.8/site-packages/pyalarmdotcomajax/__init__.py

LOGFILE = File.join(Dir.home, '.log', 'frontpoint.log')
CREDENTIALS_PATH = File.join(Dir.home, '.credentials', 'frontpoint.yaml')

URL_BASE = 'https://www.alarm.com'
LOGIN_URL = "#{URL_BASE}/login"
LOGIN_USERNAME_FIELD = 'ctl00$ContentPlaceHolder1$loginform$txtUserName'
LOGIN_PASSWORD_FIELD = 'txtPassword'
LOGIN_POST_URL = "#{URL_BASE}/web/Default.aspx"
SENSOR_URL = "#{URL_BASE}/web/api/devices/sensors/"

VIEWSTATE_FIELD = '__VIEWSTATE'
VIEWSTATEGENERATOR_FIELD = '__VIEWSTATEGENERATOR'
EVENTVALIDATION_FIELD = '__EVENTVALIDATION'
PREVIOUSPAGE_FIELD = '__PREVIOUSPAGE'

module Kernel
  def with_rescue(exceptions, logger, retries: 5)
    try = 0
    begin
      yield try
    rescue *exceptions => e
      try += 1
      raise if try > retries

      logger.info "caught error #{e.class}, retrying (#{try}/#{retries})..."
      retry
    end
  end
end

class Frontpoint < Thor
  no_commands do
    def redirect_output
      unless LOGFILE == 'STDOUT'
        logfile = File.expand_path(LOGFILE)
        FileUtils.mkdir_p(File.dirname(logfile), mode: 0o755)
        FileUtils.touch logfile
        File.chmod 0o644, logfile
        $stdout.reopen logfile, 'a'
      end
      $stderr.reopen $stdout
      $stdout.sync = $stderr.sync = true
    end

    def setup_logger
      redirect_output if options[:log]

      @logger = Logger.new $stdout
      @logger.level = options[:verbose] ? Logger::DEBUG : Logger::INFO
      @logger.info 'starting'
    end
  end

  class_option :log,     type: :boolean, default: true, desc: "log output to #{LOGFILE}"
  class_option :verbose, type: :boolean, aliases: '-v', desc: 'increase verbosity'

  desc 'record-status', 'record the current usage data to database'
  method_option :dry_run, type: :boolean, aliases: '-n', desc: "don't log to database"
  def record_status
    setup_logger

    credentials = YAML.load_file CREDENTIALS_PATH

    influxdb = options[:dry_run] ? nil : InfluxDB::Client.new('frontpoint')

    #
    # Phase 1
    # Get login page, passing 2FA credential
    # Extract fields required to post login
    #

    cookies = { twoFactorAuthenticationId: credentials[:twoFactorAuthenticationId] }

    response = with_rescue([RestClient::Exceptions::OpenTimeout,
                            RestClient::ServiceUnavailable], @logger) do |_try|
      RestClient::Request.execute(method: :get, url: LOGIN_URL, cookies: cookies)
    end
    body = response.body
    jar = response.cookie_jar

    viewstate_field = body[/id="#{VIEWSTATE_FIELD}" value="(.*)"/, 1]
    viewstategenerator_field = body[/id="#{VIEWSTATEGENERATOR_FIELD}" value="(.*)"/, 1]
    eventvalidation_field = body[/id="#{EVENTVALIDATION_FIELD}" value="(.*)"/, 1]
    previouspage_field = body[/id="#{PREVIOUSPAGE_FIELD}" value="(.*)"/, 1]

    #
    # Phase 2
    # Login, ignore redirect
    # Extract 'afg' cookie required for ajax calls
    #

    data = {
      LOGIN_USERNAME_FIELD => credentials[:username],
      LOGIN_PASSWORD_FIELD => credentials[:password],
      VIEWSTATE_FIELD => viewstate_field,
      VIEWSTATEGENERATOR_FIELD => viewstategenerator_field,
      EVENTVALIDATION_FIELD => eventvalidation_field,
      PREVIOUSPAGE_FIELD => previouspage_field,
      'IsFromNewSite' => '1'
    }

    ajax_headers = { Accept: 'application/vnd.api+json',
                     ajaxrequestuniquekey: nil }
    with_rescue([RestClient::Exceptions::OpenTimeout,
                 RestClient::ServiceUnavailable], @logger) do |_try|
      RestClient::Request.execute(method: :post,
                                  url: LOGIN_POST_URL,
                                  payload: data,
                                  cookies: jar,
                                  max_redirects: 0) do |resp, _req, _res|
        ajax_headers[:ajaxrequestuniquekey] = resp.cookies['afg']
      end
    end
    # pp jar

    #
    # Get devices
    #
    response = with_rescue([RestClient::Exceptions::OpenTimeout,
                            RestClient::ServiceUnavailable], @logger) do |_try|
      RestClient::Request.execute(method: :get,
                                  url: SENSOR_URL,
                                  headers: ajax_headers,
                                  cookies: jar)
    end
    json = JSON.parse response
    # pp json['data']

    timestamp = Time.parse(response.headers[:date]).to_i
    data = []
    json['data'].each do |sensor|
      attr = sensor['attributes']
      attr['state'] = attr['state'].to_i - 1
      next if attr['state'].negative?

      attr['description'].gsub!(/\W/, '_')
      datum = { series: 'state',
                values: { value: attr['state'] },
                tags: { description: attr['description'] },
                timestamp: timestamp }
      @logger.debug datum
      data.push datum
    end
    influxdb.write_points data unless options[:dry_run]
  rescue StandardError => e
    @logger.error e
  end
end

Frontpoint.start
