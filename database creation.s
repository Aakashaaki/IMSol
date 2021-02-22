locals {
    resource_group_name = element(coalescelist(data.azurerm_resource_group.rgrp.*.name, azurerm_resource_group.rg.*.name, [""]), 0)
    location = element(coalescelist(data.azurerm_resource_group.rgrp.*.location, azurerm_resource_group.rg.*.location, [""]), 0)
    if_threat_detection_policy_enabled = var.enable_threat_detection_policy ? [{}] : []
    if_extended_auditing_policy_enabled = var.enable_auditing_policy ? [{}] : []
}

#---------------------------------------------------------
# Resource Group Creation or selection - Default is "false"
#----------------------------------------------------------

data "azurerm_resource_group" "rgrp" {
    count                     = var.create_resource_group == false ? 1 : 0
    name                      = var.resource_group_name
}

resource "azurerm_resource_group" "rg" {
    count                     = var.create_resource_group ? 1 : 0
    name                      = var.resource_group_name
    location                  = var.location
    tags                      = merge({"Name" = format("%s", var.resource_group_name)}, var.tags,)
}

#---------------------------------------------------------
# Storage Account to keep Audit logs - Default is "false"
#----------------------------------------------------------

resource "azurerm_storage_account" "storeacc" {
    count                     = var.enable_threat_detection_policy || var.enable_auditing_policy ? 1 : 0
    name                      = "stsqlauditlogs"
    resource_group_name       = local.resource_group_name
    location                  = local.location
    account_kind              = "StorageV2"
    account_tier              = "Standard"
    account_replication_type  = "GRS"
    tags                      = merge({"Name" = format("%s", "stsqlauditlogs")}, var.tags,)
}

#-------------------------------------------------------------
# SQL servers - Secondary server is depends_on Failover Group
#-------------------------------------------------------------

resource "random_password" "main" {
    length  = 24
    special = false
}

resource "azurerm_sql_server" "primary" {
    name                        = format("%s-primary", var.sqlserver_name)
    resource_group_name         = local.resource_group_name
    location                    = local.location
    version                     = "12.0"
    administrator_login         = "sqladmin"
    administrator_login_password = random_password.main.result
    tags                        = merge({"Name" = format("%s-primary", var.sqlserver_name)}, var.tags,)

    dynamic "extended_auditing_policy" {
        for_each = local.if_extended_auditing_policy_enabled
        content {
            storage_account_access_key = azurerm_storage_account.storeacc.0.primary_access_key
            storage_endpoint           = azurerm_storage_account.storeacc.0.primary_blob_endpoint
            retention_in_days          = var.log_retention_days
        }
    }
}

resource "azurerm_sql_server" "secondary" {
    count                       = var.enable_failover_group ? 1: 0
    name                        = format("%s-secondary", var.sqlserver_name)
    resource_group_name         = local.resource_group_name
    location                    = var.secondary_sql_server_location
    version                     = "12.0"
    administrator_login         = "sqladmin"
    administrator_login_password = random_password.main.result
    tags                        = merge({"Name" = format("%s-secondary", var.sqlserver_name)}, var.tags,)

    dynamic "extended_auditing_policy" {
        for_each = local.if_extended_auditing_policy_enabled
        content {
            storage_account_access_key = azurerm_storage_account.storeacc.0.primary_access_key
            storage_endpoint           = azurerm_storage_account.storeacc.0.primary_blob_endpoint
            retention_in_days          = var.log_retention_days
        }
    }
}

#--------------------------------------------------------------------
# SQL Database creation - Default edition:"Standard" and objective:"S1"
#--------------------------------------------------------------------

resource "azurerm_sql_database" "db" {
    name                      = var.database_name
    resource_group_name       = local.resource_group_name
    location                  = local.location
    server_name               = azurerm_sql_server.primary.name
    edition                   = var.sql_database_edition
    requested_service_objective_name = var.sqldb_service_objective_name
    tags                        = merge({"Name" = format("%s-primary", var.database_name)}, var.tags,)

    dynamic "threat_detection_policy" {
        for_each = local.if_threat_detection_policy_enabled
        content {
            state                      = "Enabled"
            storage_endpoint           = azurerm_storage_account.storeacc.0.primary_blob_endpoint
            storage_account_access_key = azurerm_storage_account.storeacc.0.primary_access_key
            retention_days             = var.log_retention_days
            email_addresses            = var.email_addresses_for_alerts
        }
    }

    dynamic "extended_auditing_policy" {
        for_each = local.if_extended_auditing_policy_enabled
        content {
            storage_account_access_key = azurerm_storage_account.storeacc.0.primary_access_key
            storage_endpoint           = azurerm_storage_account.storeacc.0.primary_blob_endpoint
            retention_in_days          = var.log_retention_days
        }
    }
}

#-----------------------------------------------------------------------------------------------
# Create and initialize a Microsoft SQL Server database using sqlcmd utility - Default is "false"
#-----------------------------------------------------------------------------------------------
