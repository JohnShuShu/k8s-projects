# Metrics Scraper Documentation

---

## Overview

Documentation on the Metrics Scraper, a light weight scraper to monitor replica availability within the clusters. It uses API calls to pull cluster metrics and alerts when available replicas do not match up with desired replicas. The repository contains

  * k8s-manifest.yaml
  * Dockerfile
  * metrics_scraper.py
---

## k8s-manifest

* Namespace
* ServiceAccount
* Persistent Volume Claim
* SecretStore
* ExternalSecret
* ConfigMap
* Cronjob
   
---

## Dockerfile

Python based dockerfile to create an image of the app and store in ECR. Images are located in the metrics-scraper repository in AWS.

---

## metrics_scraper.py

Python module which uses APIs to pull cluster metrics and analyze for apps that are down. Specifically targets available replicas vs desired replicas for specific namespaces. 
Namespace list is provided from ConfigMap object.
If available replicas go below desired replicas for a THRESHOLD (currently 2 mins), a PagerDuty Alert is fired.

---
