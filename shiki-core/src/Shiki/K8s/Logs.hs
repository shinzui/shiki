-- | Fetch a Job pod's container logs as two distinct slices: a wider
--   in-memory @analysisBuffer@ (up to 1000 lines / 256 KiB) that the
--   analyzer in "Shiki.Analysis.Heuristic" consumes, and a narrower
--   @persistedTail@ (last 200 lines / 64 KiB) suitable for the
--   @runs.log_tail@ column.
--
--   Errors are reported as a tagged 'LogFetchError' so the runner can
--   distinguish \"no pod was created\" from \"the API call failed\" from
--   \"the pod has no logs yet\" — the pre-EP-7 surface returned 'Nothing'
--   for all three.
module Shiki.K8s.Logs
  ( FetchedLogs (..),
    LogFetchError (..),
    fetchJobPodLogs,
    analysisLineCap,
    analysisByteCap,
    persistedLineCap,
    persistedByteCap,
    takeLastLines,
    truncateChars,
  )
where

import Data.Generics.Labels ()
import Data.Text qualified as Text
import Kubernetes.OpenAPI qualified as K8s
import Kubernetes.OpenAPI.API.CoreV1 qualified as CoreV1
import Kubernetes.OpenAPI.ModelLens qualified as K8sLens
import Shiki.K8s.Client (ClientEnv (..))
import Shiki.K8s.Introspection (Namespace (..))
import Shiki.Prelude

-- | The pair of log slices the runner cares about: the wider buffer
--   shown to the analyzer and the narrower tail persisted into the
--   @runs.log_tail@ column.
data FetchedLogs = FetchedLogs
  { analysisBuffer :: !Text,
    persistedTail :: !Text
  }
  deriving stock (Generic, Eq, Show)

-- | Why a log fetch failed. The runner today treats every variant as
--   \"no logs\" but the tagged shape lets future callers report a more
--   useful diagnostic.
data LogFetchError
  = -- | no pod matched @job-name=\<jobName\>@
    NoPodForJob !Text
  | -- | a pod was returned but @metadata.name@ was unset
    PodMissingName !Text
  | -- | listing pods for the job failed with the wrapped 'MimeError'
    PodListFailed !Text !String
  | -- | reading the pod's log failed with the wrapped 'MimeError'
    PodLogReadFailed !Text !String
  deriving stock (Generic, Eq, Show)

analysisLineCap :: Int
analysisLineCap = 1000

analysisByteCap :: Int
analysisByteCap = 262144 -- 256 KiB measured in characters

persistedLineCap :: Int
persistedLineCap = 200

persistedByteCap :: Int
persistedByteCap = 65536 -- 64 KiB measured in characters

-- | Fetch the analysis buffer and derive the persisted tail. Issues one
--   list-pods call to locate the pod, then one read-log call against it
--   asking for the last 'analysisLineCap' lines. The persisted tail is
--   carved out of the analysis buffer in-memory.
fetchJobPodLogs ::
  ClientEnv ->
  Namespace ->
  Text ->
  IO (Either LogFetchError FetchedLogs)
fetchJobPodLogs env ns jobName = do
  let listReq =
        CoreV1.listNamespacedPod
          (K8s.Accept K8s.MimeJSON)
          (K8s.Namespace (unNamespace ns))
          `K8s.applyOptionalParam` K8s.LabelSelector ("job-name=" <> jobName)
  listResp <- K8s.dispatchMime (env ^. #httpManager) (env ^. #clientConfig) listReq
  case K8s.mimeResult listResp of
    Left err -> pure (Left (PodListFailed jobName (show err)))
    Right pl -> case pl ^. K8sLens.v1PodListItemsL of
      [] -> pure (Left (NoPodForJob jobName))
      (pod : _) ->
        case pod ^. K8sLens.v1PodMetadataL >>= (^. K8sLens.v1ObjectMetaNameL) of
          Nothing -> pure (Left (PodMissingName jobName))
          Just nm -> fetchPodLog env ns nm

fetchPodLog :: ClientEnv -> Namespace -> Text -> IO (Either LogFetchError FetchedLogs)
fetchPodLog env ns nm = do
  let logReq =
        CoreV1.readNamespacedPodLog
          (K8s.Accept K8s.MimePlainText)
          (K8s.Name nm)
          (K8s.Namespace (unNamespace ns))
          `K8s.applyOptionalParam` K8s.TailLines analysisLineCap
  logResp <- K8s.dispatchMime (env ^. #httpManager) (env ^. #clientConfig) logReq
  case K8s.mimeResult logResp of
    Left err -> pure (Left (PodLogReadFailed nm (show err)))
    Right txt ->
      let buf = truncateChars analysisByteCap txt
          tail_ = truncateChars persistedByteCap (takeLastLines persistedLineCap buf)
       in pure (Right FetchedLogs {analysisBuffer = buf, persistedTail = tail_})

-- | Keep the trailing @n@ lines of @t@. \"Line\" means \"text between
--   @\\n@ characters\"; the result always ends with @\\n@ iff the input
--   did and contains no leading newline introduced by the slicing.
takeLastLines :: Int -> Text -> Text
takeLastLines n t
  | n <= 0 = ""
  | otherwise =
      let ls = Text.splitOn "\n" t
          kept = drop (length ls - n) ls
       in Text.intercalate "\n" kept

-- | Cap a 'Text' at @n@ characters, keeping the end of the string so the
--   most recent output survives.
truncateChars :: Int -> Text -> Text
truncateChars n t
  | Text.length t <= n = t
  | otherwise = Text.takeEnd n t
