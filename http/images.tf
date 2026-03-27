resource "openstack_images_image_v2" "noble" {
  name             = "ubuntu-noble-x86_64"
  image_source_url = "http://127.0.0.1:8080/noble-server-cloudimg-amd64.img"
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
  name             = "debian-12-x86_64"
  image_source_url = "http://127.0.0.1:8080/debian-12-genericcloud-amd64.qcow2"
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
  count            = var.kali ? 1 : 0
  name             = "kali"
  image_source_url = "http://127.0.0.1:8080/kali.qcow2"
  container_format = "bare"
  disk_format      = "qcow2"

  properties = {
    os_type                                = "linux"
    "owner_specified.openstack.gui_access" = "true"
  }

  # File Kali 18GB cần rất nhiều thời gian để tải qua Public IP
  timeouts {
    create = "2h"
  }
}

resource "openstack_images_image_v2" "noble_man" {
  count            = var.noble_man ? 1 : 0
  name             = "ubuntu-noble-man"
  image_source_url = "http://127.0.0.1:8080/ubuntu-noble-man.qcow2"
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
