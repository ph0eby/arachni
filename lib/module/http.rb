=begin
                  Arachni
  Copyright (c) 2010 Anastasios Laskos <tasos.laskos@gmail.com>

  This is free software; you can copy and distribute and modify
  this program under the term of the GPL v2.0 License
  (See LICENSE file for details)

=end

require 'typhoeus'

module Arachni
  
require Options.instance.dir['lib'] + 'typhoeus/request'
require Options.instance.dir['lib'] + 'module/trainer'

module Module

#
# Arachni::Module::HTTP class
#
# Provides a simple, high-performance and thread-safe HTTP interface to modules.
#
# All requests are run Async (compliements of Typhoeus)
# providing great speed and performance.
#
# === Exceptions
# Any exceptions or session corruption is handled by the class.<br/>
# Some are ignored, on others the HTTP session is refreshed.<br/>
# Point is, you don't need to worry about it.
#
# @author: Anastasios "Zapotek" Laskos 
#                                      <tasos.laskos@gmail.com>
#                                      <zapotek@segfault.gr>
# @version: 0.2
#
class HTTP

    include Output
    include Singleton
    
    #
    # @return [URI]
    #
    attr_reader :last_url
    
    #
    # The headers with which the HTTP client is initialized<br/>
    # This is always kept updated.
    # 
    # @return    [Hash]
    #
    attr_reader :init_headers
    
    #
    # The user supplied cookie jar
    #
    # @return    [Hash]
    #
    attr_reader :cookie_jar
    
    attr_reader :request_count
    
    #
    # Initializes the HTTP session given a start URL respecting
    # system wide settings for HTTP basic auth and proxy
    #
    # @param  [String]  url  start URL
    #
    def initialize( )
        opts = Options.instance
        req_limit = opts.http_req_limit
        @hydra ||= Typhoeus::Hydra.new(
            :max_concurrency               => req_limit,
            :disable_ssl_peer_verification => true,
            :username                      => opts.url.user,
            :password                      => opts.url.password,
            :method                        => :auto
        )
          
        @hydra.disable_memoization
        
        @trainers = []
        @trainer = Arachni::Module::Trainer.instance
        @trainer.http = self
        
        @init_headers               = Hash.new
        @init_headers['cookie']     = ''
        
        @opts = {
            :user_agent      => Options.instance.user_agent,
            :follow_location => false
        }

        @__not_found  = nil
        
        @request_count = 0
    end
    
    #
    # Runs Hydra (all the queued HTTP requests)
    #
    # Should only be called by the framework
    # after all module threads have beed joined!
    #
    def run
        @hydra.run
    end
    
    #
    # Queues a Tyhpoeus::Request and applies an 'on_complete' callback 
    # on behal of the trainer.
    #
    # @param  [Tyhpoeus::Request]  req  the request to queue
    #
    def queue( req )
        
        req.id = @request_count
        @last_url = req.url
        
        @hydra.queue( req )

        @request_count += 1

        print_debug( '------------' )
        print_debug( 'Queued request.' )
        print_debug( 'ID#: ' + req.id.to_s )
        print_debug( 'URL: ' + req.url )
        print_debug( 'Method: ' + req.method.to_s  )
        print_debug( 'Params: ' + req.params.to_s  )
        print_debug( 'Headers: ' + req.headers.to_s  )
        print_debug( 'Train?: ' + req.train?.to_s  )
        print_debug(  '------------' )

        req.on_complete( true ) {
            |res|
            
            print_debug( '------------' )
            print_debug( 'Got response.' )
            print_debug( 'Request ID#: ' + res.request.id.to_s )
            print_debug( 'URL: ' + res.effective_url )
            print_debug( 'Method: ' + res.request.method.to_s  )
            print_debug( 'Params: ' + res.request.params.to_s  )
            print_debug( 'Headers: ' + res.request.headers.to_s  )
            print_debug( 'Train?: ' + res.request.train?.to_s  )
            print_debug( '------------' )
            
            if( req.train? )
                # handle redirections
                if( ( redir = redirect?( res.dup ) ).is_a?( String ) )
                    req2 = get( redir, nil, true )
                    req2.on_complete {
                        |res2|
                        @trainer.add_response( res2, true )
                    }
                else
                    @trainer.add_response( res )
                end
            end
        }
    end

    #
    # Gets a URL passing the provided query parameters
    #
    # @param  [URI]  url     URL to GET
    # @param  [Hash] params  hash with name=>value pairs
    #
    # @return [Typhoeus::Request]
    #
    def get( url, params = {}, remove_id = false, train = false )
        params = { } if !params
        
        params = params.merge( { '__arachni__' => '' } ) if !remove_id 
        #
        # the exception jail function wraps the block passed to it
        # in exception handling and runs it
        #
        # how cool is Ruby? Seriously....
        #
        exception_jail {
            
            opts = {
                :headers       => @init_headers.dup,
                :params        => params,
                :follow_location => false
            }.merge( @opts )
            
            req = Typhoeus::Request.new( url, opts )
            req.train! if train
            
            queue( req )
            return req
        }
        
    end

    #
    # Posts a form to a URL with the provided query parameters
    #
    # @param  [URI]   url     URL to POST
    # @param  [Hash]  params  hash with name=>value pairs
    #
    # @return [Typhoeus::Request]
    #
    def post( url, params = { }, train = false )

        exception_jail {
            
            opts = {
                :method        => :post,
                :headers       => @init_headers.dup,
                :params        => params,
                :follow_location => false
            }.merge( @opts )

            req = Typhoeus::Request.new( url, opts )
            req.train! if train
            
            queue( req )
            return req
        }
    end

    #
    # Gets a url with cookies and url variables
    #
    # @param  [URI]   url      URL to GET
    # @param  [Hash]  cookies  hash with name=>value pairs
    # @param  [Hash]  params   hash with GET name=>value pairs
    #
    # @return [Typhoeus::Request]
    #
    def cookie( url, cookies, params = nil, train = false )

        jar = parse_cookie_str( @init_headers['cookie'] )
        
        cookies.reject! {
            |cookie|
            Options.instance.exclude_cookies.include?( cookie['name'] )
        }
        
        cookies = jar.merge( cookies )
        
        # wrap the code in exception handling
        exception_jail {

            opts = {
                :headers       => { 'cookie' => get_cookies_str( cookies ) },
                :follow_location => false,
                :params        => params
            }.merge( @opts )

            req = Typhoeus::Request.new( url, opts )
            req.train! if train
            
            queue( req )
            return req
        }
    end

    #
    # Gets a url with optional url variables and modified headers
    #
    # @param  [URI]  url      URL to GET
    # @param  [Hash] headers  hash with name=>value pairs
    # @param  [Hash] params   hash with name=>value pairs
    #
    # @return [Typhoeus::Request]
    #
    def header( url, headers, params = { }, train = false )
        
        params = {} if !params
        # wrap the code in exception handling
        exception_jail {
            
            orig_headers  = @init_headers.clone
            @init_headers = @init_headers.merge( headers )
            
            req = Typhoeus::Request.new( url,
                :headers       => @init_headers.dup,
                :user_agent    => @init_headers['User-Agent'],
                :follow_location => false,
                :params        => params )
            req.train! if train
            
            @init_headers = orig_headers.clone
            
            queue( req )
            return req
        }

    end

    #
    # Sets cookies for the HTTP session
    #
    # @param    [Hash]  cookies  name=>value pairs
    #
    # @return   [void]
    #
    def set_cookies( cookies )
        @init_headers['cookie'] = ''
        @cookie_jar = cookies.each_pair {
            |name, value|
            @init_headers['cookie'] += "#{name}=#{value};" 
        }
    end
    
    #
    # Gets a hash of cookies as a string
    #
    # @param    [Hash]  cookies  name=>value pairs
    #
    # @return   [string]
    #
    def get_cookies_str( cookies )
        str = ''
        cookies.each_pair {
            |name, value|
            str += "#{name}=#{value};" 
        }
        return str
    end

    #
    # Converts HTTP cookies from string to Hash
    #
    # @param  [String]  str
    #
    # @return  [Hash]
    #
    def parse_cookie_str( str )
        cookie_jar = Hash.new
        str.split( ';' ).each {
            |kvp|
            cookie_jar[kvp.split( "=" )[0]] = kvp.split( "=" )[1] 
        }
        return cookie_jar
    end
    
    #
    # Class method
    #
    # Parses netscape HTTP cookie files
    #
    # @param    [String]  cookie_jar  the location of the cookie file
    #
    # @return   [Hash]    cookies     in name=>value pairs
    #    
    def HTTP.parse_cookiejar( cookie_jar )
        
        cookies = Hash.new
        
        jar = File.open( cookie_jar, 'r' ) 
        jar.each_line {
            |line|
            
            # skip empty lines
            if (line = line.strip).size == 0 then next end
                
            # skip comment lines
            if line[0] == '#' then next end
                
            cookie_arr = line.split( "\t" )
            
            cookies[cookie_arr[-2]] = cookie_arr[-1]
        }
        
        cookies
    end
    
    #
    # Encodes and parses a URL String
    #
    # @param [String] url URL String
    #
    # @return [URI] URI object
    #
    def parse_url( url )
        URI.parse( URI.encode( url ) )
    end

    #
    # Checks whether or not the provided HTML code is a custom 404 page
    #
    # @param  [String]  html  the HTML code to check
    #
    # @param  [Bool]
    #
    def custom_404?( html )
        
        if( !@__not_found )
            
            path = Module::Utilities.get_path( @last_url.to_s )
            
            # force a 404 and grab the html body
            force_404    = path + Digest::SHA1.hexdigest( rand( 9999999 ).to_s ) + '/'
            @__not_found = Typhoeus::Request.get( force_404 ).body
            
            # force another 404 and grab the html body
            force_404   = path + Digest::SHA1.hexdigest( rand( 9999999 ).to_s ) + '/'
            not_found2  = Typhoeus::Request.get( force_404 ).body
            
            #
            # some websites may have dynamic 404 pages or simply include
            # the query that caused the 404 in the 404 page causing the 404 pages to change.
            #
            # so get rid of the differences between the 2 404s (if there are any)
            # and store what *doesn't* change into @__404
            #
            @__404 = Arachni::Module::Utilities.rdiff( @__not_found, not_found2 )
        end
        
        #
        # get the rdiff between 'html' and an actual 404
        #
        # if this rdiff matches the rdiff in @__404 then by extension
        # the 'html' is a 404
        # 
        return Arachni::Module::Utilities.rdiff( @__not_found, html ) == @__404
    end

    private
    
    def redirect?( res )
        if loc = res.headers_hash['Location']
            return loc
        end
        return res
    end

    #
    # Wraps the "block" in exception handling code and runs it.
    #
    # @param    [Block]
    #
    def exception_jail( &block )
        
        begin
            block.call

        # catch the time-out and refresh
        rescue Timeout::Error => e
            # inform the user
            print_error( 'Error: ' + e.to_s + " in URL " + url.to_s )
            print_info( 'Refreshing connection...' )
            
            # refresh the connection
            refresh( )
            # try one more time
            retry

        # broken pipe probably
        rescue Errno::EPIPE => e
            # inform the user
            print_error( 'Error: ' + e.to_s + " in URL " + url.to_s )
            print_info( 'Refreshing connection...' )
            
            # refresh the connection
            refresh( )
            # try one more time
            retry
        
        # some other exception
        # just print what went wrong with some debugging info and move on
        rescue Exception => e
            handle_exception( e )
        end
    end
    
    #
    # Handles an exception outputting info about it and the environment<br/>
    # when it occured, depending on the output settings.
    #
    # @param    [Exception]     e
    #
    def handle_exception( e )
        print_error( 'Error: ' + e.to_s + " in URL " + @last_url.to_s )
        print_debug( 'Exception: ' +  e.inspect )
        print_debug( 'Backtrace: ' )
        print_debug_backtrace( e )
        print_debug( '@ ' +  __FILE__ + ':' + __LINE__.to_s )
        print_debug( 'Hydra session:' )
        print_debug_pp( @hydra )
        print_error( 'Proceeding anyway... ' )
    end
    
    def self.info
      { :name => 'HTTP' }
    end
       
end
end
end
