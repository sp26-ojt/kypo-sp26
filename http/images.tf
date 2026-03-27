resource "openstack_images_image_v2" "noble" {
  name            = "ubuntu-noble-x86_64"
  local_file_path = "/vagrant/http/noble-server-cloudimg-amd64.img"
  container_format = "bare"
  disk_format      = "qcow2"

  properties = {
    os_type = "linux"
  }

  timeouts {
    create = "30m"
  }
}

resource "openstack_images_image_v2" "debian_12" {
  name            = "debian-12-x86_64"
  local_file_path = "/vagrant/http/debian-12-genericcloud-amd64.qcow2"
  container_format = "bare"
  disk_format      = "qcow2"

  properties = {
    os_type = "linux"
  }

  timeouts {
    create = "30m"
  }
}

resource "openstack_images_image_v2" "kali" {
  count           = var.kali ? 1 : 0
  name            = "kali"
  local_file_path = "/vagrant/http/kali.qcow2"
  container_format = "bare"
  disk_format      = "qcow2"

  properties = {
    os_type                                = "linux"
    "owner_specified.openstack.gui_access" = "true"
  }

  # File Kali 18GB cần rất nhiều thời gian để upload
  timeouts {
    create = "2h"
  }
}

resource "openstack_images_image_v2" "noble_man" {
  count           = var.noble_man ? 1 : 0
  name            = "ubuntu-noble-man"
  local_file_path = "/vagrant/http/ubuntu-noble-man.qcow2"
  container_format = "bare"
  disk_format      = "qcow2"

  properties = {
    os_type                                = "linux"
    "owner_specified.openstack.gui_access" = "true"
  }

  timeouts {
    create = "30m"
  }
}
