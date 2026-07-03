// main template for solution-base-monitoring
local kap = import 'lib/kapitan.libjsonnet';
local kube = import 'lib/kube.libjsonnet';
local inv = kap.inventory();
local prometheus = import 'lib/prometheus.libsonnet';
// The hiera parameters for the component
local params = inv.parameters.solution_base_monitoring;

local namespace = (
  if std.member(inv.applications, 'prometheus') then
    prometheus.RegisterNamespace(kube.Namespace(params.namespace))
  else if inv.parameters.facts.distribution == 'openshift4' then
    kube.Namespace(params.namespace) {
      metadata+: {
        labels+: { 'openshift.io/cluster-monitoring': 'true' },
      },
    }
  else
    kube.Namespace(params.namespace)
) + {
  metadata+: {
    labels+: params.namespaceLabels,
    annotations+: params.namespaceAnnotations,
  },
};

local monitoringOperatorRules = {
  apiVersion: 'monitoring.coreos.com/v1',
  kind: 'PrometheusRule',
  metadata: {
    name: 'solution-monitoring-operator-prometheus-rules',
    namespace: params.namespace,
  },
  spec: {
    'alert:SYN_KubeDeploymentReplicasMismatch': {
      annotations: {
        description: |||
          Deployment {{ $labels.namespace }}/{{ $labels.deployment }} has not matched the expected number of replicas for longer than 15 minutes.
          This indicates that cluster infrastructure is unable to start or restart the necessary components. This most often occurs when one or more nodes
          are down or partioned from the cluster, or a fault occurs on the node that prevents the workload from starting. In rare cases this may indicate a new
          version of a cluster component cannot start due to a bug or configuration error. Assess the pods for this deployment to verify they are running on
          healthy nodes and then contact support.
        |||,
        runbook_url: 'https://github.com/openshift/runbooks/blob/master/alerts/cluster-monitoring-operator/KubeDeploymentReplicasMismatch.md',
        summary: 'Deployment has not matched the expected number of replicas',
      },
      expr: |||
        (((
          kube_deployment_spec_replicas{namespace=~"(appuio.*|cilium|default|kube-.*|openshift-.*|syn.*)",namespace!~"(openshift-marketplace)",job="kube-state-metrics"}
            >
          kube_deployment_status_replicas_available{namespace=~"(appuio.*|cilium|default|kube-.*|openshift-.*|syn.*)",namespace!~"(openshift-marketplace)",job="kube-state-metrics"}
        ) and (
          changes(kube_deployment_status_replicas_updated{namespace=~"(appuio.*|cilium|default|kube-.*|openshift-.*|syn.*)",namespace!~"(openshift-marketplace)",job="kube-state-metrics"}[5m])
            ==
          0
        )) * on() group_left cluster:control_plane:all_nodes_ready) > 0
      |||,
      'for': '15m',
      labels: {
        severity: 'warning',
        syn: 'true',
        syn_component: 'openshift4-monitoring',
        syn_team: 'aldebaran',
      },
    },
    'alert:SYN_KubePodNotScheduled': {
      annotations: {
        description: |||
          Pod {{ $labels.namespace }}/{{ $labels.pod }} cannot be scheduled for more than 30 minutes.
          Check the details of the pod with the following command:
          oc describe -n {{ $labels.namespace }} pod {{ $labels.pod }}
        |||,
        summary: 'Pod cannot be scheduled.',
      },
      expr: |||
        last_over_time(kube_pod_status_unschedulable{namespace=~"(appuio.*|cilium|default|kube-.*|openshift-.*|syn.*)",namespace!~"(openshift-marketplace)"}[5m])
          == 1
      |||,
      'for': '30m',
      labels: {
        severity: 'warning',
        syn: 'true',
        syn_component: 'openshift4-monitoring',
        syn_team: 'aldebaran',
      },
    },
  },
};

