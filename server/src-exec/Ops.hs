{-# LANGUAGE FlexibleContexts  #-}
{-# LANGUAGE MultiWayIf        #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE QuasiQuotes       #-}
{-# LANGUAGE TemplateHaskell   #-}

module Ops
  ( initCatalogSafe
  , cleanCatalog
  , migrateCatalog
  , execQuery
  ) where

import           Data.Time.Clock              (UTCTime)
import           TH

import           Hasura.Prelude
import           Hasura.RQL.DDL.Schema.Table
import           Hasura.RQL.DDL.Utils         (clearHdbViews)
import           Hasura.RQL.Types
import           Hasura.Server.Query
import           Hasura.SQL.Types

import qualified Data.Aeson                   as A
import qualified Data.ByteString.Lazy         as BL
import qualified Data.Text                    as T

import qualified Database.PG.Query            as Q
import qualified Database.PG.Query.Connection as Q
import qualified Network.HTTP.Client          as HTTP

curCatalogVer :: T.Text
curCatalogVer = "6"

runRQLQuery :: HTTP.Manager -> RQLQuery -> Q.TxE QErr ()
runRQLQuery httpMgr =
    void . join . liftEither . buildTxAny adminUserInfo emptySchemaCache httpMgr

initCatalogSafe :: UTCTime -> HTTP.Manager -> Q.TxE QErr String
initCatalogSafe initTime httpMgr =  do
  hdbCatalogExists <- Q.catchE defaultTxErrorHandler $
                      doesSchemaExist $ SchemaName "hdb_catalog"
  bool (initCatalogStrict True initTime httpMgr) onCatalogExists hdbCatalogExists
  where
    onCatalogExists = do
      versionExists <- Q.catchE defaultTxErrorHandler $
                       doesVersionTblExist
                       (SchemaName "hdb_catalog") (TableName "hdb_version")
      bool (initCatalogStrict False initTime httpMgr) (return initialisedMsg) versionExists

    initialisedMsg = "initialise: the state is already initialised"

    doesVersionTblExist sn tblN =
      (runIdentity . Q.getRow) <$> Q.withQ [Q.sql|
           SELECT EXISTS (
               SELECT 1
                 FROM pg_tables
                WHERE schemaname = $1 AND tablename = $2)
               |] (sn, tblN) False

    doesSchemaExist sn =
      (runIdentity . Q.getRow) <$> Q.withQ [Q.sql|
           SELECT EXISTS (
               SELECT 1
                 FROM information_schema.schemata
                WHERE schema_name = $1
           )
                    |] (Identity sn) False

initCatalogStrict :: Bool -> UTCTime -> HTTP.Manager -> Q.TxE QErr String
initCatalogStrict createSchema initTime httpMgr =  do
  Q.catchE defaultTxErrorHandler $ do

    when createSchema $ do
      Q.unitQ "CREATE SCHEMA hdb_catalog" () False
      -- This is where the generated views and triggers are stored
      Q.unitQ "CREATE SCHEMA hdb_views" () False

    flExtExists <- isExtAvailable "first_last_agg"
    if flExtExists
      then Q.unitQ "CREATE EXTENSION first_last_agg SCHEMA hdb_catalog" () False
      else Q.multiQ $(Q.sqlFromFile "src-rsr/first_last.sql") >>= \(Q.Discard _) -> return ()

  pgcryptoExtExists <- Q.catchE defaultTxErrorHandler $ isExtAvailable "pgcrypto"
  if pgcryptoExtExists
    -- only if we created the schema, create the extension
    then when createSchema $
         Q.unitQE needsPgCryptoExt
           "CREATE EXTENSION IF NOT EXISTS pgcrypto SCHEMA public" () False
    else throw500 "FATAL: Could not find extension pgcrytpo. This extension is required."

  Q.catchE defaultTxErrorHandler $ do
    Q.Discard () <- Q.multiQ $(Q.sqlFromFile "src-rsr/initialise.sql")
    return ()

  -- Build the metadata query
  runRQLQuery httpMgr metadataQuery

  setAllAsSystemDefined >> addVersion initTime
  return "initialise: successfully initialised"

  where
    needsPgCryptoExt :: Q.PGTxErr -> QErr
    needsPgCryptoExt e@(Q.PGTxErr _ _ _ err) =
      case err of
        Q.PGIUnexpected _ -> (err500 PostgresError pgcryptoReqdMsg) { qeInternal = Just $ A.toJSON e }
        Q.PGIStatement pgErr ->
          case Q.edStatusCode pgErr of
            Just "42501" -> err500 PostgresError pgcryptoPermsMsg
            _ -> (err500 PostgresError pgcryptoReqdMsg) { qeInternal = Just $ A.toJSON e }

    addVersion modTime = Q.catchE defaultTxErrorHandler $
      Q.unitQ [Q.sql|
                INSERT INTO "hdb_catalog"."hdb_version" VALUES ($1, $2)
                |] (curCatalogVer, modTime) False

    isExtAvailable :: T.Text -> Q.Tx Bool
    isExtAvailable sn =
      (runIdentity . Q.getRow) <$> Q.withQ [Q.sql|
           SELECT EXISTS (
               SELECT 1
                 FROM pg_catalog.pg_available_extensions
                WHERE name = $1
           )
                    |] (Identity sn) False


setAllAsSystemDefined :: Q.TxE QErr ()
setAllAsSystemDefined = Q.catchE defaultTxErrorHandler $ do
  Q.unitQ "UPDATE hdb_catalog.hdb_table SET is_system_defined = 'true'" () False
  Q.unitQ "UPDATE hdb_catalog.hdb_relationship SET is_system_defined = 'true'" () False
  Q.unitQ "UPDATE hdb_catalog.hdb_permission SET is_system_defined = 'true'" () False
  Q.unitQ "UPDATE hdb_catalog.hdb_query_template SET is_system_defined = 'true'" () False

setAsSystemDefined :: Q.TxE QErr ()
setAsSystemDefined = Q.catchE defaultTxErrorHandler $
  Q.multiQ [Q.sql|
            UPDATE hdb_catalog.hdb_table
            SET is_system_defined = 'true'
            WHERE table_schema = 'hdb_catalog';

            UPDATE hdb_catalog.hdb_permission
            SET is_system_defined = 'true'
            WHERE table_schema = 'hdb_catalog';

            UPDATE hdb_catalog.hdb_relationship
            SET is_system_defined = 'true'
            WHERE table_schema = 'hdb_catalog';
            |]

cleanCatalog :: Q.TxE QErr ()
cleanCatalog = Q.catchE defaultTxErrorHandler $ do
  -- This is where the generated views and triggers are stored
  Q.unitQ "DROP SCHEMA IF EXISTS hdb_views CASCADE" () False
  Q.unitQ "DROP SCHEMA hdb_catalog CASCADE" () False

getCatalogVersion :: Q.TxE QErr T.Text
getCatalogVersion = do
  res <- Q.withQE defaultTxErrorHandler [Q.sql|
                SELECT version FROM hdb_catalog.hdb_version
                    |] () False
  return $ runIdentity $ Q.getRow res

from08To1 :: Q.TxE QErr ()
from08To1 = Q.catchE defaultTxErrorHandler $ do
  Q.unitQ "ALTER TABLE hdb_catalog.hdb_relationship ADD COLUMN comment TEXT NULL" () False
  Q.unitQ "ALTER TABLE hdb_catalog.hdb_permission ADD COLUMN comment TEXT NULL" () False
  Q.unitQ "ALTER TABLE hdb_catalog.hdb_query_template ADD COLUMN comment TEXT NULL" () False
  Q.unitQ [Q.sql|
          UPDATE hdb_catalog.hdb_query_template
             SET template_defn =
                 json_build_object('type', 'select', 'args', template_defn->'select');
                |] () False

from1To2 :: HTTP.Manager -> Q.TxE QErr ()
from1To2 httpMgr = do
  -- migrate database
  Q.Discard () <- Q.multiQE defaultTxErrorHandler
    $(Q.sqlFromFile "src-rsr/migrate_from_1.sql")
  -- migrate metadata
  runRQLQuery httpMgr migrateMetadataFrom1
  -- set as system defined
  setAsSystemDefined

from2To3 :: Q.TxE QErr ()
from2To3 = Q.catchE defaultTxErrorHandler $ do
  Q.unitQ "ALTER TABLE hdb_catalog.event_triggers ADD COLUMN headers JSON" () False
  Q.unitQ "ALTER TABLE hdb_catalog.event_log ADD COLUMN next_retry_at TIMESTAMP" () False
  Q.unitQ "CREATE INDEX ON hdb_catalog.event_log (trigger_id)" () False
  Q.unitQ "CREATE INDEX ON hdb_catalog.event_invocation_logs (event_id)" () False

from5To6 :: HTTP.Manager -> Q.TxE QErr ()
from5To6 httpMgr = do
  -- migrate database
  Q.Discard () <- Q.multiQE defaultTxErrorHandler
    $(Q.sqlFromFile "src-rsr/migrate_from_5_to_6.sql")
  -- migrate metadata
  runRQLQuery httpMgr migrateMetadataFrom5
  -- set as system defined
  setAsSystemDefined

-- custom resolver
from4To5 :: HTTP.Manager -> Q.TxE QErr ()
from4To5 httpMgr = do
  Q.Discard () <- Q.multiQE defaultTxErrorHandler
    $(Q.sqlFromFile "src-rsr/migrate_from_4_to_5.sql")
  -- migrate metadata
  tx <- liftEither $ buildTxAny adminUserInfo
                     emptySchemaCache httpMgr migrateMetadataFrom4
  void tx
  -- set as system defined
  setAsSystemDefined


from3To4 :: Q.TxE QErr ()
from3To4 = Q.catchE defaultTxErrorHandler $ do
  Q.unitQ "ALTER TABLE hdb_catalog.event_triggers ADD COLUMN configuration JSON" () False
  eventTriggers <- map uncurryEventTrigger <$> Q.listQ [Q.sql|
           SELECT e.name, e.definition::json, e.webhook, e.num_retries, e.retry_interval, e.headers::json
           FROM hdb_catalog.event_triggers e
           |] () False
  forM_ eventTriggers updateEventTrigger3To4
  Q.unitQ "ALTER TABLE hdb_catalog.event_triggers\
          \  DROP COLUMN definition\
          \, DROP COLUMN query\
          \, DROP COLUMN webhook\
          \, DROP COLUMN num_retries\
          \, DROP COLUMN retry_interval\
          \, DROP COLUMN headers" () False
  where
    uncurryEventTrigger (trn, Q.AltJ tDef, w, nr, rint, Q.AltJ headers) =
      EventTriggerConf trn tDef (Just w) Nothing (RetryConf nr rint) headers
    updateEventTrigger3To4 etc@(EventTriggerConf name _ _ _ _ _) = Q.unitQ [Q.sql|
                                         UPDATE hdb_catalog.event_triggers
                                         SET
                                         configuration = $1
                                         WHERE name = $2
                                         |] (Q.AltJ $ A.toJSON etc, name) True

migrateCatalog :: HTTP.Manager -> UTCTime -> Q.TxE QErr String
migrateCatalog httpMgr migrationTime = do
  preVer <- getCatalogVersion
  if | preVer == curCatalogVer ->
         return "migrate: already at the latest version"
     | preVer == "0.8" -> from08ToCurrent
     | preVer == "1"   -> from1ToCurrent
     | preVer == "2"   -> from2ToCurrent
     | preVer == "3"   -> from3ToCurrent
     | preVer == "4"   -> from4ToCurrent
     | preVer == "5"   -> from5ToCurrent
     | otherwise -> throw400 NotSupported $
                    "migrate: unsupported version : " <> preVer
  where
    from5ToCurrent = do
      from5To6 httpMgr
      postMigrate

    from4ToCurrent = do
      from4To5 httpMgr
      from5ToCurrent

    from3ToCurrent = do
      from3To4
      from4ToCurrent

    from2ToCurrent = do
      from2To3
      from3ToCurrent

    from1ToCurrent = do
      from1To2 httpMgr
      from2ToCurrent

    from08ToCurrent = do
      from08To1
      from1ToCurrent

    postMigrate = do
       -- update the catalog version
       updateVersion
       -- clean hdb_views
       Q.catchE defaultTxErrorHandler clearHdbViews
       -- try building the schema cache
       void $ buildSchemaCache httpMgr
       return $ "migrate: successfully migrated to " ++ show curCatalogVer

    updateVersion =
      Q.unitQE defaultTxErrorHandler [Q.sql|
                UPDATE "hdb_catalog"."hdb_version"
                   SET "version" = $1,
                       "upgraded_on" = $2
                    |] (curCatalogVer, migrationTime) False

execQuery :: HTTP.Manager -> BL.ByteString -> Q.TxE QErr BL.ByteString
execQuery httpMgr queryBs = do
  query <- case A.decode queryBs of
    Just jVal -> decodeValue jVal
    Nothing   -> throw400 InvalidJSON "invalid json"
  schemaCache <- buildSchemaCache httpMgr
  tx <- liftEither $ buildTxAny adminUserInfo schemaCache
                                httpMgr query
  fst <$> tx


-- error messages
pgcryptoReqdMsg :: T.Text
pgcryptoReqdMsg =
  "pgcrypto extension is required, but could not install; encountered postgres error"

pgcryptoPermsMsg :: T.Text
pgcryptoPermsMsg =
  "pgcrypto extension is required, but current user doesn't have permission to create it. "
  <> "Please grant superuser permission or setup initial schema via "
  <> "https://docs.hasura.io/1.0/graphql/manual/deployment/postgres-permissions.html"
