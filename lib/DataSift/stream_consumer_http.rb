$LOAD_PATH.unshift(File.dirname(__FILE__) + '/../')

require 'uri'
require 'socket'
require 'yajl'
require 'cgi'

module DataSift
	#The HTTP implementation of the StreamConsumer.
	class StreamConsumer_HTTP < StreamConsumer
		#Constructor. Requires valid user and definition objects.
		#=== Parameters
		#* +user+ - The user consuming the data.
		#* +definition+ - The Definition to consume.
		def initialize(user, definition)
			super
		end

		#Called when the consumer is started.
		#=== Parameters
		#* +block+ - A block to receive incoming data.
		def onStart(&block)
			begin
				reconnect() unless !@socket.nil? and !@socket.closed?

				parser = Yajl::Parser.new
				parser.on_parse_complete = block if block_given?
				if @response_head[:headers]["Transfer-Encoding"] == 'chunked'
					if block_given?
						chunkLeft = 0
						while !@socket.eof? && (line = @socket.gets) && @state == StreamConsumer::STATE_RUNNING
							break if line.match /^0.*?\r\n/
							next if line == "\r\n"
							size = line.hex
							json = @socket.read(size)
							next if json.nil?
							chunkLeft = size-json.size
							if chunkLeft == 0
								if json.length > 100
									parser << json
								end
							else
								# received only part of the chunk, grab the rest
								received_data = @socket.read(chunkLeft)
								if not received_data.nil?
									parser << received_data
								end
							end
						end
					else
						raise StreamError, 'Chunked responses detected, but no block given to handle the chunks.'
					end
				else
					content_type = @response_head[:headers]['Content-Type'].split(';')
					content_type = content_type.first
					if ALLOWED_MIME_TYPES.include?(content_type)
						case @response_head[:headers]['Content-Encoding']
						when 'gzip'
							return Yajl::Gzip::StreamReader.parse(@socket, opts, &block)
						when 'deflate'
							return Yajl::Deflate::StreamReader.parse(@socket, opts.merge({:deflate_options => -Zlib::MAX_WBITS}), &block)
						when 'bzip2'
							return Yajl::Bzip2::StreamReader.parse(@socket, opts, &block)
						else
							return parser.parse(@socket)
						end
					else
						raise StreamError, 'Unhandled response MIME type ' + content_type
					end
				end
			end while @auto_reconnect and @state == StreamConsumer::STATE_RUNNING

			disconnect()

			if @state == StreamConsumer::STATE_STOPPING
				@stop_reason = 'Stop requested'
			else
				@stop_reason = 'Connection dropped'
			end

			onStop(@stop_reason)
		end

  private

  	#Reconnect the stream socket.
		def reconnect()
			uri = URI.parse('http' + (@user.use_ssl ? 's' : '') + '://' + User::STREAM_BASE_URL + @definition.hash)

			user_agent = @user.getUserAgent()

			request = "GET #{uri.path}#{uri.query ? "?"+uri.query : nil} HTTP/1.1\r\n"
			request << "Host: #{uri.host}\r\n"
			request << "User-Agent: #{user_agent}\r\n"
			request << "Accept: */*\r\n"
			request << "Auth: #{@user.username}:#{@user.api_key}\r\n"
			request << "\r\n"

			connection_delay = 0

			begin
				# Close the socket if it's open
				disconnect()

				# Back off a bit if required
				sleep(connection_delay) if connection_delay > 0

				begin
					@raw_socket = TCPSocket.new(uri.host, uri.port)
					if @user.use_ssl
						@socket = OpenSSL::SSL::SSLSocket.new(@raw_socket)
						@socket.connect
					else
						@socket = @raw_socket
					end

					@socket.write(request)
					@response_head = {}
					@response_head[:headers] = {}

					# Read the headers
					@socket.each_line do |line|
						if line == "\r\n" # end of the headers
							break
						else
							header = line.split(": ")
							if header.size == 1
								header = header[0].split(" ")
								@response_head[:version] = header[0]
								@response_head[:code] = header[1].to_i
								@response_head[:msg] = header[2]
							else
								@response_head[:headers][header[0]] = header[1].strip
							end
						end
					end

					if @response_head[:code].nil?
						raise StreamError, 'Socket connection refused'
					elsif @response_head[:code] == 200
						# Success!
						@state = StreamConsumer::STATE_RUNNING
					elsif @response_head[:code] >= 399 && @response_head[:code] < 500 && @response_head[:code] != 420
						line = ''
						while !@socket.eof? && line.length < 10
							line = @socket.gets
						end
						data = Yajl::Parser.parse(line)
						if data.has_key?('message')
							raise StreamError, data['message']
						else
							raise StreamError, 'Connection refused: ' + @response_head[:code] + ' ' + @response_head[:msg]
						end
					else
						if connection_delay == 0
							connection_delay = 10;
						elsif connection_delay < 240
							connection_delay *= 2;
						else
							raise StreamError, 'Connection refused: ' + @response_head[:code] + ' ' + @response_head[:msg]
						end
					end
				rescue
					if connection_delay == 0
						connection_delay = 1
					elsif connection_delay <= 16
						connection_delay += 1
					else
						raise StreamError, 'Connection failed due to a network error'
					end
				end
			end while @state != StreamConsumer::STATE_RUNNING
		end

		#Disconnect the stream socket.
		def disconnect()
			@socket.close if !@socket.nil? and !@socket.closed?
			@raw_socket.close if !@raw_socket.nil? and !@raw_socket.closed?
		end
	end
end
