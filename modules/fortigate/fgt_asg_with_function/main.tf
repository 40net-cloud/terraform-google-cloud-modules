locals {
  prefix              = var.prefix == "" ? "" : "${var.prefix}-"
  fgt_password        = var.fgt_password == "" ? random_password.fgt_password[0].result : var.fgt_password
  autoscale_psksecret = var.cloud_function.autoscale_psksecret == "" ? random_password.autoscale_psksecret[0].result : var.cloud_function.autoscale_psksecret
}

resource "random_password" "fgt_password" {
  count   = var.fgt_password == "" ? 1 : 0
  length  = 16
  special = false
}

resource "random_password" "autoscale_psksecret" {
  count   = var.cloud_function.autoscale_psksecret == "" ? 1 : 0
  length  = 16
  special = false
}

data "google_compute_default_service_account" "default" {
}

data "google_compute_image" "fgt_image" {
  project = "fortigcp-project-001"
  family  = var.image_type
}

data "google_compute_subnetwork" "subnet_resources" {
  count  = length(var.network_interfaces)
  name   = var.network_interfaces[count.index].subnet_name
  region = var.region
}

# VM
resource "google_compute_region_instance_template" "main" {
  name           = "${local.prefix}template"
  region         = var.region
  machine_type   = var.machine_type
  can_ip_forward = true

  tags = var.network_tags

  disk {
    boot         = true
    source_image = data.google_compute_image.fgt_image.self_link
  }

  dynamic "disk" {
    for_each = var.additional_disk.size != 0 ? [1] : []
    content {
      boot         = false
      auto_delete  = true
      disk_type    = var.additional_disk.type
      disk_size_gb = var.additional_disk.size
    }
  }

  dynamic "network_interface" {
    for_each = var.network_interfaces
    content {
      subnetwork = data.google_compute_subnetwork.subnet_resources[network_interface.key].self_link
      dynamic "access_config" {
        for_each = var.network_interfaces[network_interface.key].has_public_ip ? [1] : []
        content {}
      }
    }
  }

  metadata = {
    user-data = templatefile("${path.module}/bootstrap.conf", {
      hostname           = var.hostname
      network_interfaces = var.network_interfaces
      config_script      = var.config_script
    })
  }

  service_account {
    email  = data.google_compute_default_service_account.default.email
    scopes = ["cloud-platform"]
  }
  depends_on = [google_cloudfunctions2_function.init_instance]
  lifecycle {
    ignore_changes = [
      metadata
    ]
  }
}

resource "google_compute_region_health_check" "mig" {
  name                = "${local.prefix}hc-mig"
  region              = var.region
  timeout_sec         = 2
  check_interval_sec  = 30
  unhealthy_threshold = 10
  http_health_check {
    # TODO: parametrize probe port in both bootstrap config and here
    port = 8008
  }
}

resource "google_compute_region_instance_group_manager" "manager" {
  name                      = "${local.prefix}instance-group"
  base_instance_name        = "${local.prefix}group"
  region                    = var.region
  distribution_policy_zones = length(var.zones) > 0 ? var.zones : null
  version {
    instance_template = google_compute_region_instance_template.main.self_link
  }
  auto_healing_policies {
    health_check      = google_compute_region_health_check.mig.id
    initial_delay_sec = 180
  }
}

resource "google_compute_region_autoscaler" "autoscaler" {
  name   = "${local.prefix}autoscaler"
  region = var.region
  target = google_compute_region_instance_group_manager.manager.id

  autoscaling_policy {
    max_replicas    = var.autoscaler.max_instances
    min_replicas    = var.autoscaler.min_instances
    cooldown_period = var.autoscaler.cooldown_period

    cpu_utilization {
      target = var.autoscaler.cpu_utilization
    }
  }
}
