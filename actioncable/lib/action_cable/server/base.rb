require 'monitor'

module ActionCable
  module Server
    # A singleton ActionCable::Server instance is available via ActionCable.server. It's used by the Rack process that starts the Action Cable server, but
    # is also used by the user to reach the RemoteConnections object, which is used for finding and disconnecting connections across all servers.
    #
    # Also, this is the server instance used for broadcasting. See Broadcasting for more information.
    class Base
      include ActionCable::Server::Broadcasting
      include ActionCable::Server::Connections

      cattr_accessor(:config, instance_accessor: true) { ActionCable::Server::Configuration.new }

      def self.logger; config.logger; end
      delegate :logger, to: :config

      attr_reader :mutex

      def initialize
        @mutex = Monitor.new
        @remote_connections = @event_loop = @worker_pool = @channel_classes = @pubsub = nil
      end

      # Called by Rack to setup the server.
      def call(env)
        setup_heartbeat_timer
        config.connection_class.new(self, env).process
      end

      # Disconnect all the connections identified by `identifiers` on this server or any others via RemoteConnections.
      def disconnect(identifiers)
        remote_connections.where(identifiers).disconnect
      end

      def restart
        connections.each(&:close)

        @mutex.synchronize do
          puts "@mutex sync restart start"
          worker_pool.halt if @worker_pool

          @worker_pool = nil
          puts "@mutex sync restart end"
        end
      end

      # Gateway to RemoteConnections. See that class for details.
      def remote_connections
        @remote_connections || @mutex.synchronize {
          puts "@mutex remote_connections start"
          @remote_connections ||= RemoteConnections.new(self)
          puts "@mutex remote_connections end"
        }
      end

      def event_loop
        @event_loop || @mutex.synchronize {
          puts "@mutex event_loop start"
          @event_loop ||= config.event_loop_class.new
          puts "@mutex event_loop end"
        }
      end

      # The worker pool is where we run connection callbacks and channel actions. We do as little as possible on the server's main thread.
      # The worker pool is an executor service that's backed by a pool of threads working from a task queue. The thread pool size maxes out
      # at 4 worker threads by default. Tune the size yourself with config.action_cable.worker_pool_size.
      #
      # Using Active Record, Redis, etc within your channel actions means you'll get a separate connection from each thread in the worker pool.
      # Plan your deployment accordingly: 5 servers each running 5 Puma workers each running an 8-thread worker pool means at least 200 database
      # connections.
      #
      # Also, ensure that your database connection pool size is as least as large as your worker pool size. Otherwise, workers may oversubscribe
      # the db connection pool and block while they wait for other workers to release their connections. Use a smaller worker pool or a larger
      # db connection pool instead.
      def worker_pool
        @worker_pool || @mutex.synchronize {
          puts "@mutex worker_pool start"
          @worker_pool ||= ActionCable::Server::Worker.new(max_size: config.worker_pool_size)
          puts "@mutex worker_pool end"
        }
      end

      # Requires and returns a hash of all of the channel class constants, which are keyed by name.
      def channel_classes
        puts "in channel_classes #{@channel_classes}"
        @channel_classes || @mutex.synchronize do
          puts "@mutex channel_classes start"
          @channel_classes ||= begin
            puts "@mutex channel_classes first looping"
            config.channel_paths.each { |channel_path|
              puts "@mutex channel_classes start path: #{channel_path}"
              require channel_path
              puts "@mutex channel_classes done path: #{channel_path}"
            }
            puts "@mutex channel_classes second looping"
            config.channel_class_names.each_with_object({}) { |name, hash|
              puts "@mutex channel_classes classname: #{name}"
              hash[name] = name.constantize
            }
          end
          puts "@mutex channel_classes end"
        end
      end

      # Adapter used for all streams/broadcasting.
      def pubsub
        @pubsub || @mutex.synchronize {
          puts "@mutex pubsub start"
          @pubsub ||= config.pubsub_adapter.new(self)
          puts "@mutex pubsub end"
        }
      end

      # All of the identifiers applied to the connection class associated with this server.
      def connection_identifiers
        config.connection_class.identifiers
      end
    end

    ActiveSupport.run_load_hooks(:action_cable, Base.config)
  end
end
