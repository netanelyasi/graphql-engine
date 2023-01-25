{-# LANGUAGE CPP #-}

module Hasura.Server.App
  ( APIResp (JSONResp, RawResp),
    ConsoleRenderer (..),
    MonadVersionAPIWithExtraData (..),
    Handler,
    HandlerCtx (hcReqHeaders, hcServerCtx, hcUser),
    HasuraApp (HasuraApp),
    Loggers (..),
    MonadConfigApiHandler (..),
    MonadMetadataApiAuthorization (..),
    ServerCtx (..),
    boolToText,
    configApiGetHandler,
    isAdminSecretSet,
    mkGetHandler,
    mkSpockAction,
    mkWaiApp,
    onlyAdmin,
    renderHtmlTemplate,
  )
where

import Control.Concurrent.Async.Lifted.Safe qualified as LA
import Control.Concurrent.STM qualified as STM
import Control.Exception (IOException, try)
import Control.Monad.Stateless
import Control.Monad.Trans.Control (MonadBaseControl)
import Control.Monad.Trans.Control qualified as MTC
import Data.Aeson hiding (json)
import Data.Aeson qualified as J
import Data.Aeson.Key qualified as K
import Data.Aeson.KeyMap qualified as KM
import Data.Aeson.Types qualified as J
import Data.ByteString.Char8 qualified as B8
import Data.ByteString.Lazy qualified as BL
import Data.CaseInsensitive qualified as CI
import Data.Environment qualified as Env
import Data.HashMap.Strict qualified as M
import Data.HashSet qualified as S
import Data.String (fromString)
import Data.Text qualified as T
import Data.Text.Conversions (convertText)
import Data.Text.Extended
import Data.Text.Lazy qualified as LT
import Data.Text.Lazy.Encoding qualified as TL
import Database.PG.Query qualified as PG
import GHC.Stats.Extended qualified as RTS
import Hasura.Backends.DataConnector.API (openApiSchema)
import Hasura.Backends.Postgres.Execute.Types
import Hasura.Base.Error
import Hasura.EncJSON
import Hasura.GraphQL.Execute qualified as E
import Hasura.GraphQL.Execute.Backend qualified as EB
import Hasura.GraphQL.Execute.Subscription.State qualified as ES
import Hasura.GraphQL.Explain qualified as GE
import Hasura.GraphQL.Logging (MonadQueryLog)
import Hasura.GraphQL.Schema.NamingCase
import Hasura.GraphQL.Schema.Options qualified as Options
import Hasura.GraphQL.Transport.HTTP qualified as GH
import Hasura.GraphQL.Transport.HTTP.Protocol qualified as GH
import Hasura.GraphQL.Transport.WSServerApp qualified as WS
import Hasura.GraphQL.Transport.WebSocket.Server qualified as WS
import Hasura.HTTP
import Hasura.Logging qualified as L
import Hasura.Metadata.Class
import Hasura.Prelude hiding (get, put)
import Hasura.RQL.DDL.EventTrigger (MonadEventLogCleanup)
import Hasura.RQL.DDL.Schema
import Hasura.RQL.Types.Common
import Hasura.RQL.Types.Endpoint as EP
import Hasura.RQL.Types.Metadata (MetadataDefaults)
import Hasura.RQL.Types.SchemaCache
import Hasura.RQL.Types.Source
import Hasura.SQL.Backend
import Hasura.Server.API.Config (runGetConfig)
import Hasura.Server.API.Metadata
import Hasura.Server.API.PGDump qualified as PGD
import Hasura.Server.API.Query
import Hasura.Server.API.V2Query qualified as V2Q
import Hasura.Server.Auth (AuthMode (..), UserAuthentication (..))
import Hasura.Server.Compression
import Hasura.Server.Cors
import Hasura.Server.Init
import Hasura.Server.Limits
import Hasura.Server.Logging
import Hasura.Server.Metrics (ServerMetrics)
import Hasura.Server.Middleware (corsMiddleware)
import Hasura.Server.OpenAPI (buildOpenAPI)
import Hasura.Server.Prometheus (PrometheusMetrics)
import Hasura.Server.Rest
import Hasura.Server.SchemaCacheRef
  ( SchemaCacheRef,
    getSchemaCache,
    readSchemaCacheRef,
    withSchemaCacheUpdate,
  )
import Hasura.Server.Types
import Hasura.Server.Utils
import Hasura.Server.Version
import Hasura.Session
import Hasura.ShutdownLatch
import Hasura.Tracing qualified as Tracing
import Network.HTTP.Client qualified as HTTP
import Network.HTTP.Types qualified as HTTP
import Network.Mime (defaultMimeLookup)
import Network.Wai.Extended qualified as Wai
import Network.Wai.Handler.WebSockets.Custom qualified as WSC
import Network.WebSockets qualified as WS
import System.FilePath (joinPath, takeFileName)
import System.Mem (performMajorGC)
import System.Metrics qualified as EKG
import System.Metrics.Json qualified as EKG
import Text.Mustache qualified as M
import Web.Spock.Core ((<//>))
import Web.Spock.Core qualified as Spock

data ServerCtx = ServerCtx
  { scLoggers :: !Loggers,
    scCacheRef :: !SchemaCacheRef,
    scAuthMode :: !AuthMode,
    scManager :: !HTTP.Manager,
    scSQLGenCtx :: !SQLGenCtx,
    scEnabledAPIs :: !(S.HashSet API),
    scInstanceId :: !InstanceId,
    scSubscriptionState :: !ES.SubscriptionsState,
    scEnableAllowlist :: !Bool,
    scResponseInternalErrorsConfig :: !ResponseInternalErrorsConfig,
    scEnvironment :: !Env.Environment,
    scRemoteSchemaPermsCtx :: !Options.RemoteSchemaPermissions,
    scFunctionPermsCtx :: !Options.InferFunctionPermissions,
    scEnableMaintenanceMode :: !(MaintenanceMode ()),
    scExperimentalFeatures :: !(S.HashSet ExperimentalFeature),
    scLoggingSettings :: !LoggingSettings,
    scEventingMode :: !EventingMode,
    scEnableReadOnlyMode :: !ReadOnlyMode,
    scDefaultNamingConvention :: !(Maybe NamingCase),
    scServerMetrics :: !ServerMetrics,
    scMetadataDefaults :: !MetadataDefaults,
    scEnabledLogTypes :: HashSet (L.EngineLogType L.Hasura),
    scMetadataDbPool :: PG.PGPool,
    scShutdownLatch :: ShutdownLatch,
    scMetaVersionRef :: STM.TMVar MetadataResourceVersion,
    scPrometheusMetrics :: PrometheusMetrics,
    scTraceSamplingPolicy :: Tracing.SamplingPolicy,
    scCheckFeatureFlag :: !(FeatureFlag -> IO Bool)
  }

-- | Collection of the LoggerCtx, the regular Logger and the PGLogger
-- TODO (from master): better naming?
data Loggers = Loggers
  { _lsLoggerCtx :: !(L.LoggerCtx L.Hasura),
    _lsLogger :: !(L.Logger L.Hasura),
    _lsPgLogger :: !PG.PGLogger
  }

data HandlerCtx = HandlerCtx
  { hcServerCtx :: !ServerCtx,
    hcUser :: !UserInfo,
    hcReqHeaders :: ![HTTP.Header],
    hcRequestId :: !RequestId,
    hcSourceIpAddress :: !Wai.IpAddress
  }

type Handler m = ReaderT HandlerCtx (MetadataStorageT m)

data APIResp
  = JSONResp !(HttpResponse EncJSON)
  | RawResp !(HttpResponse BL.ByteString)

-- | API request handlers for different endpoints
data APIHandler m a where
  -- | A simple GET request
  AHGet :: !(Handler m (HttpLogGraphQLInfo, APIResp)) -> APIHandler m void
  -- | A simple POST request that expects a request body from which an 'a' can be extracted
  AHPost :: !(a -> Handler m (HttpLogGraphQLInfo, APIResp)) -> APIHandler m a
  -- | A general GraphQL request (query or mutation) for which the content of the query
  -- is made available to the handler for authentication.
  -- This is a more specific version of the 'AHPost' constructor.
  AHGraphQLRequest :: !(GH.ReqsText -> Handler m (HttpLogGraphQLInfo, APIResp)) -> APIHandler m GH.ReqsText

boolToText :: Bool -> Text
boolToText = bool "false" "true"

isAdminSecretSet :: AuthMode -> Text
isAdminSecretSet AMNoAuth = boolToText False
isAdminSecretSet _ = boolToText True

mkGetHandler :: Handler m (HttpLogGraphQLInfo, APIResp) -> APIHandler m ()
mkGetHandler = AHGet

mkPostHandler :: (a -> Handler m (HttpLogGraphQLInfo, APIResp)) -> APIHandler m a
mkPostHandler = AHPost

mkGQLRequestHandler :: (GH.ReqsText -> Handler m (HttpLogGraphQLInfo, APIResp)) -> APIHandler m GH.ReqsText
mkGQLRequestHandler = AHGraphQLRequest

mkAPIRespHandler :: (Functor m) => (a -> Handler m (HttpResponse EncJSON)) -> (a -> Handler m APIResp)
mkAPIRespHandler = (fmap . fmap) JSONResp

mkGQLAPIRespHandler ::
  (Functor m) =>
  (a -> Handler m (b, (HttpResponse EncJSON))) ->
  (a -> Handler m (b, APIResp))
mkGQLAPIRespHandler = (fmap . fmap . fmap) JSONResp

isMetadataEnabled :: ServerCtx -> Bool
isMetadataEnabled sc = S.member METADATA $ scEnabledAPIs sc

isGraphQLEnabled :: ServerCtx -> Bool
isGraphQLEnabled sc = S.member GRAPHQL $ scEnabledAPIs sc

isPGDumpEnabled :: ServerCtx -> Bool
isPGDumpEnabled sc = S.member PGDUMP $ scEnabledAPIs sc

isConfigEnabled :: ServerCtx -> Bool
isConfigEnabled sc = S.member CONFIG $ scEnabledAPIs sc

isDeveloperAPIEnabled :: ServerCtx -> Bool
isDeveloperAPIEnabled sc = S.member DEVELOPER $ scEnabledAPIs sc

-- {-# SCC parseBody #-}
parseBody :: (FromJSON a, MonadError QErr m) => BL.ByteString -> m (Value, a)
parseBody reqBody =
  case eitherDecode' reqBody of
    Left e -> throw400 InvalidJSON (T.pack e)
    Right jVal -> (jVal,) <$> decodeValue jVal

onlyAdmin :: (MonadError QErr m, MonadReader HandlerCtx m) => m ()
onlyAdmin = do
  uRole <- asks (_uiRole . hcUser)
  unless (uRole == adminRoleName) $
    throw400 AccessDenied "You have to be an admin to access this endpoint"

setHeader :: MonadIO m => HTTP.Header -> Spock.ActionT m ()
setHeader (headerName, headerValue) =
  Spock.setHeader (bsToTxt $ CI.original headerName) (bsToTxt headerValue)

-- | Typeclass representing the metadata API authorization effect
class (Monad m) => MonadMetadataApiAuthorization m where
  authorizeV1QueryApi ::
    RQLQuery -> HandlerCtx -> m (Either QErr ())

  authorizeV1MetadataApi ::
    RQLMetadata -> HandlerCtx -> m (Either QErr ())

  authorizeV2QueryApi ::
    V2Q.RQLQuery -> HandlerCtx -> m (Either QErr ())

instance MonadMetadataApiAuthorization m => MonadMetadataApiAuthorization (ReaderT r m) where
  authorizeV1QueryApi q hc = lift $ authorizeV1QueryApi q hc
  authorizeV1MetadataApi q hc = lift $ authorizeV1MetadataApi q hc
  authorizeV2QueryApi q hc = lift $ authorizeV2QueryApi q hc

instance MonadMetadataApiAuthorization m => MonadMetadataApiAuthorization (MetadataStorageT m) where
  authorizeV1QueryApi q hc = lift $ authorizeV1QueryApi q hc
  authorizeV1MetadataApi q hc = lift $ authorizeV1MetadataApi q hc
  authorizeV2QueryApi q hc = lift $ authorizeV2QueryApi q hc

instance MonadMetadataApiAuthorization m => MonadMetadataApiAuthorization (Tracing.TraceT m) where
  authorizeV1QueryApi q hc = lift $ authorizeV1QueryApi q hc
  authorizeV1MetadataApi q hc = lift $ authorizeV1MetadataApi q hc
  authorizeV2QueryApi q hc = lift $ authorizeV2QueryApi q hc

-- | The config API (/v1alpha1/config) handler
class Monad m => MonadConfigApiHandler m where
  runConfigApiHandler ::
    ServerCtx ->
    -- | console assets directory
    Maybe Text ->
    Spock.SpockCtxT () m ()

-- instance (MonadIO m, UserAuthentication m, HttpLog m, Tracing.HasReporter m) => MonadConfigApiHandler (Tracing.TraceT m) where
--   runConfigApiHandler = configApiGetHandler

mapActionT ::
  (Monad m, Monad n) =>
  (m (MTC.StT (Spock.ActionCtxT ()) a) -> n (MTC.StT (Spock.ActionCtxT ()) a)) ->
  Spock.ActionT m a ->
  Spock.ActionT n a
mapActionT f tma = MTC.restoreT . pure =<< MTC.liftWith (\run -> f (run tma))

mkSpockAction ::
  forall m a.
  ( MonadIO m,
    MonadBaseControl IO m,
    FromJSON a,
    UserAuthentication (Tracing.TraceT m),
    HttpLog m,
    Tracing.HasReporter m,
    HasResourceLimits m
  ) =>
  ServerCtx ->
  -- | `QErr` JSON encoder function
  (Bool -> QErr -> Value) ->
  -- | `QErr` modifier
  (QErr -> QErr) ->
  APIHandler (Tracing.TraceT m) a ->
  Spock.ActionT m ()
mkSpockAction serverCtx@ServerCtx {..} qErrEncoder qErrModifier apiHandler = do
  req <- Spock.request
  let origHeaders = Wai.requestHeaders req
      ipAddress = Wai.getSourceFromFallback req
      pathInfo = Wai.rawPathInfo req

  -- Bytes are actually read from the socket here. Time this.
  (ioWaitTime, reqBody) <- withElapsedTime $ liftIO $ Wai.strictRequestBody req

  (requestId, headers) <- getRequestId origHeaders
  tracingCtx <- liftIO $ Tracing.extractB3HttpContext headers
  handlerLimit <- lift askHTTPHandlerLimit

  let runTraceT ::
        forall m1 a1.
        (MonadIO m1, MonadBaseControl IO m1, Tracing.HasReporter m1) =>
        Tracing.TraceT m1 a1 ->
        m1 a1
      runTraceT = do
        (maybe Tracing.runTraceT Tracing.runTraceTInContext tracingCtx)
          scTraceSamplingPolicy
          (fromString (B8.unpack pathInfo))

      runHandler ::
        MonadBaseControl IO m2 =>
        HandlerCtx ->
        ReaderT HandlerCtx (MetadataStorageT m2) a2 ->
        m2 (Either QErr a2)
      runHandler handlerCtx handler =
        runMetadataStorageT $ flip runReaderT handlerCtx $ runResourceLimits handlerLimit $ handler

      getInfo parsedRequest = do
        authenticationResp <- lift (resolveUserInfo (_lsLogger scLoggers) scManager headers scAuthMode parsedRequest)
        authInfo <- onLeft authenticationResp (logErrorAndResp Nothing requestId req (reqBody, Nothing) False origHeaders (ExtraUserInfo Nothing) . qErrModifier)
        let (userInfo, _, authHeaders, extraUserInfo) = authInfo
        pure
          ( userInfo,
            authHeaders,
            HandlerCtx serverCtx userInfo headers requestId ipAddress,
            shouldIncludeInternal (_uiRole userInfo) scResponseInternalErrorsConfig,
            extraUserInfo
          )

  mapActionT runTraceT $ do
    -- Add the request ID to the tracing metadata so that we
    -- can correlate requests and traces
    lift $ Tracing.attachMetadata [("request_id", unRequestId requestId)]

    (serviceTime, (result, userInfo, authHeaders, includeInternal, queryJSON, extraUserInfo)) <- withElapsedTime $ case apiHandler of
      -- in the case of a simple get/post we don't have to send the webhook anything
      AHGet handler -> do
        (userInfo, authHeaders, handlerState, includeInternal, extraUserInfo) <- getInfo Nothing
        res <- lift $ runHandler handlerState handler
        pure (res, userInfo, authHeaders, includeInternal, Nothing, extraUserInfo)
      AHPost handler -> do
        (userInfo, authHeaders, handlerState, includeInternal, extraUserInfo) <- getInfo Nothing
        (queryJSON, parsedReq) <-
          runExcept (parseBody reqBody) `onLeft` \e -> do
            logErrorAndResp (Just userInfo) requestId req (reqBody, Nothing) includeInternal origHeaders extraUserInfo (qErrModifier e)
        res <- lift $ runHandler handlerState $ handler parsedReq
        pure (res, userInfo, authHeaders, includeInternal, Just queryJSON, extraUserInfo)
      -- in this case we parse the request _first_ and then send the request to the webhook for auth
      AHGraphQLRequest handler -> do
        (queryJSON, parsedReq) <-
          runExcept (parseBody reqBody) `onLeft` \e -> do
            -- if the request fails to parse, call the webhook without a request body
            -- TODO should we signal this to the webhook somehow?
            (userInfo, _, _, _, extraUserInfo) <- getInfo Nothing
            logErrorAndResp (Just userInfo) requestId req (reqBody, Nothing) False origHeaders extraUserInfo (qErrModifier e)
        (userInfo, authHeaders, handlerState, includeInternal, extraUserInfo) <- getInfo (Just parsedReq)

        res <- lift $ runHandler handlerState $ handler parsedReq
        pure (res, userInfo, authHeaders, includeInternal, Just queryJSON, extraUserInfo)

    -- apply the error modifier
    let modResult = fmapL qErrModifier result

    -- log and return result
    case modResult of
      Left err ->
        logErrorAndResp (Just userInfo) requestId req (reqBody, queryJSON) includeInternal headers extraUserInfo err
      Right (httpLogGraphQLInfo, res) -> do
        let httpLogMetadata = buildHttpLogMetadata @m httpLogGraphQLInfo extraUserInfo
        logSuccessAndResp (Just userInfo) requestId req (reqBody, queryJSON) res (Just (ioWaitTime, serviceTime)) origHeaders authHeaders httpLogMetadata
  where
    logErrorAndResp ::
      forall m3 a3 ctx.
      (MonadIO m3, HttpLog m3) =>
      Maybe UserInfo ->
      RequestId ->
      Wai.Request ->
      (BL.ByteString, Maybe Value) ->
      Bool ->
      [HTTP.Header] ->
      ExtraUserInfo ->
      QErr ->
      Spock.ActionCtxT ctx m3 a3
    logErrorAndResp userInfo reqId waiReq req includeInternal headers extraUserInfo qErr = do
      let httpLogMetadata = buildHttpLogMetadata @m3 emptyHttpLogGraphQLInfo extraUserInfo
      lift $ logHttpError (_lsLogger scLoggers) scLoggingSettings userInfo reqId waiReq req qErr headers httpLogMetadata
      Spock.setStatus $ qeStatus qErr
      Spock.json $ qErrEncoder includeInternal qErr

    logSuccessAndResp userInfo reqId waiReq req result qTime reqHeaders authHdrs httpLoggingMetadata = do
      let (respBytes, respHeaders) = case result of
            JSONResp (HttpResponse encJson h) -> (encJToLBS encJson, pure jsonHeader <> h)
            RawResp (HttpResponse rawBytes h) -> (rawBytes, h)
          (compressedResp, encodingType) = compressResponse (Wai.requestHeaders waiReq) respBytes
          encodingHeader = maybeToList (contentEncodingHeader <$> encodingType)
          reqIdHeader = (requestIdHeader, txtToBs $ unRequestId reqId)
          allRespHeaders = pure reqIdHeader <> encodingHeader <> respHeaders <> authHdrs
      lift $ logHttpSuccess (_lsLogger scLoggers) scLoggingSettings userInfo reqId waiReq req respBytes compressedResp qTime encodingType reqHeaders httpLoggingMetadata
      mapM_ setHeader allRespHeaders
      Spock.lazyBytes compressedResp

v1QueryHandler ::
  ( MonadIO m,
    MonadBaseControl IO m,
    MonadMetadataApiAuthorization m,
    Tracing.MonadTrace m,
    MonadReader HandlerCtx m,
    MonadMetadataStorage m,
    MonadResolveSource m,
    EB.MonadQueryTags m,
    MonadEventLogCleanup m
  ) =>
  RQLQuery ->
  m (HttpResponse EncJSON)
v1QueryHandler query = do
  (liftEitherM . authorizeV1QueryApi query) =<< ask
  scRef <- asks (scCacheRef . hcServerCtx)
  logger <- asks (_lsLogger . scLoggers . hcServerCtx)
  res <- bool (fst <$> (action logger)) (withSchemaCacheUpdate scRef logger Nothing (action logger)) $ queryModifiesSchemaCache query
  return $ HttpResponse res []
  where
    action logger = do
      userInfo <- asks hcUser
      scRef <- asks (scCacheRef . hcServerCtx)
      metadataDefaults <- asks (scMetadataDefaults . hcServerCtx)
      schemaCache <- liftIO $ fst <$> readSchemaCacheRef scRef
      httpMgr <- asks (scManager . hcServerCtx)
      sqlGenCtx <- asks (scSQLGenCtx . hcServerCtx)
      instanceId <- asks (scInstanceId . hcServerCtx)
      env <- asks (scEnvironment . hcServerCtx)
      remoteSchemaPermsCtx <- asks (scRemoteSchemaPermsCtx . hcServerCtx)
      functionPermsCtx <- asks (scFunctionPermsCtx . hcServerCtx)
      maintenanceMode <- asks (scEnableMaintenanceMode . hcServerCtx)
      experimentalFeatures <- asks (scExperimentalFeatures . hcServerCtx)
      eventingMode <- asks (scEventingMode . hcServerCtx)
      readOnlyMode <- asks (scEnableReadOnlyMode . hcServerCtx)
      defaultNamingCase <- asks (scDefaultNamingConvention . hcServerCtx)
      checkFeatureFlag <- asks (scCheckFeatureFlag . hcServerCtx)
      let serverConfigCtx =
            ServerConfigCtx
              functionPermsCtx
              remoteSchemaPermsCtx
              sqlGenCtx
              maintenanceMode
              experimentalFeatures
              eventingMode
              readOnlyMode
              defaultNamingCase
              metadataDefaults
              checkFeatureFlag
      runQuery
        env
        logger
        instanceId
        userInfo
        schemaCache
        httpMgr
        serverConfigCtx
        query

v1MetadataHandler ::
  ( MonadIO m,
    MonadBaseControl IO m,
    MonadReader HandlerCtx m,
    Tracing.MonadTrace m,
    MonadMetadataStorage m,
    MonadResolveSource m,
    MonadMetadataApiAuthorization m,
    MonadEventLogCleanup m
  ) =>
  RQLMetadata ->
  m (HttpResponse EncJSON)
v1MetadataHandler query = Tracing.trace "Metadata" $ do
  (liftEitherM . authorizeV1MetadataApi query) =<< ask
  userInfo <- asks hcUser
  scRef <- asks (scCacheRef . hcServerCtx)
  schemaCache <- liftIO $ fst <$> readSchemaCacheRef scRef
  httpMgr <- asks (scManager . hcServerCtx)
  _sccSQLGenCtx <- asks (scSQLGenCtx . hcServerCtx)
  env <- asks (scEnvironment . hcServerCtx)
  instanceId <- asks (scInstanceId . hcServerCtx)
  logger <- asks (_lsLogger . scLoggers . hcServerCtx)
  _sccRemoteSchemaPermsCtx <- asks (scRemoteSchemaPermsCtx . hcServerCtx)
  _sccFunctionPermsCtx <- asks (scFunctionPermsCtx . hcServerCtx)
  _sccExperimentalFeatures <- asks (scExperimentalFeatures . hcServerCtx)
  _sccMaintenanceMode <- asks (scEnableMaintenanceMode . hcServerCtx)
  _sccEventingMode <- asks (scEventingMode . hcServerCtx)
  _sccReadOnlyMode <- asks (scEnableReadOnlyMode . hcServerCtx)
  _sccDefaultNamingConvention <- asks (scDefaultNamingConvention . hcServerCtx)
  _sccMetadataDefaults <- asks (scMetadataDefaults . hcServerCtx)
  _sccCheckFeatureFlag <- asks (scCheckFeatureFlag . hcServerCtx)
  let serverConfigCtx = ServerConfigCtx {..}
  r <-
    withSchemaCacheUpdate
      scRef
      logger
      Nothing
      $ runMetadataQuery
        env
        logger
        instanceId
        userInfo
        httpMgr
        serverConfigCtx
        schemaCache
        query
  pure $ HttpResponse r []

v2QueryHandler ::
  ( MonadIO m,
    MonadBaseControl IO m,
    MonadMetadataApiAuthorization m,
    Tracing.MonadTrace m,
    MonadReader HandlerCtx m,
    MonadMetadataStorage m,
    MonadResolveSource m,
    EB.MonadQueryTags m
  ) =>
  V2Q.RQLQuery ->
  m (HttpResponse EncJSON)
v2QueryHandler query = Tracing.trace "v2 Query" $ do
  (liftEitherM . authorizeV2QueryApi query) =<< ask
  scRef <- asks (scCacheRef . hcServerCtx)
  logger <- asks (_lsLogger . scLoggers . hcServerCtx)
  res <-
    bool (fst <$> dbAction) (withSchemaCacheUpdate scRef logger Nothing dbAction) $
      V2Q.queryModifiesSchema query
  return $ HttpResponse res []
  where
    -- Hit postgres
    dbAction = do
      userInfo <- asks hcUser
      scRef <- asks (scCacheRef . hcServerCtx)
      schemaCache <- liftIO $ fst <$> readSchemaCacheRef scRef
      httpMgr <- asks (scManager . hcServerCtx)
      sqlGenCtx <- asks (scSQLGenCtx . hcServerCtx)
      instanceId <- asks (scInstanceId . hcServerCtx)
      env <- asks (scEnvironment . hcServerCtx)
      remoteSchemaPermsCtx <- asks (scRemoteSchemaPermsCtx . hcServerCtx)
      experimentalFeatures <- asks (scExperimentalFeatures . hcServerCtx)
      functionPermsCtx <- asks (scFunctionPermsCtx . hcServerCtx)
      maintenanceMode <- asks (scEnableMaintenanceMode . hcServerCtx)
      eventingMode <- asks (scEventingMode . hcServerCtx)
      readOnlyMode <- asks (scEnableReadOnlyMode . hcServerCtx)
      defaultNamingCase <- asks (scDefaultNamingConvention . hcServerCtx)
      defaultMetadata <- asks (scMetadataDefaults . hcServerCtx)
      checkFeatureFlag <- asks (scCheckFeatureFlag . hcServerCtx)
      let serverConfigCtx =
            ServerConfigCtx
              functionPermsCtx
              remoteSchemaPermsCtx
              sqlGenCtx
              maintenanceMode
              experimentalFeatures
              eventingMode
              readOnlyMode
              defaultNamingCase
              defaultMetadata
              checkFeatureFlag

      V2Q.runQuery env instanceId userInfo schemaCache httpMgr serverConfigCtx query

v1Alpha1GQHandler ::
  ( MonadIO m,
    MonadBaseControl IO m,
    E.MonadGQLExecutionCheck m,
    MonadQueryLog m,
    Tracing.MonadTrace m,
    GH.MonadExecuteQuery m,
    MonadError QErr m,
    MonadReader HandlerCtx m,
    MonadMetadataStorage (MetadataStorageT m),
    EB.MonadQueryTags m,
    HasResourceLimits m
  ) =>
  E.GraphQLQueryType ->
  GH.GQLBatchedReqs (GH.GQLReq GH.GQLQueryText) ->
  m (HttpLogGraphQLInfo, HttpResponse EncJSON)
v1Alpha1GQHandler queryType query = do
  userInfo <- asks hcUser
  reqHeaders <- asks hcReqHeaders
  ipAddress <- asks hcSourceIpAddress
  requestId <- asks hcRequestId
  logger <- asks (_lsLogger . scLoggers . hcServerCtx)
  responseErrorsConfig <- asks (scResponseInternalErrorsConfig . hcServerCtx)
  env <- asks (scEnvironment . hcServerCtx)

  execCtx <- mkExecutionContext

  flip runReaderT execCtx $
    GH.runGQBatched env logger requestId responseErrorsConfig userInfo ipAddress reqHeaders queryType query

mkExecutionContext ::
  ( MonadIO m,
    MonadReader HandlerCtx m
  ) =>
  m E.ExecutionCtx
mkExecutionContext = do
  manager <- asks (scManager . hcServerCtx)
  scRef <- asks (scCacheRef . hcServerCtx)
  (sc, scVer) <- liftIO $ readSchemaCacheRef scRef
  sqlGenCtx <- asks (scSQLGenCtx . hcServerCtx)
  enableAL <- asks (scEnableAllowlist . hcServerCtx)
  logger <- asks (_lsLogger . scLoggers . hcServerCtx)
  readOnlyMode <- asks (scEnableReadOnlyMode . hcServerCtx)
  prometheusMetrics <- asks (scPrometheusMetrics . hcServerCtx)
  pure $ E.ExecutionCtx logger sqlGenCtx (lastBuiltSchemaCache sc) scVer manager enableAL readOnlyMode prometheusMetrics

v1GQHandler ::
  ( MonadIO m,
    MonadBaseControl IO m,
    E.MonadGQLExecutionCheck m,
    MonadQueryLog m,
    Tracing.MonadTrace m,
    GH.MonadExecuteQuery m,
    MonadError QErr m,
    MonadReader HandlerCtx m,
    MonadMetadataStorage (MetadataStorageT m),
    EB.MonadQueryTags m,
    HasResourceLimits m
  ) =>
  GH.GQLBatchedReqs (GH.GQLReq GH.GQLQueryText) ->
  m (HttpLogGraphQLInfo, HttpResponse EncJSON)
v1GQHandler = v1Alpha1GQHandler E.QueryHasura

v1GQRelayHandler ::
  ( MonadIO m,
    MonadBaseControl IO m,
    E.MonadGQLExecutionCheck m,
    MonadQueryLog m,
    Tracing.MonadTrace m,
    GH.MonadExecuteQuery m,
    MonadError QErr m,
    MonadReader HandlerCtx m,
    MonadMetadataStorage (MetadataStorageT m),
    EB.MonadQueryTags m,
    HasResourceLimits m
  ) =>
  GH.GQLBatchedReqs (GH.GQLReq GH.GQLQueryText) ->
  m (HttpLogGraphQLInfo, HttpResponse EncJSON)
v1GQRelayHandler = v1Alpha1GQHandler E.QueryRelay

gqlExplainHandler ::
  forall m.
  ( MonadIO m,
    MonadBaseControl IO m,
    MonadError QErr m,
    MonadReader HandlerCtx m,
    MonadMetadataStorage (MetadataStorageT m),
    EB.MonadQueryTags m
  ) =>
  GE.GQLExplain ->
  m (HttpResponse EncJSON)
gqlExplainHandler query = do
  onlyAdmin
  scRef <- asks (scCacheRef . hcServerCtx)
  sc <- liftIO $ getSchemaCache scRef
  res <- GE.explainGQLQuery sc query
  return $ HttpResponse res []

v1Alpha1PGDumpHandler :: (MonadIO m, MonadError QErr m, MonadReader HandlerCtx m) => PGD.PGDumpReqBody -> m APIResp
v1Alpha1PGDumpHandler b = do
  onlyAdmin
  scRef <- asks (scCacheRef . hcServerCtx)
  sc <- liftIO $ getSchemaCache scRef
  let sources = scSources sc
      sourceName = PGD.prbSource b
      sourceConfig = unsafeSourceConfiguration @('Postgres 'Vanilla) =<< M.lookup sourceName sources
  ci <-
    fmap _pscConnInfo sourceConfig
      `onNothing` throw400 NotFound ("source " <> sourceName <<> " not found")
  output <- PGD.execPGDump b ci
  return $ RawResp $ HttpResponse output [sqlHeader]

consoleAssetsHandler ::
  (MonadIO m, HttpLog m) =>
  L.Logger L.Hasura ->
  LoggingSettings ->
  Text ->
  FilePath ->
  Spock.ActionT m ()
consoleAssetsHandler logger loggingSettings dir path = do
  req <- Spock.request
  let reqHeaders = Wai.requestHeaders req
  -- '..' in paths need not be handed as it is resolved in the url by
  -- spock's routing. we get the expanded path.
  eFileContents <-
    liftIO $
      try $
        BL.readFile $
          joinPath [T.unpack dir, path]
  either (onError reqHeaders) onSuccess eFileContents
  where
    onSuccess c = do
      mapM_ setHeader headers
      Spock.lazyBytes c
    onError :: (MonadIO m, HttpLog m) => [HTTP.Header] -> IOException -> Spock.ActionT m ()
    onError hdrs = raiseGenericApiError logger loggingSettings hdrs . err404 NotFound . tshow
    fn = T.pack $ takeFileName path
    -- set gzip header if the filename ends with .gz
    (fileName, encHeader) = case T.stripSuffix ".gz" fn of
      Just v -> (v, [gzipHeader])
      Nothing -> (fn, [])
    mimeType = defaultMimeLookup fileName
    headers = ("Content-Type", mimeType) : encHeader

class (Monad m) => ConsoleRenderer m where
  renderConsole :: Text -> AuthMode -> Bool -> Maybe Text -> Maybe Text -> m (Either String Text)

instance ConsoleRenderer m => ConsoleRenderer (Tracing.TraceT m) where
  renderConsole a b c d e = lift $ renderConsole a b c d e

-- Type class to get any extra [Pair] for the version API
class (Monad m) => MonadVersionAPIWithExtraData m where
  getExtraDataForVersionAPI :: m [J.Pair]

renderHtmlTemplate :: M.Template -> Value -> Either String Text
renderHtmlTemplate template jVal =
  bool (Left errMsg) (Right res) $ null errs
  where
    errMsg = "template rendering failed: " ++ show errs
    (errs, res) = M.checkedSubstitute template jVal

-- | Default implementation of the 'MonadConfigApiHandler'
configApiGetHandler ::
  forall m.
  (MonadIO m, MonadBaseControl IO m, UserAuthentication (Tracing.TraceT m), HttpLog m, Tracing.HasReporter m, HasResourceLimits m) =>
  ServerCtx ->
  Maybe Text ->
  Spock.SpockCtxT () m ()
configApiGetHandler serverCtx@ServerCtx {..} consoleAssetsDir =
  Spock.get "v1alpha1/config" $
    mkSpockAction serverCtx encodeQErr id $
      mkGetHandler $ do
        onlyAdmin
        let res =
              runGetConfig
                scFunctionPermsCtx
                scRemoteSchemaPermsCtx
                scAuthMode
                scEnableAllowlist
                (ES._ssLiveQueryOptions $ scSubscriptionState)
                (ES._ssStreamQueryOptions $ scSubscriptionState)
                consoleAssetsDir
                scExperimentalFeatures
                scEnabledAPIs
                scDefaultNamingConvention
        return (emptyHttpLogGraphQLInfo, JSONResp $ HttpResponse (encJFromJValue res) [])

data HasuraApp = HasuraApp
  { _hapApplication :: !Wai.Application,
    _hapSchemaRef :: !SchemaCacheRef,
    _hapAsyncActionSubscriptionState :: !ES.AsyncActionSubscriptionState,
    _hapShutdownWsServer :: !(IO ())
  }

-- TODO: Put Env into ServerCtx?

mkWaiApp ::
  forall m.
  ( MonadIO m,
    MonadFix m,
    MonadStateless IO m,
    LA.Forall (LA.Pure m),
    ConsoleRenderer m,
    MonadVersionAPIWithExtraData m,
    HttpLog m,
    UserAuthentication (Tracing.TraceT m),
    MonadMetadataApiAuthorization m,
    E.MonadGQLExecutionCheck m,
    MonadConfigApiHandler m,
    MonadQueryLog m,
    WS.MonadWSLog m,
    Tracing.HasReporter m,
    GH.MonadExecuteQuery m,
    HasResourceLimits m,
    MonadMetadataStorage (MetadataStorageT m),
    MonadResolveSource m,
    EB.MonadQueryTags m,
    MonadEventLogCleanup m
  ) =>
  (ServerCtx -> Spock.SpockT m ()) ->
  -- | Set of environment variables for reference in UIs
  Env.Environment ->
  CorsConfig ->
  -- | is console enabled - TODO: better type
  Bool ->
  -- | filepath to the console static assets directory - TODO: better type
  Maybe Text ->
  -- | DSN for console sentry integration
  Maybe Text ->
  -- | is telemetry enabled
  Bool ->
  SchemaCacheRef ->
  WS.ConnectionOptions ->
  KeepAliveDelay ->
  S.HashSet (L.EngineLogType L.Hasura) ->
  ServerCtx ->
  WSConnectionInitTimeout ->
  EKG.Store EKG.EmptyMetrics ->
  m HasuraApp
mkWaiApp
  setupHook
  env
  corsCfg
  enableConsole
  consoleAssetsDir
  consoleSentryDsn
  enableTelemetry
  schemaCacheRef
  connectionOptions
  keepAliveDelay
  enabledLogTypes
  serverCtx@ServerCtx {..}
  wsConnInitTimeout
  ekgStore = do
    let getSchemaCache' = first lastBuiltSchemaCache <$> readSchemaCacheRef schemaCacheRef

    let corsPolicy = mkDefaultCorsPolicy corsCfg

    wsServerEnv <-
      WS.createWSServerEnv
        (_lsLogger scLoggers)
        scSubscriptionState
        getSchemaCache'
        scManager
        corsPolicy
        scSQLGenCtx
        scEnableReadOnlyMode
        scEnableAllowlist
        keepAliveDelay
        scServerMetrics
        scPrometheusMetrics
        scTraceSamplingPolicy

    spockApp <- liftWithStateless $ \lowerIO ->
      Spock.spockAsApp $
        Spock.spockT lowerIO $
          httpApp setupHook corsCfg serverCtx enableConsole consoleAssetsDir consoleSentryDsn enableTelemetry ekgStore

    let wsServerApp = WS.createWSServerApp env enabledLogTypes scAuthMode wsServerEnv wsConnInitTimeout -- TODO: Lyndon: Can we pass environment through wsServerEnv?
        stopWSServer = WS.stopWSServerApp wsServerEnv

    waiApp <- liftWithStateless $ \lowerIO ->
      pure $ WSC.websocketsOr connectionOptions (\ip conn -> lowerIO $ wsServerApp ip conn) spockApp

    return $ HasuraApp waiApp schemaCacheRef (ES._ssAsyncActions scSubscriptionState) stopWSServer

httpApp ::
  forall m.
  ( MonadIO m,
    MonadFix m,
    MonadBaseControl IO m,
    ConsoleRenderer m,
    MonadVersionAPIWithExtraData m,
    HttpLog m,
    UserAuthentication (Tracing.TraceT m),
    MonadMetadataApiAuthorization m,
    E.MonadGQLExecutionCheck m,
    MonadConfigApiHandler m,
    MonadQueryLog m,
    Tracing.HasReporter m,
    GH.MonadExecuteQuery m,
    MonadMetadataStorage (MetadataStorageT m),
    HasResourceLimits m,
    MonadResolveSource m,
    EB.MonadQueryTags m,
    MonadEventLogCleanup m
  ) =>
  (ServerCtx -> Spock.SpockT m ()) ->
  CorsConfig ->
  ServerCtx ->
  Bool ->
  Maybe Text ->
  Maybe Text ->
  Bool ->
  EKG.Store EKG.EmptyMetrics ->
  Spock.SpockT m ()
httpApp setupHook corsCfg serverCtx enableConsole consoleAssetsDir consoleSentryDsn enableTelemetry ekgStore = do
  -- Additional spock action to run
  setupHook serverCtx

  -- cors middleware
  unless (isCorsDisabled corsCfg) $
    Spock.middleware $
      corsMiddleware (mkDefaultCorsPolicy corsCfg)

  -- API Console and Root Dir
  when (enableConsole && enableMetadata) serveApiConsole

  -- Local console assets for server and CLI consoles
  serveApiConsoleAssets

  -- Health check endpoint with logs
  let healthzAction = do
        let errorMsg = "ERROR"
        runMetadataStorageT checkMetadataStorageHealth >>= \case
          Left err -> do
            -- error running the health check
            logError err
            Spock.setStatus HTTP.status500 >> Spock.text errorMsg
          Right _ -> do
            -- healthy
            sc <- liftIO $ getSchemaCache $ scCacheRef serverCtx
            let responseText =
                  if null (scInconsistentObjs sc)
                    then "OK"
                    else "WARN: inconsistent objects in schema"
            logSuccess responseText
            Spock.setStatus HTTP.status200 >> Spock.text (LT.toStrict responseText)

  Spock.get "healthz" healthzAction

  -- This is an alternative to `healthz` (See issue #6958)
  Spock.get "hasura/healthz" healthzAction

  Spock.get "v1/version" $ do
    logSuccess $ "version: " <> convertText currentVersion
    extraData <- lift $ getExtraDataForVersionAPI
    setHeader jsonHeader
    Spock.lazyBytes $ encode $ object $ ["version" .= currentVersion] <> extraData

  let customEndpointHandler ::
        forall n.
        ( MonadIO n,
          MonadBaseControl IO n,
          E.MonadGQLExecutionCheck n,
          MonadQueryLog n,
          GH.MonadExecuteQuery n,
          MonadMetadataStorage (MetadataStorageT n),
          EB.MonadQueryTags n,
          HasResourceLimits n
        ) =>
        RestRequest Spock.SpockMethod ->
        Handler (Tracing.TraceT n) (HttpLogGraphQLInfo, APIResp)
      customEndpointHandler restReq = do
        scRef <- asks (scCacheRef . hcServerCtx)
        endpoints <- liftIO $ scEndpoints <$> getSchemaCache scRef
        execCtx <- mkExecutionContext
        env <- asks (scEnvironment . hcServerCtx)
        requestId <- asks hcRequestId
        userInfo <- asks hcUser
        reqHeaders <- asks hcReqHeaders
        ipAddress <- asks hcSourceIpAddress

        req <-
          restReq & traverse \case
            Spock.MethodStandard (Spock.HttpMethod m) -> case m of
              Spock.GET -> pure EP.GET
              Spock.POST -> pure EP.POST
              Spock.PUT -> pure EP.PUT
              Spock.DELETE -> pure EP.DELETE
              Spock.PATCH -> pure EP.PATCH
              other -> throw400 BadRequest $ "Method " <> tshow other <> " not supported."
            _ -> throw400 BadRequest $ "Nonstandard method not allowed for REST endpoints"
        fmap JSONResp <$> runCustomEndpoint env execCtx requestId userInfo reqHeaders ipAddress req endpoints

  -- See Issue #291 for discussion around restified feature
  Spock.hookRouteAll ("api" <//> "rest" <//> Spock.wildcard) $ \wildcard -> do
    queryParams <- Spock.params
    body <- Spock.body
    method <- Spock.reqMethod

    -- This is where we decode the json encoded body args. They
    -- are treated as if they came from query arguments, but allow
    -- us to pass non-scalar values.
    let bodyParams = case J.decodeStrict body of
          Just (J.Object o) -> map (first K.toText) $ KM.toList o
          _ -> []
        allParams = fmap Left <$> queryParams <|> fmap Right <$> bodyParams

    spockAction encodeQErr id $ do
      -- TODO: Are we actually able to use mkGetHandler in this situation? POST handler seems to do some work that we might want to avoid.
      mkGetHandler $ customEndpointHandler (RestRequest wildcard method allParams)

  when enableMetadata $ do
    Spock.post "v1/graphql/explain" gqlExplainAction

    Spock.post "v1alpha1/graphql/explain" gqlExplainAction

    Spock.post "v1/query" $
      spockAction encodeQErr id $ do
        mkPostHandler $ fmap (emptyHttpLogGraphQLInfo,) <$> mkAPIRespHandler v1QueryHandler

    Spock.post "v1/metadata" $
      spockAction encodeQErr id $
        mkPostHandler $
          fmap (emptyHttpLogGraphQLInfo,) <$> mkAPIRespHandler v1MetadataHandler

    Spock.post "v2/query" $
      spockAction encodeQErr id $
        mkPostHandler $
          fmap (emptyHttpLogGraphQLInfo,) <$> mkAPIRespHandler v2QueryHandler

  when enablePGDump $
    Spock.post "v1alpha1/pg_dump" $
      spockAction encodeQErr id $
        mkPostHandler $
          fmap (emptyHttpLogGraphQLInfo,) <$> v1Alpha1PGDumpHandler

  when enableConfig $ runConfigApiHandler serverCtx consoleAssetsDir

  when enableGraphQL $ do
    Spock.post "v1alpha1/graphql" $
      spockAction GH.encodeGQErr id $
        mkGQLRequestHandler $
          mkGQLAPIRespHandler $
            v1Alpha1GQHandler E.QueryHasura

    Spock.post "v1/graphql" $
      spockAction GH.encodeGQErr allMod200 $
        mkGQLRequestHandler $
          mkGQLAPIRespHandler $
            v1GQHandler

    Spock.post "v1beta1/relay" $
      spockAction GH.encodeGQErr allMod200 $
        mkGQLRequestHandler $
          mkGQLAPIRespHandler $
            v1GQRelayHandler

  -- This exposes some simple RTS stats when we run with `+RTS -T`. We want
  -- this to be available even when developer APIs are not compiled in, to
  -- support benchmarking.
  -- See: https://hackage.haskell.org/package/base/docs/GHC-Stats.html
  exposeRtsStats <- liftIO RTS.getRTSStatsEnabled
  when exposeRtsStats $ do
    Spock.get "dev/rts_stats" $ do
      -- This ensures the live_bytes and other counters from GCDetails are fresh:
      liftIO performMajorGC
      stats <- liftIO RTS.getRTSStats
      Spock.json stats

  when (isDeveloperAPIEnabled serverCtx) $ do
    Spock.get "dev/ekg" $
      spockAction encodeQErr id $
        mkGetHandler $ do
          onlyAdmin
          respJ <- liftIO $ EKG.sampleAll ekgStore
          return (emptyHttpLogGraphQLInfo, JSONResp $ HttpResponse (encJFromJValue $ EKG.sampleToJson respJ) [])
    -- This deprecated endpoint used to show the query plan cache pre-PDV.
    -- Eventually this endpoint can be removed.
    Spock.get "dev/plan_cache" $
      spockAction encodeQErr id $
        mkGetHandler $ do
          onlyAdmin
          return (emptyHttpLogGraphQLInfo, JSONResp $ HttpResponse (encJFromJValue J.Null) [])
    Spock.get "dev/subscriptions" $
      spockAction encodeQErr id $
        mkGetHandler $ do
          onlyAdmin
          respJ <- liftIO $ ES.dumpSubscriptionsState False $ scSubscriptionState serverCtx
          return (emptyHttpLogGraphQLInfo, JSONResp $ HttpResponse (encJFromJValue respJ) [])
    Spock.get "dev/subscriptions/extended" $
      spockAction encodeQErr id $
        mkGetHandler $ do
          onlyAdmin
          respJ <- liftIO $ ES.dumpSubscriptionsState True $ scSubscriptionState serverCtx
          return (emptyHttpLogGraphQLInfo, JSONResp $ HttpResponse (encJFromJValue respJ) [])
    Spock.get "dev/dataconnector/schema" $
      spockAction encodeQErr id $
        mkGetHandler $ do
          onlyAdmin
          return (emptyHttpLogGraphQLInfo, JSONResp $ HttpResponse (encJFromJValue openApiSchema) [])
  Spock.get "api/swagger/json" $
    spockAction encodeQErr id $
      mkGetHandler $ do
        onlyAdmin
        sc <- liftIO $ getSchemaCache $ scCacheRef serverCtx
        json <- buildOpenAPI sc
        return (emptyHttpLogGraphQLInfo, JSONResp $ HttpResponse (encJFromJValue json) [])

  forM_ [Spock.GET, Spock.POST] $ \m -> Spock.hookAny m $ \_ -> do
    req <- Spock.request
    let headers = Wai.requestHeaders req
        qErr = err404 NotFound "resource does not exist"
    raiseGenericApiError logger (scLoggingSettings serverCtx) headers qErr
  where
    logger = (_lsLogger . scLoggers) serverCtx

    logSuccess msg = do
      req <- Spock.request
      reqBody <- liftIO $ Wai.strictRequestBody req
      let headers = Wai.requestHeaders req
          blMsg = TL.encodeUtf8 msg
      (reqId, _newHeaders) <- getRequestId headers
      lift $
        logHttpSuccess logger (scLoggingSettings serverCtx) Nothing reqId req (reqBody, Nothing) blMsg blMsg Nothing Nothing headers (emptyHttpLogMetadata @m)

    logError err = do
      req <- Spock.request
      reqBody <- liftIO $ Wai.strictRequestBody req
      let headers = Wai.requestHeaders req
      (reqId, _newHeaders) <- getRequestId headers
      lift $
        logHttpError logger (scLoggingSettings serverCtx) Nothing reqId req (reqBody, Nothing) err headers (emptyHttpLogMetadata @m)

    spockAction ::
      forall a n.
      (FromJSON a, MonadIO n, MonadBaseControl IO n, UserAuthentication (Tracing.TraceT n), HttpLog n, Tracing.HasReporter n, HasResourceLimits n) =>
      (Bool -> QErr -> Value) ->
      (QErr -> QErr) ->
      APIHandler (Tracing.TraceT n) a ->
      Spock.ActionT n ()
    spockAction qErrEncoder qErrModifier apiHandler = mkSpockAction serverCtx qErrEncoder qErrModifier apiHandler

    -- all graphql errors should be of type 200
    allMod200 qe = qe {qeStatus = HTTP.status200}
    gqlExplainAction = do
      spockAction encodeQErr id $
        mkPostHandler $
          fmap (emptyHttpLogGraphQLInfo,) <$> mkAPIRespHandler gqlExplainHandler
    enableGraphQL = isGraphQLEnabled serverCtx
    enableMetadata = isMetadataEnabled serverCtx
    enablePGDump = isPGDumpEnabled serverCtx
    enableConfig = isConfigEnabled serverCtx

    serveApiConsole = do
      -- redirect / to /console
      Spock.get Spock.root $ Spock.redirect "console"

      -- serve console html
      Spock.get ("console" <//> Spock.wildcard) $ \path -> do
        req <- Spock.request
        let headers = Wai.requestHeaders req
            authMode = scAuthMode serverCtx
        consoleHtml <- lift $ renderConsole path authMode enableTelemetry consoleAssetsDir consoleSentryDsn
        either (raiseGenericApiError logger (scLoggingSettings serverCtx) headers . internalError . T.pack) Spock.html consoleHtml

    serveApiConsoleAssets = do
      -- serve static files if consoleAssetsDir is set
      for_ consoleAssetsDir $ \dir ->
        Spock.get ("console/assets" <//> Spock.wildcard) $ \path -> do
          consoleAssetsHandler logger (scLoggingSettings serverCtx) dir (T.unpack path)

raiseGenericApiError ::
  forall m.
  (MonadIO m, HttpLog m) =>
  L.Logger L.Hasura ->
  LoggingSettings ->
  [HTTP.Header] ->
  QErr ->
  Spock.ActionT m ()
raiseGenericApiError logger loggingSetting headers qErr = do
  req <- Spock.request
  reqBody <- liftIO $ Wai.strictRequestBody req
  (reqId, _newHeaders) <- getRequestId $ Wai.requestHeaders req
  lift $ logHttpError logger loggingSetting Nothing reqId req (reqBody, Nothing) qErr headers (emptyHttpLogMetadata @m)
  setHeader jsonHeader
  Spock.setStatus $ qeStatus qErr
  Spock.lazyBytes $ encode qErr
