require 'coffee-script'
require 'json'
require 'rufus/scheduler'
require 'sass'
require 'sinatra'
require 'sinatra/content_for'
require 'sinatra/streaming'
require 'sprockets'
require 'yaml'

SCHEDULER = Rufus::Scheduler.new

def development?
  ENV['RACK_ENV'] == 'development'
end

def production?
  ENV['RACK_ENV'] == 'production'
end

helpers Sinatra::ContentFor
helpers do
  def protected!
    # override with auth logic
  end

  def authenticated?(token)
    return true unless settings.auth_token
    token && Rack::Utils.secure_compare(settings.auth_token, token)
  end
end

set :root, Dir.pwd
set :sprockets,     Sprockets::Environment.new(settings.root)
set :assets_prefix, '/assets'
set :digest_assets, false
set server: 'puma', connections: [], history_file: 'history.yml'
set :public_folder, File.join(settings.root, 'public')
set :views, File.join(settings.root, 'dashboards')
set :default_dashboard, nil
set :auth_token, nil

if File.exists?(settings.history_file)
  set history: YAML.load_file(settings.history_file)
else
  set history: {}
end

%w(javascripts stylesheets fonts images).each do |path|
  settings.sprockets.append_path("assets/#{path}")
end

['widgets', File.expand_path('../../../javascripts', __FILE__)]. each do |path|
  settings.sprockets.append_path(path)
end

not_found do
  send_file File.join(settings.public_folder, '404.html'), status: 404
end

at_exit do
  File.write(settings.history_file, settings.history.to_yaml)
end

get '/' do
  protected!
  dashboard = settings.default_dashboard || first_dashboard
  raise Exception.new('There are no dashboards available') if not dashboard

  redirect "/" + dashboard
end


get '/events', provides: 'text/event-stream' do
  protected!
  response.headers['X-Accel-Buffering'] = 'no' # Disable buffering for nginx
  stream do |out|
    out << latest_events
    settings.connections << connection = {out: out, mutex: Mutex.new, terminated: false}
    terminated = false

    loop do
      connection[:mutex].synchronize do
        terminated = true if connection[:terminated]
      end
      break if terminated
    end

    settings.connections.delete(connection)
  end
end

get '/:dashboard' do
  protected!
  tilt_html_engines.each do |suffix, _|
    file = File.join(settings.views, "#{params[:dashboard]}.#{suffix}")
    return render(suffix.to_sym, params[:dashboard].to_sym) if File.exist? file
  end

  halt 404
end

post '/dashboards/:id' do
  request.body.rewind
  body = JSON.parse(request.body.read)
  body['dashboard'] ||= params['id']
  if authenticated?(body.delete("auth_token"))
    send_event(params['id'], body, 'dashboards')
    204 # response without entity body
  else
    status 401
    "Invalid API key\n"
  end
end

post '/widgets/:id' do
  request.body.rewind
  body = JSON.parse(request.body.read)
  if authenticated?(body.delete("auth_token"))
    send_event(params['id'], body)
    204 # response without entity body
  else
    status 401
    "Invalid API key\n"
  end
end

get '/views/:widget?.html' do
  protected!
  tilt_html_engines.each do |suffix, engines|
    file = File.join(settings.root, "widgets", params[:widget], "#{params[:widget]}.#{suffix}")
    return engines.first.new(file).render if File.exist? file
  end
end

def send_event(id, body, target=nil)
  body[:id] = id
  body[:updatedAt] ||= Time.now.to_i
  event = format_event(body.to_json, target)
  Sinatra::Application.settings.history[id] = event unless target == 'dashboards'
  Sinatra::Application.settings.connections.each do |connection|
    connection[:mutex].synchronize do
      begin
        connection[:out] << event unless connection[:out].closed?
      rescue Puma::ConnectionError
        connection[:terminated] = true
      rescue Exception => e
        connection[:terminated] = true
        puts e
      end
    end
  end
end

def format_event(body, name=nil)
  str = ""
  str << "event: #{name}\n" if name
  str << "data: #{body}\n\n"
end

def latest_events
  settings.history.inject("") do |str, (id, body)|
    str << body
  end
end

def first_dashboard
  files = Dir[File.join(settings.views, '*')].collect { |f| File.basename(f, '.*') }
  files -= ['layout']
  files.sort.first
end

def tilt_html_engines
  Tilt.mappings.select do |_, engines|
    default_mime_type = engines.first.default_mime_type
    default_mime_type.nil? || default_mime_type == 'text/html'
  end
end

def require_glob(relative_glob)
  Dir[File.join(settings.root, relative_glob)].each do |file|
    require file
  end
end

settings_file = File.join(settings.root, 'config/settings.rb')
require settings_file if File.exists?(settings_file)

{}.to_json # Forces your json codec to initialize (in the event that it is lazily loaded). Does this before job threads start.
job_path = ENV["JOB_PATH"] || 'jobs'
require_glob(File.join('lib', '**', '*.rb'))
require_glob(File.join(job_path, '**', '*.rb'))
