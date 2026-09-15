SHIKI SERVICES


A "service" in shiki is a Kubernetes workload that shiki can submit one-off
Jobs against. Each service is described by one Dhall configuration file
under the services/ directory at the operator's working directory:

  services/
    mls-service-v2.dhall
    other-service.dhall


SERVICE CONFIG FIELDS

  name                  Logical service name. Must match the file name
                        without the .dhall extension.

  defaultNamespace      Kubernetes namespace used when no --namespace flag
                        is given to 'shiki run'.

  detectFromDeployment  Name of the live Deployment 'shiki run' introspects
                        to pick up the current image digest, ConfigMap
                        names, Secret names, etc. at submit time.

  containerName         Which container inside that Deployment to mirror
                        (e.g. the application container next to a
                        cloud-sql-proxy sidecar).

  commandPath           Path to the binary inside the container image;
                        becomes the Job container's command[0]. Everything
                        after '--' on the 'shiki run' command line is
                        appended as ARGS.

  serviceAccount        Kubernetes ServiceAccount attached to the Job pod.

  nodeSelector          Optional pod nodeSelector map.

  initContainers        Init containers attached to every run (e.g. a
                        restartable cloud-sql-proxy).

  env                   Environment variables; each is ConfigMap, Secret,
                        or Literal-sourced.

  resources             CPU and memory requests/limits for the main
                        container.

  analyzer              Default analyzer backend for failed runs. One of:
                        Heuristic, Baikai { model = "<id>" }, None.
                        'shiki run' always uses Heuristic; 'shiki runs
                        analyze' honors this default unless --analyzer
                        overrides it.

  ttlSecondsAfterFinished
                        Optional (Natural). Seconds a finished Job, its
                        pod, and its logs stay in the cluster; omit it
                        for the 7-day default. 'shiki runs sync' needs
                        the Job to still exist to record the real
                        outcome, so keep this longer than the longest gap
                        in which nobody will sync. Example:
                        ttlSecondsAfterFinished = Some 1209600


INSPECTING A SERVICE

Use 'shiki service show <name>' to pretty-print one service config as JSON
without touching the cluster or the database:

  shiki service show mls-service-v2


ADDING A NEW SERVICE

  1. Create services/<name>.dhall.
  2. Set name = "<name>" (it must match the file name).
  3. Fill in defaultNamespace, detectFromDeployment, containerName,
     commandPath, serviceAccount, resources, env, and analyzer. The repo
     ships services/mls-service-v2.dhall as a worked example.
  4. Run 'shiki service show <name>' to verify the file parses.


Full reference: docs/user/service-config.md
See also: 'shiki help runs', 'shiki help analyzers'.