local synKubernetesMonitoringRules = {
  apiVersion: 'monitoring.coreos.com/v1',
  kind: 'PrometheusRule',
  metadata: {
    name: 'syn-kubernetes-monitoring-rules',
    namespace: params.namespace,
  },
  spec: {
    'alert:SYN_KubePodCrashLooping': {
      annotations: {
        description: |||
          Pod {{ $labels.namespace }}/{{ $labels.pod }} ({{ $labels.container }}) is in waiting state (reason: "CrashLoopBackOff").
        |||,
        summary: 'Pod is crash looping.',
      },
      expr: |||
        max_over_time(kube_pod_container_status_waiting_reason{reason="CrashLoopBackOff", namespace=~"(appuio.*|cilium|default|kube-.*|nunki-.*|openshift-.*|syn.*)",namespace!~"(openshift-marketplace)",job="kube-state-metrics"}[5m]) >= 1
      |||,
      'for': '15m',
      labels: {
        severity: 'warning',
        syn: 'true',
        syn_component: 'openshift4-monitoring',
        syn_team: 'aldebaran',
      },
    },
    'alert:SYN_KubePodNotReady': {
      annotations: {
        description: |||
          Pod {{ $labels.namespace }}/{{ $labels.pod }} has been in a non-ready state for longer than 15 minutes.
        |||,
        runbook_url: 'https://github.com/openshift/runbooks/blob/master/alerts/cluster-monitoring-operator/KubePodNotReady.md',
        summary: 'Pod has been in a non-ready state for more than 15 minutes.',
      },
      expr: |||
        sum by (namespace, pod, cluster) (
          max by(namespace, pod, cluster) (
            kube_pod_status_phase{namespace=~"(appuio.*|cilium|default|kube-.*|nunki-.*|openshift-.*|syn.*)",namespace!~"(openshift-marketplace)", job="kube-state-metrics", phase=~"Pending|Unknown"}
            unless ignoring(phase) (kube_pod_status_unschedulable{job="kube-state-metrics"} == 1)
          ) * on(namespace, pod, cluster) group_left(owner_kind) topk by(namespace, pod, cluster) (
            1, max by(namespace, pod, owner_kind, cluster) (kube_pod_owner{owner_kind!="Job"})
          )
        ) > 0
      |||,
      'for': '15m',
      labels: {
        severity: 'warning',
        syn: 'true',
        syn_component: 'openshift4-monitoring',
        syn_team: 'aldebaran',
      },
    },
    'alert:SYN_KubeDeploymentGenerationMismatch': {
      annotations: {
        description: |||
          Deployment generation for {{ $labels.namespace }}/{{ $labels.deployment }} does not match, this indicates that the Deployment has failed but has not been rolled back.
        |||,
        summary: 'Deployment generation mismatch due to possible roll-back',
      },
      expr: |||
        kube_deployment_status_observed_generation{namespace=~"(appuio.*|cilium|default|kube-.*|nunki-.*|openshift-.*|syn.*)",namespace!~"(openshift-marketplace)",job="kube-state-metrics"}
          !=
        kube_deployment_metadata_generation{namespace=~"(appuio.*|cilium|default|kube-.*|nunki-.*|openshift-.*|syn.*)",namespace!~"(openshift-marketplace)",job="kube-state-metrics"}
      |||,
      'for': '15m',
      labels: {
        severity: 'warning',
        syn: 'true',
        syn_component: 'openshift4-monitoring',
        syn_team: 'aldebaran',
      },
    },
    'alert:SYN_KubeDeploymentRolloutStuck': {
      annotations: {
        description: |||
          Rollout of deployment {{ $labels.namespace }}/{{ $labels.deployment }} is not progressing for longer than 15 minutes.
        |||,
        summary: 'Deployment rollout is not progressing.',
      },
      expr: |||
        kube_deployment_status_condition{condition="Progressing", status="false",namespace=~"(appuio.*|cilium|default|kube-.*|nunki-.*|openshift-.*|syn.*)",namespace!~"(openshift-marketplace)",job="kube-state-metrics"}
        != 0
      |||,
      'for': '15m',
      labels: {
        severity: 'warning',
        syn: 'true',
        syn_component: 'openshift4-monitoring',
        syn_team: 'aldebaran',
      },
    },
    'alert:SYN_KubeStatefulSetReplicasMismatch': {
      annotations: {
        description: |||
          StatefulSet {{ $labels.namespace }}/{{ $labels.statefulset }} has not matched the expected number of replicas for longer than 15 minutes.
        |||,
        summary: 'StatefulSet has not matched the expected number of replicas.',
      },
      expr: |||
        (
          kube_statefulset_status_replicas_ready{namespace=~"(appuio.*|cilium|default|kube-.*|nunki-.*|openshift-.*|syn.*)",namespace!~"(openshift-marketplace)",job="kube-state-metrics"}
            !=
          kube_statefulset_replicas{namespace=~"(appuio.*|cilium|default|kube-.*|nunki-.*|openshift-.*|syn.*)",namespace!~"(openshift-marketplace)",job="kube-state-metrics"}
        ) and (
          changes(kube_statefulset_status_replicas_updated{namespace=~"(appuio.*|cilium|default|kube-.*|nunki-.*|openshift-.*|syn.*)",namespace!~"(openshift-marketplace)",job="kube-state-metrics"}[10m])
            ==
          0
        )
      |||,
      'for': '15m',
      labels: {
        severity: 'warning',
        syn: 'true',
        syn_component: 'openshift4-monitoring',
        syn_team: 'aldebaran',
      },
    },
    'alert:SYN_KubeStatefulSetGenerationMismatch': {
      annotations: {
        description: |||
          StatefulSet generation for {{ $labels.namespace }}/{{ $labels.statefulset }} does not match, this indicates that the StatefulSet has failed but has not been rolled back.
        |||,
        summary: 'StatefulSet generation mismatch due to possible roll-back',
      },
      expr: |||
        kube_statefulset_status_observed_generation{namespace=~"(appuio.*|cilium|default|kube-.*|nunki-.*|openshift-.*|syn.*)",namespace!~"(openshift-marketplace)",job="kube-state-metrics"}
          !=
        kube_statefulset_metadata_generation{namespace=~"(appuio.*|cilium|default|kube-.*|nunki-.*|openshift-.*|syn.*)",namespace!~"(openshift-marketplace)",job="kube-state-metrics"}
      |||,
      'for': '15m',
      labels: {
        severity: 'warning',
        syn: 'true',
        syn_component: 'openshift4-monitoring',
        syn_team: 'aldebaran',
      },
    },
    'alert:SYN_KubeStatefulSetUpdateNotRolledOut': {
      annotations: {
        description: |||
          StatefulSet {{ $labels.namespace }}/{{ $labels.statefulset }} update has not been rolled out.
        |||,
        summary: 'StatefulSet update has not been rolled out.',
      },
      expr: |||
        (
          max by(namespace, statefulset, job, cluster) (
            kube_statefulset_status_current_revision{namespace=~"(appuio.*|cilium|default|kube-.*|nunki-.*|openshift-.*|syn.*)",namespace!~"(openshift-marketplace)",job="kube-state-metrics"}
              unless
            kube_statefulset_status_update_revision{namespace=~"(appuio.*|cilium|default|kube-.*|nunki-.*|openshift-.*|syn.*)",namespace!~"(openshift-marketplace)",job="kube-state-metrics"}
          )
            * on(namespace, statefulset, job, cluster)
          (
            kube_statefulset_replicas{namespace=~"(appuio.*|cilium|default|kube-.*|nunki-.*|openshift-.*|syn.*)",namespace!~"(openshift-marketplace)",job="kube-state-metrics"}
              !=
            kube_statefulset_status_replicas_updated{namespace=~"(appuio.*|cilium|default|kube-.*|nunki-.*|openshift-.*|syn.*)",namespace!~"(openshift-marketplace)",job="kube-state-metrics"}
          )
        )  and on(namespace, statefulset, job, cluster) (
          changes(kube_statefulset_status_replicas_updated{namespace=~"(appuio.*|cilium|default|kube-.*|nunki-.*|openshift-.*|syn.*)",namespace!~"(openshift-marketplace)",job="kube-state-metrics"}[5m])
            ==
          0
        )
      |||,
      'for': '15m',
      labels: {
        severity: 'warning',
        syn: 'true',
        syn_component: 'openshift4-monitoring',
        syn_team: 'aldebaran',
      },
    },
    'alert:SYN_KubeDaemonSetRolloutStuck': {
      annotations: {
        description: |||
          DaemonSet {{ $labels.namespace }}/{{ $labels.daemonset }} has not finished or progressed for at least 30 minutes.
        |||,
        summary: 'DaemonSet rollout is stuck.',
      },
      expr: |||
        (
          (
            kube_daemonset_status_current_number_scheduled{namespace=~"(appuio.*|cilium|default|kube-.*|nunki-.*|openshift-.*|syn.*)",namespace!~"(openshift-marketplace)",job="kube-state-metrics"}
              !=
            kube_daemonset_status_desired_number_scheduled{namespace=~"(appuio.*|cilium|default|kube-.*|nunki-.*|openshift-.*|syn.*)",namespace!~"(openshift-marketplace)",job="kube-state-metrics"}
          ) or (
            kube_daemonset_status_number_misscheduled{namespace=~"(appuio.*|cilium|default|kube-.*|nunki-.*|openshift-.*|syn.*)",namespace!~"(openshift-marketplace)",job="kube-state-metrics"}
              !=
            0
          ) or (
            kube_daemonset_status_updated_number_scheduled{namespace=~"(appuio.*|cilium|default|kube-.*|nunki-.*|openshift-.*|syn.*)",namespace!~"(openshift-marketplace)",job="kube-state-metrics"}
              !=
            kube_daemonset_status_desired_number_scheduled{namespace=~"(appuio.*|cilium|default|kube-.*|nunki-.*|openshift-.*|syn.*)",namespace!~"(openshift-marketplace)",job="kube-state-metrics"}
          ) or (
            kube_daemonset_status_number_available{namespace=~"(appuio.*|cilium|default|kube-.*|nunki-.*|openshift-.*|syn.*)",namespace!~"(openshift-marketplace)",job="kube-state-metrics"}
              !=
            kube_daemonset_status_desired_number_scheduled{namespace=~"(appuio.*|cilium|default|kube-.*|nunki-.*|openshift-.*|syn.*)",namespace!~"(openshift-marketplace)",job="kube-state-metrics"}
          )
        ) and (
          changes(kube_daemonset_status_updated_number_scheduled{namespace=~"(appuio.*|cilium|default|kube-.*|nunki-.*|openshift-.*|syn.*)",namespace!~"(openshift-marketplace)",job="kube-state-metrics"}[5m])
            ==
          0
        )
      |||,
      'for': '30m',
      labels: {
        severity: 'warning',
        syn: 'true',
        syn_component: 'openshift4-monitoring',
        syn_team: 'aldebaran',
      },
    },
    'alert:SYN_KubeContainerWaiting': {
      annotations: {
        description: |||
          pod/{{ $labels.pod }} in namespace {{ $labels.namespace }} on container {{ $labels.container}} has been in waiting state for longer than 1 hour. (reason: "{{ $labels.reason }}").
        |||,
        summary: 'Pod container waiting longer than 1 hour',
      },
      expr: |||
        kube_pod_container_status_waiting_reason{reason!="CrashLoopBackOff", namespace=~"(appuio.*|cilium|default|kube-.*|nunki-.*|openshift-.*|syn.*)",namespace!~"(openshift-marketplace)",job="kube-state-metrics"} > 0
      |||,
      'for': '1h',
      labels: {
        severity: 'warning',
        syn: 'true',
        syn_component: 'openshift4-monitoring',
        syn_team: 'aldebaran',
      },
    },
    'alert:SYN_KubeDaemonSetNotScheduled': {
      annotations: {
        description: |||
          {{ $value }} Pods of DaemonSet {{ $labels.namespace }}/{{ $labels.daemonset }} are not scheduled.
        |||,
        summary: 'DaemonSet pods are not scheduled.',
      },
      expr: |||
        kube_daemonset_status_desired_number_scheduled{namespace=~"(appuio.*|cilium|default|kube-.*|nunki-.*|openshift-.*|syn.*)",namespace!~"(openshift-marketplace)",job="kube-state-metrics"}
          -
        kube_daemonset_status_current_number_scheduled{namespace=~"(appuio.*|cilium|default|kube-.*|nunki-.*|openshift-.*|syn.*)",namespace!~"(openshift-marketplace)",job="kube-state-metrics"} > 0
      |||,
      'for': '10m',
      labels: {
        severity: 'warning',
        syn: 'true',
        syn_component: 'openshift4-monitoring',
        syn_team: 'aldebaran',
      },
    },
    'alert:SYN_KubeDaemonSetMisScheduled': {
      annotations: {
        description: |||
          {{ $value }} Pods of DaemonSet {{ $labels.namespace }}/{{ $labels.daemonset }} are running where they are not supposed to run.
        |||,
        summary: 'DaemonSet pods are misscheduled.',
      },
      expr: |||
        kube_daemonset_status_number_misscheduled{namespace=~"(appuio.*|cilium|default|kube-.*|nunki-.*|openshift-.*|syn.*)",namespace!~"(openshift-marketplace)",job="kube-state-metrics"} > 0
      |||,
      'for': '15m',
      labels: {
        severity: 'warning',
        syn: 'true',
        syn_component: 'openshift4-monitoring',
        syn_team: 'aldebaran',
      },
    },
    'alert:SYN_KubeJobNotCompleted': {
      annotations: {
        description: |||
          Job {{ $labels.namespace }}/{{ $labels.job_name }} is taking more than {{ "43200" | humanizeDuration }} to complete.
        |||,
        summary: 'Job did not complete in time',
      },
      expr: |||
        time() - max by(namespace, job_name, cluster) (kube_job_status_start_time{namespace=~"(appuio.*|cilium|default|kube-.*|nunki-.*|openshift-.*|syn.*)",namespace!~"(openshift-marketplace)",job="kube-state-metrics"}
          and
        kube_job_status_active{namespace=~"(appuio.*|cilium|default|kube-.*|nunki-.*|openshift-.*|syn.*)",namespace!~"(openshift-marketplace)",job="kube-state-metrics"} > 0) > 43200
      |||,
      labels: {
        severity: 'warning',
        syn: 'true',
        syn_component: 'openshift4-monitoring',
        syn_team: 'aldebaran',
      },
    },
    'alert:SYN_KubePdbNotEnoughHealthyPods': {
      annotations: {
        description: |||
          PDB {{ $labels.namespace }}/{{ $labels.poddisruptionbudget }} expects {{ $value }} more healthy pods. The desired number of healthy pods has not been met for at least 15m.
        |||,
        summary: 'PDB does not have enough healthy pods.',
      },
      expr: |||
        (
          kube_poddisruptionbudget_status_desired_healthy{namespace=~"(appuio.*|cilium|default|kube-.*|nunki-.*|openshift-.*|syn.*)",namespace!~"(openshift-marketplace)",job="kube-state-metrics"}
          -
          kube_poddisruptionbudget_status_current_healthy{namespace=~"(appuio.*|cilium|default|kube-.*|nunki-.*|openshift-.*|syn.*)",namespace!~"(openshift-marketplace)",job="kube-state-metrics"}
        )
        > 0
      |||,
      'for': '15m',
      labels: {
        severity: 'warning',
        syn: 'true',
        syn_component: 'openshift4-monitoring',
        syn_team: 'aldebaran',
      },
    },
  },
};

