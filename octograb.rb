require "typhoeus"
require "resolv"
require 'colorize'
require 'optparse'
require 'ruby-progressbar'

params = {}
follow_r = false

ARGV << '-h' if ARGV.empty?
option_parser = OptionParser.new do |opts|
    opts.banner = "Usage: octograb.rb [options]"
    opts.separator ""
    opts.separator "Mandatory parameters:"
    opts.on('-fFILE', '--inputfile=FILENAME', "Input file which contains a list of hostnames")
    opts.on('-cCONTENT', '--content=CONTENT', "Content string that has to match in response body")
    opts.separator "Optional parameters:"
    opts.on('-pPATH','--path=PATH', 'Specify the url path with a foregoing slash, default = /')
    opts.on('-aUSERAGENT', '--useragent=USERAGENT', "Specify the user agent string")
    opts.on('-tTHREADS', '--threads=THREADS', Integer, "Number of paralell requests. Default =  50")
    opts.on('-tTHREADS', '--threads=THREADS', Integer, "Number of paralell requests. Default =  50")
    opts.on("-r", "--follow-redirects", "Follow redirects (301)") do
        follow_r = true
    end
    opts.on("-h", "--help", "Show this message") do
        puts opts
        exit
    end
    opts.separator ""
    opts.separator "Example:"
    opts.separator "     octograb.rb -f urls.txt -p /.git/HEAD -c 'ref:'".green
    opts.separator ""
    opts.separator "Each line will be parsed and resolved in four requests. Assuming the first entry in urls.txt is 'example.com' and can be resolved to 12.12.12.12"
    opts.separator "     -> http://example.com/.git/HEAD - 'ref:' not contained in response"
    opts.separator "     -> https://example.com/.git/HEAD - 'ref:' not contained in response"
    opts.separator "     -> http://12.12.12.12/.git/HEAD - 'ref:' found in response"
    opts.separator "     -> https://12.12.12.12/.git/HEAD - 'ref:' not contained in response"
    opts.separator ""
end
option_parser.parse!(into: params)

unless params[:inputfile]
    puts option_parser.help
    puts "[-] Inputfile is missing".red
    exit 1
else
    inputfile = params[:inputfile]
    unless File.exists?(inputfile)
        puts option_parser.help
        puts "[-] Inputfile could not be found".red
        exit 1
    end
end

unless params[:content]
    puts option_parser.help
    puts "[-] Content parameter is missing".red
    exit 1
else
    content = params[:content]
end

if params[:useragent]
    Typhoeus::Config.user_agent = params[:useragent]
else
    Typhoeus::Config.user_agent = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/83.0.4103.61 Safari/537.36"
end

if params[:threads]
    hydra = Typhoeus::Hydra.new(max_concurrency: params[:threads])
else
    hydra = Typhoeus::Hydra.new(max_concurrency: 50)
end

path = params[:path] || "/"
dns = Resolv::DNS.open
progressbar = ProgressBar.create(:title => "Progress",
    :starting_at => 0,
    :total => IO.readlines(inputfile).size * 4,
    :format => "%a %b\u{15E7}%i %p%% %t",
    :progress_mark  => ' ',
    :remainder_mark => "\u{FF65}")

File.readlines(inputfile).each do |line|
    # do not overload the que
    hydra.run if hydra.queued_requests.size > 50

    r1 = Typhoeus::Request.new("http://#{line.strip}#{path}", followlocation: follow_r, timeout: 1)
    r1.on_complete do |response|
        progressbar.increment
        progressbar.log "[+] Content match: #{r1.url}".green if response.body.include? content
    end
    r2 = Typhoeus::Request.new("https://#{line.strip}#{path}", followlocation: follow_r, ssl_verifyhost: 0, timeout: 1)
    r2.on_complete do |response|
        progressbar.increment
        progressbar.log "[+] Content match: #{r2.url}".green if response.body.include? content
    end
    hydra.queue(r1)
    hydra.queue(r2)

    # check if current line is already an ip address
    unless line.strip =~ Regexp.union(Resolv::IPv4::Regex, Resolv::IPv6::Regex) ? true : false
        begin
            ip = dns.getaddress(line.strip)
            r3 = Typhoeus::Request.new("http://#{ip}#{path}", followlocation: follow_r, timeout: 1)
            r3.on_complete do |response|
                progressbar.increment
                progressbar.log "[+] Content match: #{r3.url}".green if response.body.include? content
            end
            r4 = Typhoeus::Request.new("https://#{ip}#{path}", followlocation: follow_r, timeout: 1, ssl_verifyhost: 0)
            r4.on_complete do |response|
                progressbar.increment
                progressbar.log "[+] Content match: #{r4.url}".green if response.body.include? content
            end
            hydra.queue(r3)
            hydra.queue(r4)
        rescue
            progressbar.total -= 2
        end
    else
        progressbar.total -= 2
    end
end

# run the last "< 50" requests
hydra.run