# render-checks.jq — assertions over one environment's flattened `helm template` output.
#
# Input:  JSON array of rendered Kubernetes objects (List wrappers already expanded).
# Args:   $env (string), $retention (string), $maxbytes (number),
#         $expected ({enabled:[{job,serviceMonitor}], disabled:[{job,serviceMonitorPattern?}]}),
#         $rules ({<name>: <promtool rule file>}), $dashboards ({<name>: <dashboard JSON>})
# Output: JSON array of failure messages (empty = pass).

def release: "kube-prometheus-stack";
def ns: "monitoring";
def objs($kind): [.[] | select(.kind == $kind)];
def named($kind; $name): [.[] | select(.kind == $kind and .metadata.name == $name)] | first;
def fail_if($cond; $msg): if $cond then [$msg] else [] end;

def pod_specs:
  [ .[] | select(.kind | IN("Deployment","DaemonSet","StatefulSet","ReplicaSet","Job"))
        | {ref: "\(.kind)/\(.metadata.name)", spec: .spec.template.spec} ]
  + [ .[] | select(.kind == "Pod") | {ref: "Pod/\(.metadata.name)", spec: .spec} ];

def missing_resources($r):
  [ "requests.cpu", "requests.memory", "limits.cpu", "limits.memory" ] as $keys
  | [ $keys[] as $k | ($k | split(".")) as $p
      | select(($r[$p[0]][$p[1]] // null) == null) | $k ];

# Effective Prometheus `job` of one ServiceMonitor endpoint, following the operator's
# generated order: Service name -> Service label named by jobLabel (if present) ->
# endpoint relabelings (appended last). Returns null if it cannot be derived from the render.
def static_job_relabel($ep):
  [ ($ep.relabelings // [])[] | select(.targetLabel == "job") ] | last as $r
  | if $r == null then {kind: "none"}
    elif ((($r.action // "replace") | ascii_downcase) == "replace")
         and ((($r.sourceLabels // []) | length) == 0)
         and (($r.regex // "(.*)") == "(.*)")
         and ($r.replacement != null)
    then {kind: "static", job: $r.replacement}
    else {kind: "dynamic"} end;

def selected_services($all; $sm):
  ($sm.spec.namespaceSelector.matchNames // [$sm.metadata.namespace]) as $nss
  | ($sm.spec.selector.matchLabels // {}) as $ml
  | if ($sm.spec.namespaceSelector.any // false) or ($sm.spec.selector.matchExpressions != null)
    then null
    else [ $all[] | select(.kind == "Service")
           | select(.metadata.namespace as $n | $nss | index($n))
           | select(.metadata.labels as $l | $ml | to_entries | all(.value == ($l[.key] // null))) ]
    end;

def endpoint_job($all; $sm; $ep):
  static_job_relabel($ep) as $s
  | if $s.kind == "static" then $s.job
    elif $s.kind == "dynamic" then null
    else selected_services($all; $sm) as $svcs
      | if $svcs == null or ($svcs | length) != 1 then null
        else $svcs[0] as $svc
          | (if ($sm.spec.jobLabel // "") != "" then ($svc.metadata.labels[$sm.spec.jobLabel] // null) else null end)
            // $svc.metadata.name
        end
    end;

def sm_job($all; $sm):
  [ $sm.spec.endpoints[] as $ep | endpoint_job($all; $sm; $ep) ] | unique as $jobs
  | if ($jobs | length) == 1 and $jobs[0] != null then $jobs[0] else null end;

. as $all
| [
    # --- forbidden resources -------------------------------------------------
    fail_if((objs("Alertmanager") | length) > 0; "Alertmanager resource rendered"),
    fail_if((objs("Ingress") | length) > 0; "Ingress rendered"),
    fail_if(([.[] | select(.kind | test("WebhookConfiguration$"))] | length) > 0;
            "admission WebhookConfiguration rendered"),
    ([.[] | select((.metadata.annotations["helm.sh/hook"] // "") | test("test"))
          | "helm test hook rendered: \(.kind)/\(.metadata.name)"]),
    ([.[] | select(.kind == "Service" and ((.spec.type // "ClusterIP") != "ClusterIP"))
          | "Service \(.metadata.name) is \(.spec.type), expected ClusterIP"]),

    # --- Grafana secret contract ---------------------------------------------
    (named("Service"; release + "-grafana") as $s
     | fail_if($s == null; "Grafana Service not rendered")),
    ([.[] | select(.kind == "Secret")
          | select(((.data // {}) + (.stringData // {})) | has("admin-password") or has("admin-user"))
          | "Secret \(.metadata.name) carries Grafana admin credentials"]),
    fail_if(named("Secret"; release + "-grafana") != null; "Grafana admin Secret rendered by the chart"),
    (named("Deployment"; release + "-grafana") as $d
     | ([$d.spec.template.spec.containers[]? | select(.name == "grafana") | .env[]?]) as $env
     | [ {var: "GF_SECURITY_ADMIN_USER", key: "admin-user"},
         {var: "GF_SECURITY_ADMIN_PASSWORD", key: "admin-password"} ][] as $want
     | ([$env[] | select(.name == $want.var)] | first) as $e
     | fail_if(($e.valueFrom.secretKeyRef.name // "") != "grafana-admin"
               or ($e.valueFrom.secretKeyRef.key // "") != $want.key
               or ($e.value != null);
               "\($want.var) must be a secretKeyRef to grafana-admin/\($want.key)")),
    (named("ConfigMap"; release + "-grafana").data["grafana.ini"] // "" as $ini
     | fail_if(($ini | test("\\[auth\\.anonymous\\]\\s*\\nenabled = false")) | not;
               "grafana.ini does not explicitly disable anonymous access")),
    ([pod_specs[] | .ref as $ref | .spec.containers[]? | select(.name == "grafana-sc-dashboard")
          | "dashboard sidecar rendered in \($ref)"]),

    # --- resources -------------------------------------------------------------
    ([pod_specs[] | .ref as $ref
        | ((.spec.initContainers // []) + (.spec.containers // []))[]
        | .name as $c | missing_resources(.resources // {}) as $m
        | select($m | length > 0)
        | "\($ref) container \($c) lacks \($m | join(", "))"]),
    ([objs("Prometheus")[] | missing_resources(.spec.resources // {}) as $m | select($m | length > 0)
        | "Prometheus \(.metadata.name) lacks \($m | join(", "))"]),
    (named("Deployment"; release + "-operator").spec.template.spec.containers[0].args // [] as $args
     | ([ "cpu-request", "cpu-limit", "memory-request", "memory-limit" ][] as $f
        | ([$args[] | select(startswith("--config-reloader-\($f)="))] | first) as $a
        | select($a == null or ($a | endswith("=0")))
        | "operator: config-reloader \($f) not set"),
       ([ "prometheus-instance-namespaces", "alertmanager-instance-namespaces",
          "alertmanager-config-namespaces", "thanos-ruler-instance-namespaces" ][] as $f
        | select(($args | index("--\($f)=\(ns)")) == null)
        | "operator: --\($f) is not scoped to \(ns)")),

    # --- environment sizing contract ------------------------------------------
    ([objs("Prometheus")[] | select(.spec.retention != $retention)
        | "Prometheus retention is \(.spec.retention), expected \($retention) for \($env)"]),
    fail_if((objs("Prometheus") | length) != 1; "expected exactly one Prometheus resource"),

    # --- rules: rendered PrometheusRules == repository sources -----------------
    (([$all | objs("PrometheusRule")[] | .metadata.name] | sort) as $have
     | ([$rules | keys[] | release + "-" + .] | sort) as $want
     | fail_if($have != $want; "PrometheusRule set \($have) != expected \($want)")),
    ([$rules | to_entries[] as $r
        | ($all | named("PrometheusRule"; release + "-" + $r.key)) as $pr
        | select($pr != null and $pr.spec.groups != $r.value.groups)
        | "PrometheusRule \($pr.metadata.name) differs from rules/\($r.key).rules.yaml"]),

    # --- dashboards: rendered ConfigMap == repository sources ------------------
    (named("ConfigMap"; release + "-grafana-dashboards-omnivise") as $cm
     | if $cm == null then ["dashboards ConfigMap not rendered"]
       else
         ([$cm.data | keys[]] | sort) as $have
         | ([$dashboards | keys[] | . + ".json"] | sort) as $want
         | ([$cm.data[] | utf8bytelength] | add) as $bytes
         | fail_if($have != $want; "dashboard keys \($have) != expected \($want)")
           + [ $dashboards | to_entries[] as $d
               | select(($cm.data[$d.key + ".json"] // "null" | fromjson) != $d.value)
               | "dashboard \($d.key) differs from dashboards/\($d.key).json" ]
           + fail_if($bytes > $maxbytes;
                     "dashboards ConfigMap is \($bytes) bytes, project limit \($maxbytes)")
       end),

    # --- expected targets ------------------------------------------------------
    (([$all | objs("ServiceMonitor")[] | .metadata.name] | sort) as $have
     | ([$expected.enabled[].serviceMonitor] | sort) as $want
     | ([$have[] as $n | select(($want | index($n)) == null) | "unexpected ServiceMonitor rendered: \($n)"]
        + [$want[] as $n | select(($have | index($n)) == null) | "expected ServiceMonitor missing: \($n)"])),
    ([$expected.disabled[] | select(.serviceMonitorPattern != null) as $d
        | $all | objs("ServiceMonitor")[] | select(.metadata.name | test($d.serviceMonitorPattern))
        | "ServiceMonitor \(.metadata.name) rendered for disabled job \($d.job)"]),
    ([$expected.enabled[] as $e
        | ($all | named("ServiceMonitor"; $e.serviceMonitor)) as $sm
        | select($sm != null)
        | sm_job($all; $sm) as $job
        | select($job != $e.job)
        | if $job == null
          then "ServiceMonitor \($e.serviceMonitor): effective job cannot be derived from the render"
          else "ServiceMonitor \($e.serviceMonitor): effective job \($job) != expected \($e.job)" end])
  ]
| flatten
