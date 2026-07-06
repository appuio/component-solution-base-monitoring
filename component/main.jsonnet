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

local defaultRuleLabels = {
  syn: 'true',
  syn_component: 'solution-base-monitoring',
  syn_team: '{{ $labels.label_syn_team }}',
};

local openshiftRules = std.parseJson(
  kap.yaml_load('solution-base-monitoring/component/openshift-rules.yml')
).rules;

local monitor_namespaces = params.monitor_namespaces;
local namespaceLabelFilter = 'and on(namespace) kube_namespace_labels{label_%s="%s"}' % [
  monitor_namespaces.label,
  monitor_namespaces.label_value,
];
local teamJoin = '* on(namespace) group_left(label_syn_team) kube_namespace_labels';

local patchRule(r) =
  std.mergePatch(
    { labels: defaultRuleLabels },
    std.mergePatch(r, { expr: r.expr % {
      namespaceLabelFilter: namespaceLabelFilter,
      teamJoin: teamJoin,
    } }),
  );

local buildManifest(m) =
  m {
    metadata+: {
      namespace: params.namespace,
    },
    spec+: {
      groups: [
        g { rules: [ patchRule(r) for r in g.rules ] }
        for g in m.spec.groups
      ],
    },
  };

{
  namespace: namespace,
} + {
  ['prometheusRule_%s' % m.metadata.name]: buildManifest(m)
  for m in openshiftRules
}
