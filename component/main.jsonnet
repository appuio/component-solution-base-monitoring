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

{
  namespace: namespace,
}
