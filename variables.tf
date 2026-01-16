variable "base_name" {
  type        = string
  default     = "venakamura2026je"
  description = "Base name used as a prefix for all resources (RG, vnet, app, etc.)."
}

variable "subscription_id" {
  type = string
  description = "subscription id"
}

variable "resource_group_location" {
  type        = string
  default     = "West Europe"
  description = "Location of the resource group."
}
