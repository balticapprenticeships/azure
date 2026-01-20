# Azure Automation & Deployment Samples  
**Repository:** balticapprenticeships/azure

Welcome! This repository contains Azure-focused automation, deployment templates, and role-based access control (RBAC) configuration examples developed as part of Baltic Apprenticeships’ cloud skills training.

## 🚀 Overview

This project is designed to provide reusable **Azure infrastructure automation, deployment patterns, and RBAC templates** to support training, demos, and real-world cloud provisioning workflows.

The repo includes:

- 📦 **Automation scripts** — reusable automation examples to perform tasks on Azure.
- ☁️ **Deployment templates** — infrastructure as code or deployment artifacts.
- 🔐 **RBAC configurations** — role and permission setup examples for secure Azure environments.

> ⚠️ *No formal description yet — feel free to update this section with specific purpose and scope.*

## 📁 Repository Structure



---

## 🔧 Automation

**Path:** `automation/`

This folder contains automation scripts designed to run in:

- **Azure Automation Accounts**
- **Azure Functions**

### 🔹 What the scripts do

The scripts perform common Azure management tasks, including:

- 🗑 **Deleting virtual machines based on tags**
- ▶️ **Starting virtual machines based on tags**
- ⏹ **Stopping virtual machines based on tags**

Tag-based automation allows for cost control, environment management, and scheduled operations without hard-coding resource names.

> Scripts may be written using Azure PowerShell or Azure CLI, depending on the scenario.

### Typical use cases

- Automatically stop non-production VMs outside business hours
- Clean up unused or temporary resources
- Enforce consistent operational behaviour across environments

---

## ☁️ Deployment

**Path:** `deployment/`

This folder contains **Infrastructure as Code (IaC)** templates used to deploy Azure resources.

### 🔹 Technologies used

- **ARM templates**
- **Bicep templates**

### 🔹 Example deployments

- Virtual machines
- Supporting infrastructure (e.g., networking, storage, availability components)

These templates can be deployed via:

- Azure Portal
- Azure CLI
- Azure DevOps pipelines
- GitHub Actions

---

## 🔐 RBAC

**Path:** `rbac/`

This folder contains **JSON role definition files** used to create **custom RBAC roles** in Azure.

### 🔹 Purpose

Custom RBAC roles allow fine-grained control over:

- What actions a user, group, or service principal can perform
- Which Azure resources those actions apply to

### 🔹 Typical usage

- Creating least-privilege roles
- Supporting training scenarios
- Delegating limited administrative access safely

---


