require 'date'
require 'tmpdir'
require 'shellwords'
require 'securerandom'
require 'json'
require 'open-uri'
require 'logger'

class GiphyStream

  DEFAULT_API_KEY = 'dc6zaTOxFJmzC' # Giphy test key
  DEFAULT_FILE_NAME = 'Giphy_%s.mp4' % Time.now.strftime('%Y%m%dT%H%M%S')
  DEFAULT_FFMPEG_PATH = 'ffmpeg'
  DEFAULT_CPULIMIT_PATH = 'cpulimit'
  DEFAULT_FFMPEG_CPU_LIMIT = 0 # unlimited
  DEFAULT_FFMPEG_THREADS = 0 # unlimited
  DEFAULT_VIDEO_COUNT = 100 # number of loops retrieve from Giphy
  HLS_STREAM_NAME = 'giphy.m3u8'
  TEMP_DIRECTORY_PREFIX = 'giphy-stream_'
  ENDPOINT = 'https://api.giphy.com/v1'
  BATCH_SIZE = 100 # 100 is Giphy's maximum per request
  MAX_REQUESTS = 10 # maximum number of requests to perform before giving up
  MAX_RETRIES = 100
  TARGET_VIDEO_WIDTH = 1280
  TARGET_VIDEO_HEIGHT = 720
  SLEEP_AFTER_DELETE = 60

  def initialize(options)

    @api_key = options[:api_key] ? options[:api_key] : DEFAULT_API_KEY

    if options[:log_file]
      log_file = File.open(options[:log_file], 'a')
      log_file.sync = true
      @logger = Logger.new(log_file, 'weekly')
    else
      @logger = Logger.new(STDOUT)
      @logger.formatter = proc do |severity, datetime, progname, msg|
        "#{msg}\n"
     end
    end

    @output_path = options[:output_path] ? File.expand_path(options[:output_path])
      : File.join(Dir.pwd, DEFAULT_FILE_NAME)

    if options[:count] and options[:count].between?(1, 1000)
      @count = options[:count]
    elsif options[:count].nil?
      @count = DEFAULT_VIDEO_COUNT
    else
      $stderr.puts "Count must be between 1 and 100"
      exit 1
    end

    @cpulimit_path = options[:cpulimit_path] ? options[:cpulimit_path] : DEFAULT_CPULIMIT_PATH
    @ffmpeg_path = options[:ffmpeg_path] ? options[:ffmpeg_path] : DEFAULT_FFMPEG_PATH
    @ffmpeg_cpu_limit = options[:ffmpeg_cpu_limit] ? options[:ffmpeg_cpu_limit].to_i : DEFAULT_FFMPEG_CPU_LIMIT
    @ffmpeg_threads = options[:ffmpeg_threads] ? options[:ffmpeg_threads].to_i : DEFAULT_FFMPEG_THREADS

    # invoke process
    loop_urls = get_loop_urls
    exit 1 unless create_stream(loop_urls, options[:temp_dir])

    @logger.info "Done."
  end

  private

  def create_stream(urls, temp_dir=nil)

    if temp_dir
      dir = File.join(File.expand_path(temp_dir), TEMP_DIRECTORY_PREFIX + SecureRandom.hex)
      Dir.mkdir(dir, 0700)
    else
      dir = Dir.mktmpdir
    end

    @logger.info "Temporary directory is %s" % dir

    files = []
    scaled_files = []
    stream_path = File.join Time.now.strftime("%Y-%m-%d_%H-%M-%S"), HLS_STREAM_NAME

    begin
      urls.each do |url|
        path = download_file(url, dir)
        files.push(path) if path
      end

      if files.count == 0
        @logger.fatal "No videos downloaded"
        return false
      end

      @logger.info "Downloaded %i file(s)" % files.count

      @logger.info "Scaling videos to #{TARGET_VIDEO_WIDTH}x#{TARGET_VIDEO_HEIGHT}"
      files.each do |file|
        scaled_file = scale_video(file, file + '_scaled')
        File.unlink file
        scaled_files.push(scaled_file) if scaled_file
      end

      @logger.info "Concatenating %i scaled video(s)" % scaled_files.count
      return false unless concatenate_videos(scaled_files, @output_path, stream_path)

      @logger.info "Writing .htaccess"
      return false unless write_htaccess(@output_path, stream_path)

      return true
    ensure
      FileUtils.remove_entry dir
    end
  end

  def scale_video(source, dest)
    w = TARGET_VIDEO_WIDTH
    h = TARGET_VIDEO_HEIGHT

    dest += '.mp4'

    # force to target width dimensions but keep aspect ratio (adding black bars)
    filter = "scale=iw*min(#{w}/iw\\,#{h}/ih):ih*min(#{w}/iw\\,#{h}/ih)," +
      "pad=#{w}:#{h}:(#{w}-iw*min(#{w}/iw\\,#{h}/ih))/2:(#{h}-ih*min(#{w}/iw\\,#{h}/ih))/2," +
      "setsar=1:1"

    cmd = apply_cpu_limit([ @ffmpeg_path, '-y',
      '-i', source,
      '-loglevel', 'error',
      '-preset', 'superfast',
      '-c:v', 'libx264',
      '-r', 25,
      '-filter:v', filter,
      '-threads', @ffmpeg_threads,
      dest ], @ffmpeg_cpu_limit).shelljoin

    `#{cmd}`

    if $?.to_i != 0
      @logger.fatal "Failed to convert video %s to %s" % [ source, dest ]
      return nil
    end

    dest
  end

  def concatenate_videos(files, dest, stream_path)

    dir = Dir.mktmpdir

    base_dir = File.join(dest, File.dirname(stream_path))
    stream_name = File.basename(stream_path)

    @logger.info "Writing stream to %s" % File.join(dest, stream_path)

    begin

      # write temporary concat file for ffmpeg
      list_path = File.join(dir, 'list.txt')
      File.write(list_path, files.map{|s| 'file \'%s\'' % s.shellescape }.join("\n"))    

      cmd = apply_cpu_limit([ @ffmpeg_path, '-y',
        '-loglevel', 'error',
        '-safe', '0',
        '-f', 'concat',
        '-i', list_path,
        '-c', 'copy',
        '-f', 'hls',
        '-hls_list_size', '0',
        '-threads', @ffmpeg_threads,
        File.basename(stream_path)
      ], @ffmpeg_cpu_limit).shelljoin

      FileUtils.mkdir_p base_dir
      Dir.chdir base_dir

      `#{cmd}`

      if $?.to_i != 0
        @logger.fatal "Failed to concatenate videos"
        return false
      end

    ensure
      FileUtils.remove_entry dir
    end

    return true
  end

  def write_htaccess(dest, stream_path)
    dirname = File.basename(dest)
    File.write(File.join(dest, '.htaccess'),
      "RedirectMatch temp ^.*/#{dirname}/$ $1/#{dirname}/#{stream_path}\n" +
      "RedirectMatch temp ^.*/#{dirname}/#{HLS_STREAM_NAME}$ $1/#{dirname}/#{stream_path}\n")
  end

  def apply_cpu_limit(cmd, limit=0)
    if limit > 0
      return [ @cpulimit_path, '-i', '-l', limit, '--' ] + cmd
    end
    return cmd
  end

  def download_file(url, dir)

    path = File.join(dir, SecureRandom.hex)
    @logger.info "Downloading %s to %s" % [ url, path ]

    File.open(path, 'wb') do |f|
      begin
        open(url, 'rb') do |data|
          f.write(data.read)
        end
      rescue => e
        @logger.warn "Failed to download file from %s, skipping (%s)" % [ url, e ]
        return
      end
    end

    path
  end

  def get_loop_urls
    @logger.info "Getting loop URLs"

    urls = []
    request_counter = 0

    while urls.length < @count and request_counter < MAX_REQUESTS

      res = query_api('gifs/trending', request_counter * BATCH_SIZE)
      data = JSON.load(res)["data"]

      data.each do |item|
        begin
          url = item["images"]["looping"]["mp4"].strip
          urls.push(url) if url.length > 0
        rescue
          next
        end
        break if urls.length >= @count
      end

      # one dot per request
      if $stdout.isatty
        print '.'
        STDOUT.flush
      end

      request_counter += 1
    end
    puts if $stdout.isatty # print new line

    @logger.info "Retrieved %i loop URL(s) in %i requests" % [ urls.count, request_counter ]
    urls
  end

  def temp_video_name(path)
    File.join(File.dirname(path), '.tmp_%s' % File.basename(path))
  end

  def query_api(route, offset=0, limit=BATCH_SIZE)
    uri = URI.parse("%s/%s" % [ ENDPOINT, route ])
    
    uri.query = URI.encode_www_form({
      api_key: @api_key,
      offset: offset,
      limit: limit,
    })

    retries = 0
    begin
      return open(uri).read
    rescue => e
      if (retries += 1) <= MAX_RETRIES
        @logger.warn "Failed to connect to Giphy API (#{e}), retrying in #{retries} second(s)..."
        sleep(retries)
        retry
      else
        raise
      end
    end

  end
end
