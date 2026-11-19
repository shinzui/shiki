-- | Fetch a Job pod's container logs as two distinct slices: a wider
--   in-memory @analysisBuffer@ (up to 1000 lines / 256 KiB) that the
--   analyzer in "Shiki.Analysis.Heuristic" consumes, and a narrower
--   @persistedTail@ (last 200 lines / 64 KiB) suitable for the
--   @runs.log_tail@ column.
--
--   Errors are reported as a tagged 'LogFetchError' so the runner can
--   distinguish \"no pod was created\" from \"the API call failed\" from
--   \"the pod has no logs yet\" — the pre-EP-7 surface returned 'Nothing'
--   for all three. 'renderLogFetchError' turns one into the line the CLI
--   prints when a run's log could not be captured.
module Shiki.K8s.Logs
  ( FetchedLogs (..),
    LogFetchError (..),
    PodLogText (..),
    fetchJobPodLogs,
    renderLogFetchError,
    analysisLineCap,
    analysisByteCap,
    persistedLineCap,
    persistedByteCap,
    takeLastLines,
    truncateChars,
  )
where

import Data.ByteString.Lazy qualified as BL
import Data.Generics.Labels ()
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TE
import Kubernetes.OpenAPI qualified as K8s
import Kubernetes.OpenAPI.API.CoreV1 qualified as CoreV1
import Kubernetes.OpenAPI.ModelLens qualified as K8sLens
import Network.HTTP.Client (responseBody, responseStatus)
import Network.HTTP.Types.Status (statusCode)
import Shiki.K8s.Client (ClientEnv (..), dispatchK8s)
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

-- | Why a log fetch failed. The run is still recorded without a log tail,
--   and the runner hands the rendered error to the CLI, which warns about it.
data LogFetchError
  = -- | no pod matched @job-name=\<jobName\>@
    NoPodForJob !Text
  | -- | a pod was returned but @metadata.name@ was unset
    PodMissingName !Text
  | -- | listing pods for the job failed; carries the rendered 'K8s.MimeError'
    PodListFailed !Text !Text
  | -- | reading the pod's log failed; carries the rendered 'K8s.MimeError'
    PodLogReadFailed !Text !Text
  deriving stock (Generic, Eq, Show)

-- | One line saying why a run's log could not be captured.
renderLogFetchError :: LogFetchError -> Text
renderLogFetchError = \case
  NoPodForJob job -> "no pod found for job " <> job
  PodMissingName job -> "the pod for job " <> job <> " has no name"
  PodListFailed job err -> "listing the pods of job " <> job <> " failed: " <> err
  PodLogReadFailed pod err -> "reading the log of pod " <> pod <> " failed: " <> err

-- | The status code, the client's message, and the start of the response body
--   (the API server's @Status@ object, which says why it refused). Showing the
--   whole 'K8s.MimeError' would dump http-client's request record.
renderMimeError :: K8s.MimeError -> Text
renderMimeError err =
  let resp = K8s.mimeErrorResponse err
      body = TE.decodeUtf8Lenient (BL.toStrict (responseBody resp))
   in "HTTP "
        <> Text.pack (show (statusCode (responseStatus resp)))
        <> " ("
        <> Text.pack (K8s.mimeError err)
        <> "): "
        <> Text.take 500 (Text.unwords (Text.words body))

-- | The accept type for the @pods/log@ request.
--
--   The generated client offers 'K8s.MimePlainText', which sends
--   @Accept: text/plain@. GKE's 1.35 API server answers that with
--   @406 Not Acceptable@ (\"only the following media types are accepted:
--   application/json, application/yaml, application/vnd.kubernetes.protobuf\"),
--   so on GKE 1.35 every run was recorded with no log tail. With @Accept: */*@,
--   as @kubectl logs@ sends, the server still returns the log as @text/plain@.
--
--   The body is decoded leniently: a log line with invalid UTF-8 should not
--   cost the whole tail.
data PodLogText = PodLogText

instance K8s.MimeType PodLogText where
  mimeType _ = K8s.mimeType (Proxy @K8s.MimeAny)

instance K8s.MimeUnrender PodLogText Text where
  mimeUnrender _ = Right . TE.decodeUtf8Lenient . BL.toStrict

instance K8s.Produces CoreV1.ReadNamespacedPodLog PodLogText

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
  listResp <- dispatchK8s env listReq
  case K8s.mimeResult listResp of
    Left err -> pure (Left (PodListFailed jobName (renderMimeError err)))
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
          (K8s.Accept PodLogText)
          (K8s.Name nm)
          (K8s.Namespace (unNamespace ns))
          `K8s.applyOptionalParam` K8s.TailLines analysisLineCap
  logResp <- dispatchK8s env logReq
  case K8s.mimeResult logResp of
    Left err -> pure (Left (PodLogReadFailed nm (renderMimeError err)))
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
