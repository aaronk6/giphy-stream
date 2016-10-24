require 'date'
require 'tmpdir'
require 'shellwords'
require 'securerandom'
require 'json'
require 'open-uri'

class GiphyStream

  DEFAULT_API_KEY = 'dc6zaTOxFJmzC' # Giphy test key
  DEFAULT_FILE_NAME = 'Giphy_%s.mp4' % Time.now.strftime('%Y%m%dT%H%M%S')
  DEFAULT_FFMPEG_PATH = 'ffmpeg'
  TEMP_DIRECTORY_PREFIX = 'giphy-stream_'
  ENDPOINT = 'https://api.giphy.com/v1'
  MAX_RESULTS = 100 # 100 is Giphy's maximum (per request)
  TARGET_VIDEO_WIDTH = 1280
  TARGET_VIDEO_HEIGHT = 720
  SLEEP_AFTER_DELETE = 60

  def initialize(options)

    @api_key = options[:api_key] ? options[:api_key] : DEFAULT_API_KEY

    @output_file = options[:output_file] ? options[:output_file]
      : File.join(Dir.pwd, DEFAULT_FILE_NAME)

    if options[:count] and options[:count].between?(1, 100)
      @count = options[:count]
    elsif options[:count].nil?
      @count = MAX_RESULTS
    else
      $stderr.puts "Count must be between 1 and 100"
      exit 1
    end

    @ffmpeg_path = options[:ffmpeg_path] ? options[:ffmpeg_path] : DEFAULT_FFMPEG_PATH

    # invoke process
    loop_urls = get_loop_urls
    exit 1 unless create_stream(loop_urls, options[:temp_dir])

    puts "Done."
  end

  private

  def create_stream(urls, temp_dir=nil)

    if temp_dir
      dir = File.join(File.expand_path(temp_dir), TEMP_DIRECTORY_PREFIX + SecureRandom.hex)
      Dir.mkdir(dir, 0700)
    else
      dir = Dir.mktmpdir
    end

    puts "Temporary directory is %s" % dir

    files = []
    scaled_files = []

    begin
      urls.each do |url|
        path = download_file(url, dir)
        files.push(path) if path
      end

      puts "Downloaded %i file(s)" % files.count

      puts "Scaling videos to #{TARGET_VIDEO_WIDTH}x#{TARGET_VIDEO_HEIGHT}"
      files.each do |file|
        scaled_file = scale_video(file, file + '_scaled')
        File.unlink file
        scaled_files.push(scaled_file) if scaled_file
      end

      puts "Concatenating %i scaled video(s)" % scaled_files.count
      return false unless concatenate_videos(scaled_files, @output_file)
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

    cmd = [ @ffmpeg_path, '-y',
      '-i', source,
      '-loglevel', 'error',
      '-preset', 'superfast',
      '-c:v', 'libx264',
      '-r', 25,
      '-filter:v', filter,
      dest ].shelljoin

    `#{cmd}`

    if $?.to_i != 0
      $stderr.puts "Failed to convert video %s to %s" % [ source, dest ]
      return nil
    end

    dest
  end

  def concatenate_videos(files, dest)

    dir = Dir.mktmpdir
    dest << 'mp4' unless dest.end_with? 'mp4'
    dest_tmp = temp_video_name(dest)

    puts "Writing video to %s" % dest

    begin

      # write temporary concat file for ffmpeg
      list_path = File.join(dir, 'list.txt')
      File.write(list_path, files.map{|s| 'file \'%s\'' % s.shellescape }.join("\n"))

      cmd = [ @ffmpeg_path, '-y',
        '-loglevel', 'error',
        '-safe', '0',
        '-f', 'concat',
        '-i', list_path, dest_tmp,
        '-c', 'copy' ].shelljoin

      `#{cmd}`

      if $?.to_i != 0
        $stderr.puts "Failed to concatenate videos"
        FileUtils.rm_f dest_tmp
        return nil
      end

      puts "Removing existing file (if any)"
      FileUtils.rm_f dest

      puts "Waiting %i seconds" % SLEEP_AFTER_DELETE
      sleep SLEEP_AFTER_DELETE

      FileUtils.mv(dest_tmp, dest)
      return dest
    ensure
      FileUtils.remove_entry dir
    end
  end

  def download_file(url, dir)

    path = File.join(dir, SecureRandom.hex)
    puts "Downloading %s to %s" % [ url, path ]

    File.open(path, 'wb') do |f|
      begin
        open(url, 'rb') do |data|
          f.write(data.read)
        end
      rescue => e
        puts "Failed to download file from %s, skipping (%s)" % [ url, e ]
        return
      end
    end

    path
  end

  def get_loop_urls

    res = query_api 'gifs/trending'
    data = JSON.load(res)["data"]
    urls = []

    data.each do |item|
      begin
        url = item["images"]["looping"]["mp4"].strip
        urls.push(url) if url.length > 0
      rescue
        next
      end
    end

    puts "Found %i loop(s)" % urls.count
    urls
  end

  def temp_video_name(path)
    File.join(File.dirname(path), '.tmp_%s' % File.basename(path))
  end

  def query_api(route, limit=MAX_RESULTS)
    uri = URI.parse("%s/%s" % [ ENDPOINT, route ])
    uri.query = URI.encode_www_form({
      api_key: @api_key,
      limit: @count
    })
    open(uri).read
  end
end
