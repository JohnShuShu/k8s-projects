#!/usr/bin/env python3

import os
import re
import sys
import json
import time
import logging
import requests
from datetime import datetime
from kubernetes import client, config
from typing import Dict, List, Optional, Tuple, Set

# Configure logging
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(levelname)s - %(message)s'
)
logger = logging.getLogger(__name__)

class MetricsScraper:
    def __init__(self):
        self.pagerduty_token = os.getenv('PAGERDUTY_TOKEN') 
        self.pagerduty_routing_key = os.getenv('PAGERDUTY_ROUTING_KEY')
        self.namespace = os.getenv('TARGET_NAMESPACE')
        self.watch_json = json.loads(os.getenv('WATCH_JSON'))

        if not self.pagerduty_token or not self.pagerduty_routing_key:
            raise ValueError("PAGERDUTY_TOKEN and PAGERDUTY_ROUTING_KEY must be set")
        
        # Initializing K8s client
        try:
            config.load_incluster_config()
        except Exception:
            try:
                config.load_kube_config()
            except Exception as e:
                logger.error(f"Failed to load Kubernetes config: {e}")
                raise
        
        self.k8s_apps_v1 = client.AppsV1Api()
        self.k8s_core_v1 = client.CoreV1Api()
        self.k8s_batch_v1 = client.BatchV1Api()

        logger.info("\n--- Version Information ---")
        logger.info(f"Python Version: {sys.version.split()[0]} (Full: {sys.version.splitlines()[0]})") 

        # Build quick-lookup sets from watch.json
        self.watch_pairs_by_kind: Dict[str, Set[Tuple[str, str]]] = {}
        for item in self.watch_json:
            kind = (item.get("kind") or "Deployment").lower()
            ns = item["namespace"]
            name = item["name"]
            self.watch_pairs_by_kind.setdefault(kind, set()).add((ns, name))

        # Also keep a set of all namespaces mentioned, as a fallback
        self.watched_namespaces = {item["namespace"] for item in self.watch_json}

    # ---------- Helpers ----------
    def _is_watched(self, kind: str, namespace: str, name: str) -> bool:
        """Return True if (ns,name) is explicitly in watch.json for this kind."""
        pairs = self.watch_pairs_by_kind.get(kind.lower())
        if pairs:
            return (namespace, name) in pairs
        # Fallback to namespace-only filtering if pairs is empty for this kind
        return namespace in self.watched_namespaces


    def remove_replicaset_hash(self, metric_name: str) -> str:
        """Remove trailing alphanumeric hash if present, otherwise return as-is"""
        # Check if string ends with hyphen followed by alphanumeric characters
        # This helps simplify the resolution since we don't store the state

        if re.search(r'-[a-zA-Z0-9]+$', metric_name):
            return re.sub(r'-[a-zA-Z0-9]+$', '', metric_name)
        return metric_name
    
    # ---------- Deployments ----------
    def get_deployment_metrics(self) -> List[Dict]:
        """Scraping Deployment metrics from Cluster"""
        metrics = []
        try:
            deployments = self.k8s_apps_v1.list_deployment_for_all_namespaces()
            for deployment in deployments.items:
                name = deployment.metadata.name
                namespace = deployment.metadata.namespace
                if not self._is_watched("deployment", namespace, name):
                    continue

                desired_replicas = deployment.spec.replicas or 0
                available_replicas = deployment.status.available_replicas or 0
                ready_replicas = deployment.status.ready_replicas or 0

                metrics.append({
                    'name': name,
                    'namespace': namespace,
                    'type': 'deployment',
                    'desired_replicas': desired_replicas,
                    'available_replicas': available_replicas,
                    'ready_replicas': ready_replicas,
                    'timestamp': datetime.now().isoformat()
                })
                logger.info(
                    f"Deployment {namespace}/{name}: {available_replicas}/{desired_replicas} available"
                )
        except Exception as e:
            logger.error(f"Failed to get Deployment metrics: {e}")
        return metrics

    # ---------- ReplicaSets ----------
    def get_replicaset_metrics(self) -> List[Dict]:
        """Scrape ReplicaSet metrics from Kubernetes"""
        metrics = []
        try:
            replicasets = self.k8s_apps_v1.list_replica_set_for_all_namespaces()
            for rs in replicasets.items:
                name = rs.metadata.name
                namespace = rs.metadata.namespace
                # We only include ReplicaSets if their owning Deployment is explicitly watched
                # (If desired, you can relax this to namespace-only.)
                if not self._is_watched("replicaset", namespace, name) and namespace not in self.watched_namespaces:
                    continue

                desired_replicas = rs.spec.replicas or 0
                available_replicas = rs.status.available_replicas or 0
                ready_replicas = rs.status.ready_replicas or 0

                # Skip ReplicaSets with 0 desired replicas (scaled to zero)
                if desired_replicas == 0:
                    continue

                metrics.append({
                    'name': name,
                    'namespace': namespace,
                    'type': 'replicaset',
                    'desired_replicas': desired_replicas,
                    'available_replicas': available_replicas,
                    'ready_replicas': ready_replicas,
                    'timestamp': datetime.now().isoformat()
                })
        except Exception as e:
            logger.error(f"Failed to get ReplicaSet metrics: {e}")
        return metrics

    # ---------- DaemonSets ----------
    def get_daemonset_metrics(self) -> List[Dict]:
        """Scrape DaemonSet metrics. Map 'available' to number_ready."""
        metrics = []
        try:
            dss = self.k8s_apps_v1.list_daemon_set_for_all_namespaces()
            for ds in dss.items:
                name = ds.metadata.name
                namespace = ds.metadata.namespace
                if not self._is_watched("daemonset", namespace, name):
                    continue

                status = ds.status or client.V1DaemonSetStatus()
                desired = status.desired_number_scheduled or 0
                current = status.current_number_scheduled or 0
                ready = status.number_ready or 0
                updated = status.updated_number_scheduled or 0
                available = ready
                misscheduled = status.number_misscheduled or 0

                metrics.append({
                    'name': name,
                    'namespace': namespace,
                    'type': 'daemonset',
                    'desired_replicas': desired,
                    'available_replicas': available,   # use 'ready' as available
                    'ready_replicas': ready,
                    'current_number_scheduled': current,
                    'updated_number_scheduled': updated,
                    'number_misscheduled': misscheduled,
                    'timestamp': datetime.now().isoformat()
                })
                logger.info(
                    f"DaemonSet {namespace}/{name}: ready {ready} / desired {desired} (current {current}, updated {updated}, mis {misscheduled})"
                )
        except Exception as e:
            logger.error(f"Failed to get DaemonSet metrics: {e}")
        return metrics

    # ---------- StatefulSets ----------
    def get_statefulset_metrics(self) -> List[Dict]:
        """Scrape StatefulSet metrics. Treat 'ready_replicas' as 'available' for stateless checks."""
        metrics = []
        try:
            ssets = self.k8s_apps_v1.list_stateful_set_for_all_namespaces()
            for ss in ssets.items:
                name = ss.metadata.name
                namespace = ss.metadata.namespace
                if not self._is_watched("statefulset", namespace, name):
                    continue

                desired = ss.spec.replicas or 0
                ready = ss.status.ready_replicas or 0
                current = ss.status.current_replicas or 0
                updated = ss.status.updated_replicas or 0

                metrics.append({
                    'name': name,
                    'namespace': namespace,
                    'type': 'statefulset',
                    'desired_replicas': desired,
                    'available_replicas': ready,  # map ready to available
                    'ready_replicas': ready,
                    'current_replicas': current,
                    'updated_replicas': updated,
                    'timestamp': datetime.now().isoformat()
                })
                logger.info(
                    f"StatefulSet {namespace}/{name}: ready {ready} / desired {desired} (current {current}, updated {updated})"
                )
        except Exception as e:
            logger.error(f"Failed to get StatefulSet metrics: {e}")
        return metrics

    # ---------- CronJobs ----------
    def get_cronjob_metrics(self) -> List[Dict]:
        """
        Scrape CronJob metrics.
        - If spec.suspend is True -> ignore (treated as desired==0)
        - Healthy (available=1) if not suspended AND has lastSuccessfulTime AND no failed Jobs/Pods
        - Otherwise unhealthy (available=0)
        We encode this into desired_replicas (1 if enabled, else 0) and available_replicas (1/0).
        """
        metrics = []
        try:
            cronjobs = self.k8s_batch_v1.list_cron_job_for_all_namespaces()
            for cj in cronjobs.items:
                name = cj.metadata.name
                namespace = cj.metadata.namespace
                if not self._is_watched("cronjob", namespace, name):
                    continue

                spec = cj.spec or client.V1CronJobSpec()
                status = cj.status or client.V1CronJobStatus()
                suspended = bool(spec.suspend) if spec.suspend is not None else False

                # When suspended, treat as scaled-to-zero (desired=0)
                desired = 0 if suspended else 1

                # lastSuccessfulTime (may be None if never succeeded)
                last_success = getattr(status, "last_successful_time", None)
                last_success_iso = None
                if last_success:
                    # last_success is datetime or V1Time; coerce to string
                    last_success_iso = getattr(last_success, "isoformat", lambda: str(last_success))()

                # Check Jobs owned by this CronJob
                failed_jobs = 0
                job_names = []
                try:
                    jobs = self.k8s_batch_v1.list_namespaced_job(namespace=namespace)
                    for job in jobs.items:
                        if job.metadata and job.metadata.owner_references:
                            for ref in job.metadata.owner_references:
                                if ref.kind == "CronJob" and ref.name == name:
                                    job_names.append(job.metadata.name)
                                    # Job status.failed can be None
                                    if job.status and (job.status.failed or 0) > 0:
                                        failed_jobs += 1
                except Exception as je:
                    logger.warning(f"Failed to list Jobs for CronJob {namespace}/{name}: {je}")

                # Check Pods of those Jobs for failed/unknown phases
                failed_pods = 0
                if job_names:
                    try:
                        pods = self.k8s_core_v1.list_namespaced_pod(namespace=namespace)
                        job_name_set = set(job_names)
                        for pod in pods.items:
                            labels = pod.metadata.labels or {}
                            # Pods from Jobs typically have a 'job-name' label
                            if labels.get("job-name") in job_name_set:
                                phase = (pod.status.phase or "").lower()
                                if phase in ("failed", "unknown"):
                                    failed_pods += 1
                    except Exception as pe:
                        logger.warning(f"Failed to list Pods for CronJob {namespace}/{name}: {pe}")

                healthy = (not suspended) and (last_success_iso is not None) and (failed_jobs == 0) and (failed_pods == 0)
                available = 1 if healthy else 0

                metrics.append({
                    'name': name,
                    'namespace': namespace,
                    'type': 'cronjob',
                    'desired_replicas': desired,
                    'available_replicas': available,
                    'ready_replicas': available,  # mirror available for shape-compatibility
                    'suspended': suspended,
                    'last_successful_time': last_success_iso,
                    'failed_jobs': failed_jobs,
                    'failed_pods': failed_pods,
                    'timestamp': datetime.now().isoformat()
                })
                logger.info(
                    f"CronJob {namespace}/{name}: enabled={not suspended}, last_success={last_success_iso}, failed_jobs={failed_jobs}, failed_pods={failed_pods} -> available={available}"
                )
        except Exception as e:
            logger.error(f"Failed to get CronJob metrics: {e}")
        return metrics

    # ---------- Stateless evaluation ----------
    def evaluate_and_notify(self, metrics: List[Dict]):
        """
        Stateless evaluation (uniform for all kinds):
        - If desired > 0 and available == 0  -> trigger
        - If desired > 0 and available > 0   -> resolve
        - If desired == 0                    -> do nothing
        """
        triggers = 0
        resolves = 0
        for metric in metrics:
            desired = metric.get('desired_replicas', 0) or 0
            available = metric.get('available_replicas', 0) or 0

            if desired == 0:
                continue  # scaled down or suspended
     
            metric['name'] = self.remove_replicaset_hash(metric['name']    )
            resource_key = f"{metric['namespace']}/{metric['name']}"
            unhealthy = (available == 0)

            if unhealthy:
                alert = {
                    'resource': resource_key,
                    'type': metric['type'],
                    'duration': 'unknown',
                    'metric': metric
                }

                logger.info(
                    f"Sending PagerDuty alert with dedup key: k8s-zero-replicas-{resource_key}"
                )
                if self.send_pagerduty_alert(alert):
                    triggers += 1
            else:
                logger.info(
                    f"Sending PagerDuty resolve with dedup key: k8s-zero-replicas-{resource_key}"
                )
                if self.send_pagerduty_resolve(resource_key, metric['type'], metric):
                    resolves += 1

        logger.info(f"Stateless notify complete - triggers: {triggers}, resolves: {resolves}")

    # ---------- PagerDuty ----------
    def send_pagerduty_alert(self, alert: Dict):
        """Send alert to PagerDuty"""
        url = "https://events.pagerduty.com/v2/enqueue"
        dedup_key = f"k8s-zero-replicas-{alert['resource']}"
        payload = {
            "routing_key": self.pagerduty_routing_key,
            "event_action": "trigger",
            "dedup_key": dedup_key,  # For resolving later
            "payload": {
                "summary": f"Kubernetes {alert['type']} {alert['resource']} has 0 available replicas",
                "severity": "critical",
                "source": f"k8s-metrics-scraper",
                "component": alert['resource'],
                "group": "kubernetes",
                "class": "replica_failure",
                "custom_details": alert['metric']
            }
        }
        headers = {
            "Content-Type": "application/json"
        }         
        try:
            response = requests.post(url, json=payload, headers=headers, timeout=30)
            response.raise_for_status()
            logger.info(f"Successfully sent PagerDuty alert for {alert['resource']}")
            return True
        except Exception as e:
            logger.error(f"Failed to send PagerDuty alert for {alert['resource']}: {e}")
            return False

    def send_pagerduty_resolve(self, resource_key: str, resource_type: str, metric: Dict):
        """Send resolve alert to PagerDuty when resource recovers"""
        url = "https://events.pagerduty.com/v2/enqueue"
        dedup_key = f"k8s-zero-replicas-{resource_key}"
        payload = {
            "routing_key": self.pagerduty_routing_key,
            "event_action": "resolve",
            "dedup_key": dedup_key
        }
        headers = {
            "Content-Type": "application/json"
        }      
        try:
            response = requests.post(url, json=payload, headers=headers, timeout=30)
            response.raise_for_status()
            logger.info(f"Successfully sent PagerDuty resolve for {resource_key}")
            return True
        except Exception as e:
            logger.error(f"Failed to send PagerDuty resolve for {resource_key}: {e}")
            return False

    # ---------- Main ----------
    def run(self):
        """Main execution function"""
        logger.info("Starting metrics scraping run")

        all_metrics: List[Dict] = []
        all_metrics.extend(self.get_deployment_metrics())
        all_metrics.extend(self.get_replicaset_metrics())
        all_metrics.extend(self.get_daemonset_metrics())
        all_metrics.extend(self.get_statefulset_metrics())
        all_metrics.extend(self.get_cronjob_metrics())

        logger.info(f"Collected {len(all_metrics)} metrics")

        # Stateless: evaluate current health and notify PD accordingly
        self.evaluate_and_notify(all_metrics)

        logger.info("Completed metrics scraping run (stateless)")

if __name__ == "__main__":
    try:
        scraper = MetricsScraper()
        scraper.run()
    except Exception as e:
        logger.error(f"Fatal error: {e}")
        exit(1)

