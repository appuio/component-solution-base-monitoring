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

{
  namespace: namespace,
} + {
  ['prometheusRule_%s' % rule.metadata.name]: rule
  for rule in [ monitoringOperatorRules ]
}