local persistentVolumeRules = {
  apiVersion: 'monitoring.coreos.com/v1',
  kind: 'PrometheusRule',
  metadata: {
    name: 'syn-prometheus',
    namespace: params.namespace,
  },
  spec: {
    'alert:SYN_KubePersistentVolumeFillingUp': {
      annotations: {
        description: |||
          The PersistentVolume claimed by {{ $labels.persistentvolumeclaim }} in Namespace {{ $labels.namespace }} {{ with $labels.cluster -}} on Cluster {{ . }} {{- end }} is only {{ $value | humanizePercentage }} free.
        |||,
        runbook_url: 'https://github.com/openshift/runbooks/blob/master/alerts/cluster-monitoring-operator/KubePersistentVolumeFillingUp.md',
        summary: 'PersistentVolume is filling up.',
      },
      expr: |||
        (
          kubelet_volume_stats_available_bytes{namespace=~"(appuio.*|cilium|default|kube-.*|nunki-.*|openshift-.*|syn.*)",namespace!~"(openshift-marketplace)",job="kubelet", metrics_path="/metrics"}
            /
          kubelet_volume_stats_capacity_bytes{namespace=~"(appuio.*|cilium|default|kube-.*|nunki-.*|openshift-.*|syn.*)",namespace!~"(openshift-marketplace)",job="kubelet", metrics_path="/metrics"}
        ) < 0.03
        and
        kubelet_volume_stats_used_bytes{namespace=~"(appuio.*|cilium|default|kube-.*|nunki-.*|openshift-.*|syn.*)",namespace!~"(openshift-marketplace)",job="kubelet", metrics_path="/metrics"} > 0
        unless on(cluster, namespace, persistentvolumeclaim)
        kube_persistentvolumeclaim_access_mode{namespace=~"(appuio.*|cilium|default|kube-.*|nunki-.*|openshift-.*|syn.*)",namespace!~"(openshift-marketplace)", access_mode="ReadOnlyMany"} == 1
        unless on(cluster, namespace, persistentvolumeclaim)
        kube_persistentvolumeclaim_labels{namespace=~"(appuio.*|cilium|default|kube-.*|nunki-.*|openshift-.*|syn.*)",namespace!~"(openshift-marketplace)",label_alerts_k8s_io_kube_persistent_volume_filling_up="disabled"} == 1
      |||,
      'for': '1m',
      labels: {
        severity: 'critical',
        syn: 'true',
        syn_component: 'openshift4-monitoring',
        syn_team: 'aldebaran',
      },
    },
    'alert:SYN_KubePersistentVolumeFillingUpWarning': {
      annotations: {
        description: |||
          Based on recent sampling, the PersistentVolume claimed by {{ $labels.persistentvolumeclaim }} in Namespace {{ $labels.namespace }} {{ with $labels.cluster -}} on Cluster {{ . }} {{- end }} is expected to fill up within four days. Currently {{ $value | humanizePercentage }} is available.
        |||,
        runbook_url: 'https://github.com/openshift/runbooks/blob/master/alerts/cluster-monitoring-operator/KubePersistentVolumeFillingUp.md',
        summary: 'PersistentVolume is filling up.',
      },
      expr: |||
        (
          kubelet_volume_stats_available_bytes{namespace=~"(appuio.*|cilium|default|kube-.*|nunki-.*|openshift-.*|syn.*)",namespace!~"(openshift-marketplace)",job="kubelet", metrics_path="/metrics"}
            /
          kubelet_volume_stats_capacity_bytes{namespace=~"(appuio.*|cilium|default|kube-.*|nunki-.*|openshift-.*|syn.*)",namespace!~"(openshift-marketplace)",job="kubelet", metrics_path="/metrics"}
        ) < 0.15
        and
        kubelet_volume_stats_used_bytes{namespace=~"(appuio.*|cilium|default|kube-.*|nunki-.*|openshift-.*|syn.*)",namespace!~"(openshift-marketplace)",job="kubelet", metrics_path="/metrics"} > 0
        and
        predict_linear(kubelet_volume_stats_available_bytes{namespace=~"(appuio.*|cilium|default|kube-.*|nunki-.*|openshift-.*|syn.*)",namespace!~"(openshift-marketplace)",job="kubelet", metrics_path="/metrics"}[6h], 4 * 24 * 3600) < 0
        unless on(cluster, namespace, persistentvolumeclaim)
        kube_persistentvolumeclaim_access_mode{namespace=~"(appuio.*|cilium|default|kube-.*|nunki-.*|openshift-.*|syn.*)",namespace!~"(openshift-marketplace)", access_mode="ReadOnlyMany"} == 1
        unless on(cluster, namespace, persistentvolumeclaim)
        kube_persistentvolumeclaim_labels{namespace=~"(appuio.*|cilium|default|kube-.*|nunki-.*|openshift-.*|syn.*)",namespace!~"(openshift-marketplace)",label_alerts_k8s_io_kube_persistent_volume_filling_up="disabled"} == 1
      |||,
      'for': '1h',
      labels: {
        severity: 'warning',
        syn: 'true',
        syn_component: 'openshift4-monitoring',
        syn_team: 'aldebaran',
      },
    },
    'alert:SYN_KubePersistentVolumeInodesFillingUp': {
      annotations: {
        description: |||
          The PersistentVolume claimed by {{ $labels.persistentvolumeclaim }} in Namespace {{ $labels.namespace }} {{ with $labels.cluster -}} on Cluster {{ . }} {{- end }} only has {{ $value | humanizePercentage }} free inodes.
        |||,
        runbook_url: 'https://github.com/openshift/runbooks/blob/master/alerts/cluster-monitoring-operator/KubePersistentVolumeInodesFillingUp.md',
        summary: 'PersistentVolumeInodes are filling up.',
      },
      expr: |||
        (
          kubelet_volume_stats_inodes_free{namespace=~"(appuio.*|cilium|default|kube-.*|nunki-.*|openshift-.*|syn.*)",namespace!~"(openshift-marketplace)",job="kubelet", metrics_path="/metrics"}
            /
          kubelet_volume_stats_inodes{namespace=~"(appuio.*|cilium|default|kube-.*|nunki-.*|openshift-.*|syn.*)",namespace!~"(openshift-marketplace)",job="kubelet", metrics_path="/metrics"}
        ) < 0.03
        and
        kubelet_volume_stats_inodes_used{namespace=~"(appuio.*|cilium|default|kube-.*|nunki-.*|openshift-.*|syn.*)",namespace!~"(openshift-marketplace)",job="kubelet", metrics_path="/metrics"} > 0
        unless on(cluster, namespace, persistentvolumeclaim)
        kube_persistentvolumeclaim_access_mode{namespace=~"(appuio.*|cilium|default|kube-.*|nunki-.*|openshift-.*|syn.*)",namespace!~"(openshift-marketplace)", access_mode="ReadOnlyMany"} == 1
        unless on(cluster, namespace, persistentvolumeclaim)
        kube_persistentvolumeclaim_labels{namespace=~"(appuio.*|cilium|default|kube-.*|nunki-.*|openshift-.*|syn.*)",namespace!~"(openshift-marketplace)",label_alerts_k8s_io_kube_persistent_volume_filling_up="disabled"} == 1
      |||,
      'for': '1m',
      labels: {
        severity: 'critical',
        syn: 'true',
        syn_component: 'openshift4-monitoring',
        syn_team: 'aldebaran',
      },
    },
    'alert:SYN_KubePersistentVolumeInodesFillingUpWarning': {
      annotations: {
        description: |||
          Based on recent sampling, the PersistentVolume claimed by {{ $labels.persistentvolumeclaim }} in Namespace {{ $labels.namespace }} {{ with $labels.cluster -}} on Cluster {{ . }} {{- end }} is expected to run out of inodes within four days. Currently {{ $value | humanizePercentage }} of its inodes are free.
        |||,
        runbook_url: 'https://github.com/openshift/runbooks/blob/master/alerts/cluster-monitoring-operator/KubePersistentVolumeInodesFillingUp.md',
        summary: 'PersistentVolumeInodes are filling up.',
      },
      expr: |||
        (
          kubelet_volume_stats_inodes_free{namespace=~"(appuio.*|cilium|default|kube-.*|nunki-.*|openshift-.*|syn.*)",namespace!~"(openshift-marketplace)",job="kubelet", metrics_path="/metrics"}
            /
          kubelet_volume_stats_inodes{namespace=~"(appuio.*|cilium|default|kube-.*|nunki-.*|openshift-.*|syn.*)",namespace!~"(openshift-marketplace)",job="kubelet", metrics_path="/metrics"}
        ) < 0.15
        and
        kubelet_volume_stats_inodes_used{namespace=~"(appuio.*|cilium|default|kube-.*|nunki-.*|openshift-.*|syn.*)",namespace!~"(openshift-marketplace)",job="kubelet", metrics_path="/metrics"} > 0
        and
        predict_linear(kubelet_volume_stats_inodes_free{namespace=~"(appuio.*|cilium|default|kube-.*|nunki-.*|openshift-.*|syn.*)",namespace!~"(openshift-marketplace)",job="kubelet", metrics_path="/metrics"}[6h], 4 * 24 * 3600) < 0
        unless on(cluster, namespace, persistentvolumeclaim)
        kube_persistentvolumeclaim_access_mode{namespace=~"(appuio.*|cilium|default|kube-.*|nunki-.*|openshift-.*|syn.*)",namespace!~"(openshift-marketplace)", access_mode="ReadOnlyMany"} == 1
        unless on(cluster, namespace, persistentvolumeclaim)
        kube_persistentvolumeclaim_labels{namespace=~"(appuio.*|cilium|default|kube-.*|nunki-.*|openshift-.*|syn.*)",namespace!~"(openshift-marketplace)",label_alerts_k8s_io_kube_persistent_volume_filling_up="disabled"} == 1
      |||,
      'for': '1h',
      labels: {
        severity: 'warning',
        syn: 'true',
        syn_component: 'openshift4-monitoring',
        syn_team: 'aldebaran',
      },
    },
    'alert:SYN_KubepersistentVolumeRules': {
      annotations: {
        description: |||
          The persistent volume {{ $labels.persistentvolume }} {{ with $labels.cluster -}} on Cluster {{ . }} {{- end }} has status {{ $labels.phase }}.
        |||,
        summary: 'PersistentVolume is having issues with provisioning.',
      },
      expr: |||
        kube_persistentvolume_status_phase{phase=~"Failed|Pending",namespace=~"(appuio.*|cilium|default|kube-.*|nunki-.*|openshift-.*|syn.*)",namespace!~"(openshift-marketplace)",job="kube-state-metrics"} > 0
      |||,
      'for': '5m',
      labels: {
        severity: 'warning',
        syn: 'true',
        syn_component: 'openshift4-monitoring',
        syn_team: 'aldebaran',
      },
    },
  },
};

{
  namespace: namespace,
} + {
  ['prometheusRule_%s' % rule.metadata.name]: rule
  for rule in [ monitoringOperatorRules, synKubernetesMonitoringRules, persistentVolumeRules ]
}
