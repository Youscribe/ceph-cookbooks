# This recipe creates a monitor cluster
#
# You should never change the mon default path or
# the keyring path.
# Don't change the cluster name either
# Default path for mon data: /var/lib/ceph/mon/$cluster-$id/
#   which will be /var/lib/ceph/mon/ceph-`hostname`/
#   This path is used by upstart. If changed, upstart won't
#   start the monitor
# The keyring files are created using the following pattern:
#  /etc/ceph/$cluster.client.$name.keyring
#  e.g. /etc/ceph/ceph.client.admin.keyring
#  The bootstrap-osd and bootstrap-mds keyring are a bit
#  different and are created in
#  /var/lib/ceph/bootstrap-{osd,mds}/ceph.keyring

require 'json'

include_recipe "ceph::default"
include_recipe "ceph::conf"

service_type = service_type()
service "ceph_mon" do
  case service_type
  when "upstart"
    service_name "ceph-mon-all"
    provider Chef::Provider::Service::Upstart
    action :enable
  when "sysvinit"
    service_name "ceph"
    provider Chef::Provider::Service::Init
  end
  supports :restart => true
end

directory "/var/run/ceph" do
  owner "root"
  group "root"
  mode 00644
  recursive true
  action :create
end

# TODO cluster name
cluster = 'ceph'

unless node["ceph"]["mon"]["done"] or File.exists?("/var/lib/ceph/mon/ceph-#{node["hostname"]}/done")
  keyring = "#{Chef::Config[:file_cache_path]}/#{cluster}-#{node['hostname']}.mon.keyring"

  execute "format as keyring" do
    command "ceph-authtool '#{keyring}' --create-keyring --name=mon. --add-key='#{node["ceph"]["monitor-secret"]}' --cap mon 'allow *'"
    creates "#{Chef::Config[:file_cache_path]}/#{cluster}-#{node['hostname']}.mon.keyring"
  end

  execute 'ceph-mon mkfs' do
    command "ceph-mon --mkfs -i #{node['hostname']} --keyring '#{keyring}'"
  end

  ruby_block "finalise" do
    block do
      %w[done, upstart].each do |ack|
        File.open("/var/lib/ceph/mon/ceph-#{node["hostname"]}/#{ack}", "w").close()
      end
      node.set["ceph"]["mon"]["done"] = true
      node.save
    end
  end
end

service "ceph-mon-all" do
  provider Chef::Provider::Service::Upstart
  action [ :enable, :start ]
end

get_mon_addresses().each do |addr|
  execute "peer #{addr}" do
    command "ceph --admin-daemon '/var/run/ceph/ceph-mon.#{node['hostname']}.asok' add_bootstrap_peer_hint #{addr}"
  end
end

# The key is going to be automatically
# created,
# We store it when it is created
ruby_block "get osd-bootstrap keyring" do
  block do
    cmd = Chef::ShellOut.new("ceph auth get-key client.bootstrap-osd")
    osd_bootstrap_key = cmd.run_command.stdout
    node.override['ceph']['ceph_bootstrap_osd_key'] = osd_bootstrap_key
    node.save
  end
  not_if { node['ceph']['ceph_bootstrap_osd_key'] }
end
