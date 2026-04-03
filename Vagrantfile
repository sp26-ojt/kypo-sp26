# -*- mode: ruby -*-
# vi: set ft=ruby :

dns1 = ENV["DNS1"] || "1.1.1.1"
dns2 = ENV["DNS2"] || "1.0.0.1"
cpu = ENV["CPU"] || 8
ram = ENV["RAM"] || 45056

Vagrant.configure(2) do |config|

  config.vm.box = "bento/ubuntu-24.04"
  config.vm.box_version = "202508.03.0"
  config.vm.hostname = "openstack"

  config.vm.network :private_network, ip: "10.1.2.10"
  config.vm.network :private_network, ip: "10.1.2.11", auto_config: false

  # 9p mount — truy cập trực tiếp thư mục host, không copy
  config.vm.synced_folder ".", "/vagrant", type: "9p", accessmode: "mapped"

  config.vm.provider :libvirt do |libvirt|
    libvirt.cpus = cpu
    libvirt.memory = ram
    libvirt.nested = true
    libvirt.machine_virtual_size = 250
  end

  # Copy scripts và ansible config vào VM
  config.vm.provision "file", source: "ansible.cfg", destination: "/tmp/ansible.cfg", run: "once"
  config.vm.provision "file", source: "scripts/", destination: "/tmp/", run: "once"

  # Kiểm tra images có thấy qua 9p không
  config.vm.provision "shell",
    name: "Check images mount",
    privileged: true,
    run: "once",
    inline: <<-SHELL
      echo "=== /vagrant mount check ==="
      mountpoint /vagrant && echo "mounted OK" || echo "NOT mounted"
      ls -lh /vagrant/http/ 2>/dev/null || echo "http/ not accessible"
    SHELL

  # Phase 1: System Setup
  config.vm.provision "system-setup",
    type: "shell",
    name: "System Setup and Package Installation",
    env: { "DNS1" => dns1, "DNS2" => dns2, "RAM" => ram.to_s },
    path: "scripts/01-system-setup.sh",
    run: "once"

  # Phase 2: OpenStack Deployment
  config.vm.provision "openstack-deployment",
    type: "shell",
    name: "OpenStack Deployment with Kolla-Ansible",
    path: "scripts/02-openstack-deploy.sh",
    run: "once",
    privileged: true

  # Phase 3: Infrastructure Deployment
  config.vm.provision "infrastructure-deployment",
    type: "shell",
    name: "Kubernetes and Application Infrastructure",
    env: { "DNS1" => dns1, "DNS2" => dns2, "PUBLIC_IP" => ENV["PUBLIC_IP"] || "" },
    path: "scripts/03-infrastructure-deploy.sh",
    run: "once",
    privileged: true

  # Phase 4: Final Setup
  config.vm.provision "final-setup",
    type: "shell",
    name: "Final Configuration and Information Display",
    path: "scripts/04-final-setup.sh",
    run: "once",
    privileged: true

end
