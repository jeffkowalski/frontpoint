#!/usr/bin/env ruby
# frozen_string_literal: true

require 'rubygems'
require 'bundler/setup'
Bundler.require(:default)

# see https://github.com/elahd/pyalarmdotcomajax/tree/master/pyalarmdotcomajax
# file:///home/jeff/.local/lib/python3.8/site-packages/pyalarmdotcomajax/__init__.py

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

class Frontpoint < RecorderBotBase
  no_commands do
    def main
      credentials = load_credentials

      soft_faults = [Errno::ECONNRESET,
                     RestClient::Exceptions::OpenTimeout,
                     RestClient::ServiceUnavailable]

      influxdb = options[:dry_run] ? nil : InfluxDB::Client.new('frontpoint')

      #
      # Phase 1
      # Get login page, passing 2FA credential
      # Extract fields required to post login
      #

      cookies = { twoFactorAuthenticationId: credentials[:twoFactorAuthenticationId] }

      response = with_rescue(soft_faults, @logger) do |_try|
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
      with_rescue(soft_faults, @logger) do |_try|
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
      response = with_rescue(soft_faults, @logger) do |_try|
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
    end
  end
end

Frontpoint.start
