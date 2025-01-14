# frozen_string_literal: true

module Switchman
  module ActiveRecord
    module TestFixtures
      FORBIDDEN_DB_ENVS = %i[development production].freeze
      def setup_fixtures(config = ::ActiveRecord::Base)
        super

        return unless run_in_transaction?

        # Replace the one that activerecord natively uses with a switchman-optimized one
        ::ActiveSupport::Notifications.unsubscribe(@connection_subscriber)
        # Code adapted from the code in rails proper
        @connection_subscriber = ::ActiveSupport::Notifications.subscribe('!connection.active_record') do |_, _, _, _, payload|
          spec_name = payload[:spec_name] if payload.key?(:spec_name)
          shard = payload[:shard] if payload.key?(:shard)
          setup_shared_connection_pool

          if spec_name && !FORBIDDEN_DB_ENVS.include?(shard)
            begin
              connection = ::ActiveRecord::Base.connection_handler.retrieve_connection(spec_name, shard: shard)
            rescue ::ActiveRecord::ConnectionNotEstablished, ::ActiveRecord::NoDatabaseError
              connection = nil
            end

            if connection && !@fixture_connections.include?(connection)
              connection.begin_transaction joinable: false, _lazy: false
              connection.pool.lock_thread = true if lock_threads
              @fixture_connections << connection
            end
          end
        end
      end

      def enlist_fixture_connections
        setup_shared_connection_pool

        ::ActiveRecord::Base.connection_handler.connection_pool_list.reject { |cp| FORBIDDEN_DB_ENVS.include?(cp.db_config.env_name.to_sym) }.map(&:connection)
      end
    end
  end
end
