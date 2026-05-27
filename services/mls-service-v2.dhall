let EnvSource =
      < ConfigMap : { key : Text }
      | Secret : { key : Text }
      | Literal : { value : Text }
      >

let EnvVar = { name : Text, source : EnvSource }

let mkConfigEnv =
      \(name : Text) ->
        { name = name, source = EnvSource.ConfigMap { key = name } }

let mkSecretEnv =
      \(name : Text) ->
        { name = name, source = EnvSource.Secret { key = name } }

let CommonEnv =
      [ mkConfigEnv "PROJECT_ID"
      , mkConfigEnv "DATABASE_NAME"
      , mkConfigEnv "DATABASE_USER"
      , mkSecretEnv "DATABASE_PASSWORD"
      , { name = "PG_CONNECTION_STRING"
        , source =
            EnvSource.Literal
              { value =
                  "postgresql://\$(DATABASE_USER):\$(DATABASE_PASSWORD)@localhost:5432/\$(DATABASE_NAME)"
              }
        }
      , mkConfigEnv "HASKELL_ENV"
      , mkConfigEnv "PG_POOL_SIZE"
      , mkSecretEnv "C1_OAUTH_CLIENT_ID"
      , mkSecretEnv "C1_OAUTH_CLIENT_SECRET"
      , mkConfigEnv "OTEL_SERVICE_NAME"
      , mkConfigEnv "OTEL_EXPORTER_OTLP_ENDPOINT"
      , mkSecretEnv "OTEL_EXPORTER_OTLP_HEADERS"
      , mkConfigEnv "OTEL_SDK_DISABLED"
      ]

let AnalyzerBackend = ../shiki-core/dhall/AnalyzerBackend.dhall

in  { name = "mls-service-v2"
    , defaultNamespace = "prod"
    , detectFromDeployment = "mls-service-v2-worker"
    , containerName = "mls-service-v2"
    , commandPath = "/app/mls-service-v2"
    , serviceAccount = "mls-service-v2"
    , nodeSelector =
        toMap { `iam.gke.io/gke-metadata-server-enabled` = "true" }
    , initContainers =
        [ { name = "cloud-sql-proxy"
          , image = "gcr.io/cloud-sql-connectors/cloud-sql-proxy:2.21.0"
          , args = [ "\$(DATABASE_INSTANCE)?port=5432" ]
          , env =
              [ mkConfigEnv "DATABASE_INSTANCE"
              , { name = "CSQL_PROXY_HEALTH_CHECK"
                , source = EnvSource.Literal { value = "true" }
                }
              , { name = "CSQL_PROXY_HTTP_PORT"
                , source = EnvSource.Literal { value = "9090" }
                }
              , { name = "CSQL_PROXY_HTTP_ADDRESS"
                , source = EnvSource.Literal { value = "0.0.0.0" }
                }
              , { name = "CSQL_PROXY_EXIT_ZERO_ON_SIGTERM"
                , source = EnvSource.Literal { value = "true" }
                }
              , { name = "CSQL_PROXY_STRUCTURED_LOGS"
                , source = EnvSource.Literal { value = "true" }
                }
              ]
          , resources =
              { cpuRequest = "50m"
              , cpuLimit = "300m"
              , memoryRequest = "16Mi"
              , memoryLimit = "64Mi"
              }
          , restartable = True
          }
        ]
    , env = CommonEnv
    , resources =
        { cpuRequest = "500m"
        , cpuLimit = "2"
        , memoryRequest = "512Mi"
        , memoryLimit = "4096Mi"
        }
    , analyzer = AnalyzerBackend.Heuristic
    }
