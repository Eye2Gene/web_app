# frozen_string_literal: true

require 'fileutils'
require 'json'
require 'yaml'

require 'eye2gene/config'
require 'eye2gene/exceptions'
require 'eye2gene/logger'
require 'eye2gene/routes'
require 'eye2gene/run_analysis'
require 'eye2gene/server'
require 'eye2gene/version'

# Eye2Gene NameSpace
module Eye2Gene
  class << self
    def environment
      ENV['RACK_ENV']
    end

    def verbose?
      @verbose ||= (environment == 'development')
    end

    def root
      File.dirname(File.dirname(__FILE__))
    end

    def ssl?
      @config[:ssl]
    end

    def logger
      @logger ||= Logger.new(STDOUT)
    end

    # Setting up the environment before running the app...
    # We don't validate port and host settings. If Eye2Gene is run
    # self-hosted, bind will fail on incorrect values. If Eye2Gene
    # is run via Apache/Nginx + Passenger, we don't need to worry.
    def init(config = {})
      @config = Config.new(config)
      Thread.abort_on_exception = true if verbose?

      init_dirs
      check_num_threads

      self
    end

    # default data_dir = $HOME/.eye2gene/
    # default public_dir  = $HOME/.eye2gene/public/
    # default users_dir   = $HOME/.eye2gene/users/
    # default tmp_dir     = $HOME/.eye2gene/tmp/
    attr_reader :config, :data_dir, :public_dir, :users_dir, :tmp_dir, :script_dir

    # Starting the app manually
    def run
      check_host
      Server.run(self)
    rescue Errno::EADDRINUSE
      puts "** Could not bind to port #{config[:port]}."
      puts "   Is Eye2Gene already accessible at #{server_url}?"
      puts '   No? Try running Eye2Gene on another port, like so:'
      puts
      puts '       eye2gene -p 4570.'
    rescue Errno::EACCES
      puts "** Need root privilege to bind to port #{config[:port]}."
      puts '   It is not advisable to run Eye2Gene as root.'
      puts '   Please use Apache/Nginx to bind to a privileged port.'
    end

    def on_start
      puts '** Eye2Gene is ready.'
      puts "   Go to #{server_url} in your browser & start analysing OCT Scans!"
      puts '   Press CTRL+C to quit.'
      open_in_browser(server_url)
    end

    def on_stop
      puts
      puts '** Thank you for using Eye2Gene :).'
    end

    # Rack-interface.
    #
    # Inject our logger in the env and dispatch request to our controller.
    def call(env)
      env['rack.logger'] = logger
      Routes.call(env)
    end

    # Run Eye2Gene interactively
    def pry
      # rubocop:disable Lint/Debugger
      ARGV.clear
      require 'pry'
      binding.pry
      # rubocop:enable Lint/Debugger
    end

    private

    # Set up the directory structure in @config[:gd_public_dir]
    def init_dirs
      config[:data_dir] = File.expand_path(config[:data_dir])
      logger.debug "Eye2Gene Directory: #{config[:data_dir]}"
      init_public_dir
      init_public_data_dirs
      init_script_dir
      init_tmp_dir
      init_users_dir
      set_up_default_user_dir
    end

    def init_public_dir
      @public_dir = File.join(config[:data_dir], 'public')
      logger.debug "public_dir Directory: #{@public_dir}"
      FileUtils.mkdir_p @public_dir unless Dir.exist?(@public_dir)
      root_assets = File.join(Eye2Gene.root, 'public/assets')
      assets = File.join(@public_dir, 'assets')
      css = File.join(assets, 'css', "style-#{Eye2Gene::VERSION}.min.css")
      init_assets(root_assets, assets, css)
    end

    def init_assets(root_assets, assets, css)
      if environment == 'development'
        FileUtils.rm_rf(assets) unless File.symlink?(assets)
        FileUtils.ln_s(root_assets, @public_dir) unless File.exist?(assets)
      else
        FileUtils.rm_rf(assets) if File.symlink?(assets) || !File.exist?(css)
        FileUtils.cp_r(root_assets, @public_dir) unless File.exist?(assets)
      end
    end

    def init_public_data_dirs
      root_data = File.join(Eye2Gene.root, 'public/eye2gene')
      public_gd = File.join(@public_dir, 'eye2gene')
      return if File.exist?(public_gd)
      FileUtils.cp_r(root_data, @public_dir)
    end

    def init_script_dir
      @script_dir = File.join(Eye2Gene.root, 'scripts')
      logger.debug "script_dir Directory: #{@script_dir}"
      FileUtils.mkdir_p @script_dir unless Dir.exist? @script_dir
    end


    def init_tmp_dir
      @tmp_dir = File.join(config[:data_dir], 'tmp')
      logger.debug "tmp_dir Directory: #{@tmp_dir}"
      FileUtils.mkdir_p @tmp_dir unless Dir.exist? @tmp_dir
    end

    def init_users_dir
      @users_dir = File.join(config[:data_dir], 'users')
      logger.debug "users_dir Directory: #{@users_dir}"
      FileUtils.mkdir_p @users_dir unless Dir.exist? @users_dir
    end

    def set_up_default_user_dir
      user_dir    = File.join(Eye2Gene.users_dir, 'eye2gene')
      user_public = File.join(Eye2Gene.public_dir, 'eye2gene/users')
      FileUtils.mkdir(user_dir) unless Dir.exist?(user_dir)
      return if File.exist? File.join(user_public, 'eye2gene')
      FileUtils.ln_s(user_dir, user_public)
    end

    def check_num_threads
      config[:num_threads] = Integer(config[:num_threads])
      raise NUM_THREADS_INCORRECT unless config[:num_threads] > 0

      logger.debug "Will use #{config[:num_threads]} threads to run Eye2Gene."
      return unless config[:num_threads] > 256
      logger.warn "Number of threads set at #{config[:num_threads]} is" \
                  ' unusually high.'
    end

    # Check and warn user if host is 0.0.0.0 (default).
    def check_host
      return unless config[:host] == '0.0.0.0'
      logger.warn 'Will listen on all interfaces (0.0.0.0).' \
                  ' Consider using 127.0.0.1 (--host option).'
    end

    def server_url(initial_page = '/')
      host = config[:host]
      host = 'localhost' if ['127.0.0.1', '0.0.0.0'].include? host
      "#{ssl? ? 'https' : 'http'}://#{host}:#{config[:port]}/#{initial_page}"
    end

    def open_in_browser(url)
      return if using_ssh? || verbose?
      if RUBY_PLATFORM =~ /linux/ && xdg?
        system "xdg-open #{url}"
      elsif RUBY_PLATFORM.match?(/darwin/)
        system "open #{url}"
      end
    end

    def using_ssh?
      true if ENV['SSH_CLIENT'] || ENV['SSH_TTY'] || ENV['SSH_CONNECTION']
    end

    def xdg?
      true if ENV['DISPLAY'] && system('which xdg-open > /dev/null 2>&1')
    end
  end
end
