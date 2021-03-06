#
# Cookbook Name:: docker-registry
# Recipe:: default
# Author:: Raul E Rangel (<Raul.E.Rangel@gmail.com>)
#
# Copyright 2013, Raul E Rangel
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
# http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

directory node['docker-registry']['storage_path'] do
  mode 0770
  owner node['docker-registry']['owner']
  group node['docker-registry']['group']
end

if node['docker-registry']['data_bag']
  secrets = Chef::EncryptedDataBagItem.load(node['docker-registry']['data_bag'], node.chef_environment)

  if node['roles'].include?('docker-registry_load_balancer') and node['docker-registry']['ssl']
    if secrets["ssl_certificate"] and secrets["ssl_certificate_key"]

      certificate_path = ::File.join(node['docker-registry']['ssl_path'], "certs", "docker-registry.crt")

      template certificate_path do
        source "certificate.crt.erb"
        mode 0444
        owner 'root'
        owner 'root'
        variables({
          :certificates => secrets["ssl_certificate"].kind_of?(Array) ? secrets["ssl_certificate"] : [secrets["ssl_certificate"]]
        })
      end

      certificate_key_path = ::File.join(node['docker-registry']['ssl_path'], "private", "docker-registry.key")

      template certificate_key_path do
        source "certificate.key.erb"
        mode 0440
        owner 'root'
        group 'root'
        variables({
          :key => secrets["ssl_certificate_key"]
        })
      end
    end
  end

  s3_secret_key = secrets["s3_secret_key"]
end

application "docker-registry" do
  owner node['docker-registry']['owner']
  group node['docker-registry']['group']
  path node['docker-registry']['install_dir']
  repository node['docker-registry']['repository']
  revision node['docker-registry']['revision']
  packages ["libevent-dev", "git"]

  action :force_deploy
  symlinks "config.yml" => "config.yml"

  before_migrate do
    template "#{new_resource.path}/shared/config.yml" do
      source "config.yml.erb"
      mode 0440
      owner node['docker-registry']['owner']
      group node['docker-registry']['group']
      variables({
        :storage => node['docker-registry']['storage'],
        :storage_path => node['docker-registry']['storage_path'],
        #TODO: Come get these from an encrypted databag
        :s3_access_key => node['docker-registry']['s3_access_key'],
        :s3_secret_key => s3_secret_key,
        :s3_bucket => node['docker-registry']['s3_bucket'],
      })
    end
  end

  gunicorn do
    only_if { node['roles'].include?('docker-registry_application_server') }

    requirements "requirements.txt"
    max_requests node['docker-registry']['max_requests']
    timeout node['docker-registry']['timeout']
    port node['docker-registry']['internal_port']
    workers node['docker-registry']['workers']
    worker_class "gevent"
    app_module "wsgi:application"
    virtualenv ::File.join(node['docker-registry']['install_dir'], "env", node['docker-registry']['revision'])
    environment :SETTINGS_FLAVOR => node['docker-registry']['flavor']
  end

  nginx_load_balancer do
    only_if { node['roles'].include?('docker-registry_load_balancer') }
    
    application_port node['docker-registry']['internal_port']
    server_name (node['docker-registry']['server_name'] || node['fqdn'] || node['hostname'])
    template "load_balancer.conf.erb"
    ssl node['docker-registry']['ssl']
    ssl_certificate certificate_path
    ssl_certificate_key certificate_key_path
  end

end
