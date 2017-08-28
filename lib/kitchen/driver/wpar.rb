# -*- encoding: utf-8 -*-

#
# Author:: Alain Dejoux (<adejoux@djouxtech.net>)
#
# Copyright (C) 2016, Alain Dejoux
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#    http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

require 'kitchen'
require 'kitchen/driver/wpar_version'
require 'net/ssh'

module Kitchen
  module Driver
    # Wpar driver for Kitchen.
    #
    # @author Alain Dejoux <adejoux@djouxtech.net>
    # noinspection RubyDefParenthesesInspection,SpellCheckingInspection
    class Wpar < Kitchen::Driver::Base
      kitchen_driver_api_version 2
      plugin_version Kitchen::Driver::WPAR_VERSION

      default_config :mkwpar, '/usr/sbin/mkwpar'
      default_config :startwpar, '/usr/sbin/startwpar'
      default_config :rmwpar, '/usr/sbin/rmwpar'
      default_config :lswpar, '/usr/sbin/lswpar'
      default_config :wpar_name, 'kitchenwpar'
      default_config :wpar_copy_rootvg, false
      default_config :aix_host, 'localhost'
      default_config :aix_user, 'root'
      default_config :isWritable, false
      default_config :isVersioned, false
      default_config :share_network_resolution, true
      default_config :echo, '/bin/echo'
      default_config :clogin, '/usr/sbin/clogin'
      default_config :lssrc, '/usr/bin/lssrc'
      default_config :mkssys, '/usr/bin/mkssys'
      default_config :startsrc, '/usr/bin/startsrc'
      default_config :stopsrc, '/usr/bin/stopsrc'
      default_config :pam_sshd_account_rule, 'sshd account required pam_aix'
      default_config :pam_sshd_session_rule, 'sshd session required pam_aix'

      def create(state)
        raise ActionFailed, 'wpar already exists !' if wpar_exists?(state)

        cmd = build_mkwpar_command
        ssh_command(cmd, :stderr)

        raise ActionFailed, 'Cannot create wpar !' unless wpar_exists?(state)
        state[:hostname] = config[:wpar_address] || config[:wpar_name]
        copy_key

        # Ensure sshd is a defined service and is running so that
        # kitchen can connect to the host and do work.
        create_sshd_service unless sshd_service_exists?

        start_sshd_service unless sshd_service_running?

        configure_pam unless pam_supports_sshd?
      end

      protected

      def build_mkwpar_command
        cmd = "#{config[:mkwpar]} -s -n #{config[:wpar_name]}"
        unless config[:wpar_address].nil?
          cmd += " -N address=#{config[:wpar_address]}"
        end

        cmd += ' -r' if config[:share_network_resolution]

        cmd += " -g #{config[:wpar_vg]}" unless config[:wpar_vg].nil?

        unless config[:wpar_rootvg].nil?
          cmd += " -D rootvg=yes devname=#{config[:wpar_rootvg]}"
        end

        unless config[:wpar_mksysb].nil?
          cmd += ' -C' if config[:isVersioned]
          cmd += " -B #{config[:wpar_mksysb]}"
        end

        cmd += ' -t' if config[:wpar_copy_rootvg]

        cmd += ' -l' if config[:isWritable]

        cmd
      end

      def copy_key
        cmd = "mkdir /wpars/#{config[:wpar_name]}/.ssh;"
        cmd += "chmod 700 /wpars/#{config[:wpar_name]}/.ssh"
        ssh_command(cmd, :stderr)
        cmd = "cp ~/.ssh/authorized_keys /wpars/#{config[:wpar_name]}/.ssh"
        ssh_command(cmd, :stderr)
      end

      def wpar_exists?(_state)
        output = ssh_command("#{config[:lswpar]} #{config[:wpar_name]}",
                             :stderr)
        return false if output.include?('0960-419')
        true
      end

      # Determines if the sshd service is defined in the WPAR.
      def sshd_service_exists?
        # FIXME: We should probably check exit status rather than AIX-specific
        # error codes.
        output = ssh_command("#{config[:clogin]} "\
                           "#{config[:wpar_name]} "\
                           "#{config[:lssrc]} -s sshd",
                             :stderr)
        # 0513-085 The sshd Subsystem is not on file.
        return false if output.include?('0513-085')
        true
      end

      # Creates an sshd service.
      def create_sshd_service
        # FIXME: We should probably check exit status rather than AIX-specific
        # error codes.
        output = ssh_command("#{config[:clogin]} "\
                           "#{config[:wpar_name]} "\
                           "#{config[:mkssys]} "\
                           '-s sshd -p /usr/sbin/sshd '\
                           "-a '-D' -u 0 -S -n 15 -f 9 -R -G local",
                             :stderr)
        # 0513-071 The sshd Subsystem has been added.
        return true if output.include?('0513-071')
        false
      end

      # Determines if the sshd service is running.
      def sshd_service_running?
        # FIXME: We should probably check exit status rather than AIX-specific
        # error codes.
        output = ssh_command("#{config[:clogin]} "\
                           "#{config[:wpar_name]} "\
                           "#{config[:lssrc]} -s sshd",
                             :stderr)
        return true if output.include?('active')
        false # Status == inoperative
      end

      # Starts the sshd service.
      def start_sshd_service
        # FIXME: We should probably check exit status rather than AIX-specific
        # error codes.
        output = ssh_command("#{config[:clogin]} "\
                           "#{config[:wpar_name]} "\
                           "#{config[:startsrc]} -s sshd",
                             :stderr)
        # 0513-059 The sshd Subsystem has been started. Subsystem PID is 123...
        return true if output.include?('0513-059')
        false
      end

      # Determines if PAM support for sshd exists in this WPAR.
      # This includes account and session rules.
      def pam_supports_sshd?
        pam_config_path = "/wpars/#{config[:wpar_name]}/etc/pam.conf"
        account_output = ssh_command('grep '\
                                   "'#{config[:pam_sshd_account_rule]}' "\
                                   "#{pam_config_path}", :stderr)
        session_output = ssh_command('grep '\
                                   "'#{config[:pam_sshd_session_rule]}' "\
                                   "#{pam_config_path}", :stderr)

        unless account_output.include?(config[:pam_sshd_account_rule].to_s)
          return false
        end
        unless session_output.include?(config[:pam_sshd_session_rule].to_s)
          return false
        end

        true
      end

      # Configures PAM support for sshd in the WPAR.
      def configure_pam
        pam_config_path = "/wpars/#{config[:wpar_name]}/etc/pam.conf"
        pam_sshd_rules = "#{config[:pam_sshd_account_rule]}"\
                         "\\n#{config[:pam_sshd_session_rule]}"
        header = '\\n\\n# sshd Rules\\n'
        cmd = "#{config[:echo]} \"#{header}#{pam_sshd_rules}\" "\
              ">> #{pam_config_path}"
        ssh_command(cmd, :stderr)
      end

      def ssh_command(cmd, _stream)
        out = ''
        begin
          host = config[:aix_host]
          user = config[:aix_user]
          keys = config[:aix_key]
          Net::SSH.start(host, user, keys: keys) do |ssh|
            ssh.exec!(cmd) do |_channel, stream, data|
              out << data if stream == stream
              print data
            end
            out
          end
        rescue
          raise ActionFailed, 'ssh command failed !'
        end
      end
    end
  end
end
