{-# LANGUAGE FlexibleContexts      #-}
{-# LANGUAGE LambdaCase            #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE MultiWayIf            #-}
{-# LANGUAGE OverloadedStrings     #-}
{-# LANGUAGE ScopedTypeVariables   #-}
{-# LANGUAGE TemplateHaskell       #-}

module Hasura.HTTP
  ( HTTP(..)
  , HTTPSessionMgr(..)
  , mkHTTP
  , mkHTTPPost
  , mkHTTPMaybe
  , HTTPErr(..)
  , runHTTP
  , runInsecureHTTP
  , default2xxParser
  , noBody2xxParser
  , defaultRetryPolicy
  , defaultRetryFn
  , defaultParser
  , defaultParserMaybe
  , isNetworkError
  , isNetworkErrorHC
  , HLogger
  , mkHLogger
  ) where

import qualified Control.Retry            as R
import qualified Data.Aeson               as J
import qualified Data.Aeson.Casing        as J
import qualified Data.Aeson.TH            as J
import qualified Data.ByteString.Lazy     as B
import qualified Data.CaseInsensitive     as CI
import qualified Data.Text                as T
import qualified Data.Text.Encoding       as TE
import qualified Data.Text.Encoding.Error as TE
import qualified Data.Text.Lazy           as TL
import qualified Data.Text.Lazy.Encoding  as TLE
import qualified Network.HTTP.Client      as H
import qualified Network.HTTP.Types       as N
import qualified Network.Wreq             as W
import qualified Network.Wreq.Session     as WS
import qualified System.Log.FastLogger    as FL

import           Control.Exception        (try)
import           Control.Lens
import           Control.Monad.Except     (MonadError, throwError)
import           Control.Monad.IO.Class   (MonadIO, liftIO)
import           Control.Monad.Reader     (MonadReader, ask)
import           Data.Has
import           Hasura.Logging
-- import           Data.Monoid
import           Hasura.Prelude

-- import           Context                  (HTTPSessionMgr (..))
-- import           Log

type HLogger = (LogLevel, EngineLogType, J.Value) -> IO ()

data HTTPSessionMgr
  = HTTPSessionMgr
  { _hsmSession         :: !WS.Session
  , _hsmInsecureSession :: !WS.Session
  }
data HTTPErr
  = HClient !H.HttpException
  | HParse !N.Status !String
  | HStatus !N.Status !J.Value
  deriving (Show)

instance J.ToJSON HTTPErr where
  toJSON err = toObj $ case err of
    (HClient e) -> ("client", J.toJSON $ show e)
    (HParse st e) ->
      ( "parse"
      , J.toJSON [ J.toJSON $ N.statusCode st
        , J.toJSON $ show e
        ]
      )
    (HStatus st resp) ->
      ("status", J.toJSON [ J.toJSON $ N.statusCode st, resp])
    where
      toObj :: (T.Text, J.Value) -> J.Value
      toObj (k, v) = J.object [ "type" J..= k
                              , "detail" J..= v]

instance J.FromJSON HTTPErr where
  parseJSON (J.Object o) = do
    typ <- o J..: "type"
    det <- o J..: "detail"
    case typ of
      J.String "parse" -> do
        sc  <- J.parseJSON $ head det
        str <- J.parseJSON $ head $ tail det
        return $ HParse (N.mkStatus sc "") str

      J.String "status" -> do
        sc  <- J.parseJSON $ head det
        str <- J.parseJSON $ head $ tail det
        return $ HStatus (N.mkStatus sc "") str

      J.String "client" ->
        return $ HStatus N.status500 "some H.HttpException occured!"

      _ -> fail "Invalid HTTPErr type"

  parseJSON _ = fail "Invalid HTTPErr type"
    -- case typ of
    --   J.String "parse" -> do
    --     parsedDet <- J.parseJSON det
    --     case parsedDet of
    --       Just [a, b] -> HParse (N.mkStatus a "") b
    --       _           -> fail "Could not decode as HParse"
    -- this beautiful thing doesn't work because client and (parse, status) have different structures
    -- let parsedDet = J.decode det
    -- case (typ, parsedDet) of
    --   ("parse" , Just [a, b]) -> HParse <$> J.parseJSON a <*> J.parseJSON b
    --   ("status", Just [a, b]) -> HStatus <$> J.parseJSON a <*> J.parseJSON b
    --   ("client", Just str)    -> HClient <$> J.parseJSON str
    --   _                       -> fail "could not decode as HTTPErr"


-- encapsulates a http operation
instance ToEngineLog  HTTPErr where
  toEngineLog err = (LevelError, "event-trigger", J.toJSON err )

data HTTP a
  = HTTP
  { _hMethod      :: !String
  , _hUrl         :: !String
  , _hPayload     :: !(Maybe J.Value)
  , _hFormData    :: !(Maybe [W.FormParam])
  -- options modifier
  , _hOptions     :: W.Options -> W.Options
  -- the response parser
  , _hParser      :: W.Response B.ByteString -> Either HTTPErr a
  -- should the operation be retried
  , _hRetryFn     :: Either HTTPErr a -> Bool
  -- the retry policy
  , _hRetryPolicy :: R.RetryPolicyM IO
  }

-- TODO. Why this istance?
-- instance Show (HTTP a) where
--   show (HTTP m u p _ _ _ _) = show m ++ " " ++ show u ++ " : " ++ show p

isNetworkError :: HTTPErr -> Bool
isNetworkError = \case
  HClient he -> isNetworkErrorHC he
  _          -> False

isNetworkErrorHC :: H.HttpException -> Bool
isNetworkErrorHC = \case
  H.HttpExceptionRequest _ (H.ConnectionFailure _) -> True
  H.HttpExceptionRequest _ H.ConnectionTimeout -> True
  H.HttpExceptionRequest _ H.ResponseTimeout -> True
  _ -> False

-- retries on the typical network errors
defaultRetryFn :: Either HTTPErr a -> Bool
defaultRetryFn = \case
  Left e  -> isNetworkError e
  Right _ -> False

-- full jitter backoff
defaultRetryPolicy :: (MonadIO m) => R.RetryPolicyM m
defaultRetryPolicy =
  R.capDelay (120 * 1000 * 1000) (R.fullJitterBackoff (2 * 1000 * 1000))
  <> R.limitRetries 15

-- a helper function
respJson :: (J.FromJSON a) => W.Response B.ByteString -> Either HTTPErr a
respJson resp =
  either (Left . HParse respCode) return $
  J.eitherDecode respBody
  where
    respCode = resp ^. W.responseStatus
    respBody = resp ^. W.responseBody

defaultParser :: (J.FromJSON a) => W.Response B.ByteString -> Either HTTPErr a
defaultParser resp = if
  | respCode == N.status200 -> respJson resp
  | otherwise -> do
      val <- respJson resp
      throwError $ HStatus respCode val
  where
    respCode = resp ^. W.responseStatus

-- like default parser but turns 404 into maybe
defaultParserMaybe
  :: (J.FromJSON a) => W.Response B.ByteString -> Either HTTPErr (Maybe a)
defaultParserMaybe resp = if
  | respCode == N.status200 -> Just <$> respJson resp
  | respCode == N.status404 -> return Nothing
  | otherwise -> do
      val <- respJson resp
      throwError $ HStatus respCode val
  where
    respCode = resp ^. W.responseStatus

-- default parser which allows all 2xx responses
default2xxParser :: (J.FromJSON a) => W.Response B.ByteString -> Either HTTPErr a
default2xxParser resp = if
  | respCode >= N.status200 && respCode < N.status300 -> respJson resp
  | otherwise -> do
      val <- respJson resp
      throwError $ HStatus respCode val
  where
    respCode = resp ^. W.responseStatus

noBody2xxParser :: W.Response B.ByteString -> Either HTTPErr ()
noBody2xxParser resp = if
  | respCode >= N.status200 && respCode < N.status300 -> return ()
  | otherwise -> do
      val <- respJson resp
      throwError $ HStatus respCode val
  where
    respCode = resp ^. W.responseStatus

mkHTTP :: (J.FromJSON a) => String -> String -> HTTP a
mkHTTP method url =
  HTTP method url Nothing Nothing id defaultParser
  defaultRetryFn defaultRetryPolicy

mkHTTPPost :: (J.FromJSON a) => String -> Maybe J.Value -> HTTP a
mkHTTPPost url payload =
  HTTP "POST" url payload Nothing id defaultParser
  defaultRetryFn defaultRetryPolicy

mkHTTPMaybe :: (J.FromJSON a) => String -> String -> HTTP (Maybe a)
mkHTTPMaybe method url =
  HTTP method url Nothing Nothing id defaultParserMaybe
  defaultRetryFn defaultRetryPolicy

-- internal logging related types
data HTTPReq
  = HTTPReq
  { _hrqMethod  :: !String
  , _hrqUrl     :: !String
  , _hrqPayload :: !(Maybe J.Value)
  , _hrqTry     :: !Int
  , _hrqDelay   :: !(Maybe Int)
  } deriving (Show, Eq)

$(J.deriveJSON (J.aesonDrop 4 J.camelCase){J.omitNothingFields=True} ''HTTPReq)

instance ToEngineLog  HTTPReq where
  toEngineLog req = (LevelInfo, "event-trigger", J.toJSON req )

instance ToEngineLog HTTPResp where
  toEngineLog resp = (LevelInfo, "event-trigger", J.toJSON resp )

data HTTPResp
   = HTTPResp
   { _hrsStatus  :: !Int
   , _hrsHeaders :: ![T.Text]
   , _hrsBody    :: !TL.Text
   } deriving (Show, Eq)

$(J.deriveJSON (J.aesonDrop 4 J.camelCase){J.omitNothingFields=True} ''HTTPResp)

mkHTTPResp :: W.Response B.ByteString -> HTTPResp
mkHTTPResp resp =
  HTTPResp
  (resp ^. W.responseStatus.W.statusCode)
  (map decodeHeader $ resp ^. W.responseHeaders)
  (decodeLBS $ resp ^. W.responseBody)
  where
    decodeBS = TE.decodeUtf8With TE.lenientDecode
    decodeLBS = TLE.decodeUtf8With TE.lenientDecode
    decodeHeader (hdrName, hdrVal)
      = decodeBS (CI.original hdrName) <> " : " <> decodeBS hdrVal


runHTTP
  :: ( MonadReader r m
     , MonadError HTTPErr m
     , MonadIO m
     , Has HTTPSessionMgr r
     , Has HLogger r
     )
  => W.Options -> HTTP a -> m a
runHTTP opts http = do
  -- try the http request
  res <- R.retrying retryPol' retryFn' $ httpWithLogging opts True http

  -- process the result
  either throwError return res

  where
    retryPol'  = R.RetryPolicyM $ liftIO . R.getRetryPolicyM (_hRetryPolicy http)
    retryFn' _ = return . _hRetryFn http

runInsecureHTTP
  :: ( MonadReader r m
     , MonadError HTTPErr m
     , MonadIO m
     , Has HTTPSessionMgr r
     , Has HLogger r
     )
  => W.Options -> HTTP a -> m a
runInsecureHTTP opts http = do
  -- try the http request
  res <- R.retrying retryPol' retryFn' $ httpWithLogging opts False http

  -- process the result
  either throwError return res
  where
    retryPol'  = R.RetryPolicyM $ liftIO . R.getRetryPolicyM (_hRetryPolicy http)
    retryFn' _ = return . _hRetryFn http


httpWithLogging
  :: (MonadReader r m, MonadIO m, Has HTTPSessionMgr r, Has HLogger r)
  => W.Options -> Bool -> HTTP a -> R.RetryStatus -> m (Either HTTPErr a)
-- the actual http action
httpWithLogging opts isSecure (HTTP method url mPayload mFormParams optsMod bodyParser _ _) retryStatus = do
  (logF:: HLogger) <- asks getter
  -- log the request
  liftIO $ logF $ toEngineLog $ HTTPReq method url mPayload
    (R.rsIterNumber retryStatus) (R.rsPreviousDelay retryStatus)

  (HTTPSessionMgr secSess insecSess) <- getter <$> ask

  -- try the request
  res <- case isSecure of
    -- make requests with the secure http session (meaning verifies ssl certs ca)
    True  -> finallyRunHTTPPlz secSess
    -- m

  -- log the response
  case res of
    Left e     -> liftIO $ logF $ toEngineLog $ HClient e
    Right resp ->
      --liftIO $ print "=======================>"
      liftIO $ logF $ toEngineLog $ mkHTTPResp resp
      --liftIO $ print "<======================="

  -- return the processed response
  return $ either (Left . HClient) bodyParser res

  where
    -- set wreq options to ignore status code exceptions
    ignoreStatusCodeExceptions _ _ = return ()
    finalOpts = optsMod opts
                & W.checkResponse .~ Just ignoreStatusCodeExceptions

    -- the actual function which makes the relevant Wreq calls
    finallyRunHTTPPlz sessMgr =
      liftIO $ try $
      case (mPayload, mFormParams) of
        (Just payload, _)   -> WS.customPayloadMethodWith method finalOpts sessMgr url payload
        (Nothing, Just fps) -> WS.customPayloadMethodWith method finalOpts sessMgr url fps
        (Nothing, Nothing)  -> WS.customMethodWith method finalOpts sessMgr url

mkHLogger :: LoggerCtx -> HLogger
mkHLogger (LoggerCtx loggerSet serverLogLevel timeGetter) (logLevel, logTy, logDet) = do
  localTime <- timeGetter
  when (logLevel >= serverLogLevel) $
    FL.pushLogStrLn loggerSet $ FL.toLogStr $
    J.encode $ EngineLog localTime logLevel logTy logDet
