SHIKI LONG RUNS


Read this before running a command that may take more than a few minutes
(an initial import or a full sync can take a day or more), and especially
when you are an agent driving shiki. Every rule below comes from a real run
that was lost, mis-recorded, or watched wastefully.


RULE 1: DO NOT BLOCK ON A LONG RUN; SUBMIT WITH --no-wait

'shiki run' without --no-wait keeps a local process polling the Job until it
ends. On a laptop or inside an agent session that process does not survive
a day: the terminal closes, the machine sleeps, or the host kills the
process (agent harnesses stop background tasks under memory pressure).
Killing it does not stop the Job, but nothing is left to record the result,
so the run stays 'running' forever.

  shiki run <service> --no-wait -- <args...>

Then reconcile the row later with 'shiki runs sync' (rule 3).


RULE 2: A 'running' ROW IS NOT PROOF THE JOB IS RUNNING

The runs table only reflects what the last shiki process wrote. Before
reporting a run as running, succeeded, or failed, check the Job itself:

  kubectl get job -n <namespace> <job_name>

or let shiki do it and update the row in the same step:

  shiki runs sync <id>


RULE 3: RECORD THE OUTCOME WITH 'shiki runs sync'

  shiki runs sync            Every pending/running run.
  shiki runs sync <id>       One run.

sync reads each run's Job and writes what the cluster reports: the real
status, the Job's own end time, the log tail, and an error summary. A Job
that is still active is left 'running'. Run it any time after the Job ends,
within the Job's TTL (rule 5).


RULE 4: POLL SPARINGLY

A day-long import does not need a status check every few seconds or
minutes. Check a long run every 15 to 30 minutes, or once near its expected
end; each 'shiki runs sync' or 'kubectl get job' is a round trip to the
cluster API. Do not write tight watch loops.


RULE 5: SYNC WITHIN THE TTL, OR THE OUTCOME IS LOST

A finished Job, its pod, and its logs are deleted ttlSecondsAfterFinished
seconds after it ends: 7 days by default, or the service's
ttlSecondsAfterFinished setting (see 'shiki help services'). After that,
sync can only record the run as failed with "outcome is unknown". Never
lower the TTL below the longest gap in which nobody will sync.


RULE 6: CHECK THE KUBE CONTEXT BEFORE SUBMITTING

shiki has no --context flag. It uses the current-context of the single
kubeconfig file named by KUBECONFIG (or ~/.kube/config), and it does not
merge a colon-separated KUBECONFIG list. Confirm the target first:

  kubectl config current-context

An error such as 'HostCannotConnect "0.0.0.0"' or 'connection refused'
means the current context points at a local cluster (k3d, kind) that is
not running; nothing was submitted. To target another cluster without
changing the operator's global context, give shiki a one-context copy:

  kubectl config view --minify --flatten --context <ctx> > <tmp>/kubeconfig
  KUBECONFIG=<tmp>/kubeconfig shiki run ...

Delete that file afterwards; it holds cluster credentials.

sync refuses to mark a run lost when the service's Deployment is missing
from the run's namespace, since that usually means a context for the wrong
cluster; it reports the problem and leaves the row unchanged.


WHAT SHIKI ALREADY HANDLES

  Node scale-down        Job pods carry cluster-autoscaler.kubernetes.io/
                         safe-to-evict: "false", so the autoscaler does
                         not drain their node mid-run. (Jobs have
                         backoffLimit 0; one lost pod fails the run.)
  Credential expiry      An expired exec-plugin token (GKE) is renewed
                         during a blocking wait instead of failing it.
  Idempotent writes      sync never overwrites an outcome another shiki
                         process already recorded.


A LONG RUN, END TO END

  kubectl config current-context
  shiki run <service> --no-wait -- <args...>       note the run id
  shiki runs sync <id>                             every 15-30 min, or near
                                                   the expected end
  shiki runs show <id>                             once it has finished


Full reference: docs/user/commands.md
See also: 'shiki help runs', 'shiki help env', 'shiki help services'.
