require 'mixlib/shellout'
require 'timeout'

require_relative 'consul'

# For testing purposes, if the first path cannot be found load the second
begin
  require_relative '../../omnibus-ctl/lib/gitlab_ctl'
rescue LoadError
  require_relative '../../gitlab-ctl-commands/lib/gitlab_ctl'
end

class Repmgr
  class MasterError < StandardError; end

  class EventError < StandardError; end

  attr_accessor :command, :subcommand, :args

  def initialize(command, subcommand, args = nil)
    @command = Kernel.const_get("#{self.class}::#{command.capitalize}")
    @subcommand = subcommand
    @args = args
  end

  def execute
    @command.send(subcommand, @args)
  end

  class Base
    class << self
      def repmgr_cmd(args, command)
        runas = if Etc.getpwuid.name.eql?('root')
                  'gitlab-psql'
                else
                  Etc.getpwuid.name
                end
        cmd("/opt/gitlab/embedded/bin/repmgr #{args[:verbose]} -f /var/opt/gitlab/postgresql/repmgr.conf #{command}", runas)
      end

      def execute_psql(options)
        database = options[:database]
        query = options[:query]
        host = options[:host]
        port = options[:port]
        user = options[:user] || Etc.getpwuid.name
        command = %(/opt/gitlab/embedded/bin/psql -qt -d #{database} -h #{host} -p #{port} -c "#{query}" -U #{user})
        cmd(command, Etc.getpwuid.name).chomp.lines.map(&:strip)
      end

      def cmd(command, user = 'root')
        results = Mixlib::ShellOut.new(
          command,
          user: user,
          cwd: '/tmp',
          # Allow a week before timing out.
          timeout: 604800
        )
        begin
          results.run_command
          results.error!
        rescue Mixlib::ShellOut::ShellCommandFailed
          $stderr.puts "Error running command: #{results.command}"
          $stderr.puts "ERROR: #{results.stderr}" unless results.stderr.empty?
          raise
        rescue Mixlib::ShellOut::CommandTimeout
          $stderr.puts "Timeout running command: #{results.command}"
          raise
        rescue StandardError => se
          puts "Unknown Error: #{se}"
        end
        # repmgr logs most output to stderr by default
        return results.stdout unless results.stdout.empty?
        results.stderr
      end

      def repmgr_with_args(command, args)
        repmgr_cmd(args, "-h #{args[:primary]} -U #{args[:user]} -d #{args[:database]} -D #{args[:directory]} #{command}")
      end

      def wait_for_postgresql(timeout)
        # wait for *timeout* seconds for postgresql to respond to queries
        Timeout.timeout(timeout) do
          results = nil
          loop do
            begin
              results = cmd("gitlab-psql -l")
            rescue Mixlib::ShellOut::ShellCommandFailed
              sleep 1
              next
            else
              break
            end
          end
        end
      rescue Timeout::TimeoutError
        raise TimeoutError("Timed out waiting for PostgreSQL to start")
      end

      def restart_daemon
        cmd('gitlab-ctl restart repmgrd')
      end
    end
  end

  class Standby < Base
    class << self
      def clone(args)
        repmgr_with_args('standby clone', args)
      end

      def follow(args)
        repmgr_with_args('standby follow', args)
      end

      def promote(args)
        repmgr_cmd(args, 'standby promote')
      end

      def register(args)
        repmgr_cmd(args, 'standby register')
        restart_daemon
      end

      def unregister(args)
        return repmgr_cmd(args, "standby unregister --node=#{args[:node]}") unless args[:node].nil?
        repmgr_cmd(args, "standby unregister")
      end

      def setup(args)
        if args[:wait]
          $stdout.puts "Doing this will delete the entire contents of #{args[:directory]}"
          $stdout.puts "If this is not what you want, hit Ctrl-C now to exit"
          $stdout.puts "To skip waiting, rerun with the -w option"
          $stdout.puts "Sleeping for 30 seconds"
          sleep 30
        end
        $stdout.puts "Stopping the database"
        cmd("gitlab-ctl stop postgresql")
        $stdout.puts "Removing the data"
        cmd("rm -rf /var/opt/gitlab/postgresql/data")
        $stdout.puts "Cloning the data"
        clone(args)
        $stdout.puts "Starting the database"
        cmd("gitlab-ctl start postgresql")
        # Wait until postgresql is responding to queries before proceeding
        wait_for_postgresql(30)
        $stdout.puts "Registering the node with the cluster"
        register(args)
      end
    end
  end

  class Cluster < Base
    class << self
      def show(args)
        repmgr_cmd(args, 'cluster show')
      end
    end
  end

  class Master < Base
    class << self
      def register(args)
        repmgr_cmd(args, 'master register')
        restart_daemon
      end

      # repmgr command line does not provide a way to remove failed master nodes
      def remove(args)
        query = "DELETE FROM repmgr_gitlab_cluster.repl_nodes WHERE "
        if args.key?(:host)
          query << "name='#{args[:host]}'"
        elsif args.key?(:node_id)
          query << "id='#{args[:node_id]}'"
        end
        user = args[:user] ? args[:user] : nil
        execute_psql(database: 'gitlab_repmgr', query: query, host: '127.0.0.1', port: 5432, user: user)
      end
    end
  end

  class Node
    attr_accessor :attributes

    def initialize
      @attributes = GitlabCtl::Util.get_public_node_attributes
    end

    def is_master?
      hostname = attributes['repmgr']['node_name'] || `hostname -f`.chomp
      query = "SELECT name FROM repmgr_gitlab_cluster.repl_nodes WHERE type='master' AND active != 'f'"
      host = attributes['gitlab']['postgresql']['unix_socket_directory']
      port = attributes['gitlab']['postgresql']['port']
      master = Repmgr::Base.execute_psql(database: 'gitlab_repmgr', query: query, host: host, port: port, user: 'gitlab-consul')
      show_count = Repmgr::Base.cmd(
        %(gitlab-ctl repmgr cluster show | awk 'BEGIN { count=0 } $2=="master" {count+=1} END { print count }'),
        Etc.getpwuid.name
      ).chomp
      raise MasterError, "#{master} #{show_count}" if master.length != 1 || show_count != '1'
      master.first.eql?(hostname)
    end
  end

  class Events
    class <<self
      def fire(args)
        node_id, event_type, success, timestamp, details = args[3..-1]
        event_method = event_type.tr('-', '_')
        begin
          send(event_method, node_id, success, timestamp, details)
        rescue NoMethodError
          # If the method doesn't exist, we don't handle the event
          nil
        end
      end

      def repmgrd_failover_promote(node_id, success, timestamp, details)
        raise Repmgr::EventError, "We tried to failover at #{timestamp}, but failed with: #{details}" unless success.eql?('1')
        old_master = details.match(/old master (\d+) marked as failed/)[1]
        Consul::Kv.put("gitlab/ha/postgresql/failed_masters/#{old_master}")
      end
    end
  end
end
