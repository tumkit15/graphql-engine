{-# LANGUAGE FlexibleContexts    #-}
{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE QuasiQuotes         #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Hasura.RQL.DDL.Schema.Table.Internal
  ( renameTableInCatalog
  , renameColumnInCatalog
  )
where

import           Hasura.Prelude
import           Hasura.RQL.DDL.Permission
import           Hasura.RQL.DDL.Permission.Internal
import           Hasura.RQL.DDL.Relationship
import           Hasura.RQL.Types
import           Hasura.SQL.Types

import qualified Data.HashMap.Strict                as M
import qualified Data.Map.Strict                    as Map
import qualified Database.PG.Query                  as Q

import           Control.Arrow                      (first, (***))
import           Data.Aeson

renameTableInCatalog
  :: (MonadTx m)
  => SchemaCache -> QualifiedTable -> QualifiedTable -> m ()
renameTableInCatalog sc newQT oldQT = do
  let allRels = getAllRelations $ scTables sc
  -- Update depended relations on this table with new name
  forM_ allRels $ \rel -> updateRelDefs newQT oldQT rel
  -- Update table name in hdb_catalog
  liftTx $ Q.catchE defaultTxErrorHandler updateTableInCatalog

  where
    QualifiedObject nsn ntn = newQT
    QualifiedObject osn otn = oldQT
    updateTableInCatalog =
      Q.unitQ [Q.sql|
           UPDATE "hdb_catalog"."hdb_table"
              SET table_schema = $1, table_name = $2
            WHERE table_schema = $3 AND table_name = $4
                |] (nsn, ntn, osn, otn) False

renameColumnInCatalog
  :: (MonadTx m)
  => SchemaCache -> PGCol -> PGCol
  -> QualifiedTable -> TableInfo -> m ()
renameColumnInCatalog sc oCol nCol qt ti = do
  -- Check if any relation exists with new column name
  assertFldNotExists
  -- Update cols in permissions
  updatePermCols oCol nCol qt
  -- Update right cols in relations
  let allRels = getAllRelations $ scTables sc
  forM_ allRels $ \r -> updateRelRemoteCols oCol nCol qt r
  -- Update left cols in table's relations
  let rels = getRels $ tiFieldInfoMap ti
  updateRelNativeCols oCol nCol rels qt
  where
    assertFldNotExists =
      case M.lookup (fromPGCol oCol) $ tiFieldInfoMap ti of
        Just (FIRelationship _) ->
          throw400 AlreadyExists $ "cannot rename column " <> oCol
          <<> " to " <> nCol <<> " in table " <> qt <<>
          " as a relationship with the name already exists"
        _ -> return ()

-- helper functions for rename table
getRelDef :: QualifiedTable -> RelName -> Q.TxE QErr Value
getRelDef (QualifiedObject sn tn) rn =
  Q.getAltJ . runIdentity . Q.getRow <$> Q.withQE defaultTxErrorHandler
    [Q.sql|
     SELECT rel_def::json FROM hdb_catalog.hdb_relationship
      WHERE table_schema = $1 AND table_name = $2
        AND rel_name = $3
    |] (sn, tn, rn) True

updateRelDefs
  :: (MonadTx m)
  => QualifiedTable
  -> QualifiedTable
  -> (QualifiedTable, [RelInfo])
  -> m ()
updateRelDefs newQT oldQT (qt, rels) =
  forM_ rels $ \rel -> when (oldQT == riRTable rel) $
    case riType rel of
      ObjRel -> updateObjRelDef newQT qt $ riName rel
      ArrRel -> updateArrRelDef newQT qt $ riName rel

updateObjRelDef :: (MonadTx m) => QualifiedTable
                -> QualifiedTable -> RelName -> m ()
updateObjRelDef newQT qt rn = do
  oldDefV <- liftTx $ getRelDef qt rn
  oldDef :: ObjRelUsing <- decodeValue oldDefV
  case oldDef of
    RUFKeyOn _ -> return ()
    RUManual (ObjRelManualConfig (RelManualConfig _ rmCols)) -> do
      let newDef = mkObjRelUsing rmCols
      liftTx $ updateRel qt rn $ toJSON (newDef :: ObjRelUsing)
  where
    mkObjRelUsing colMap = RUManual $ ObjRelManualConfig $
      RelManualConfig newQT colMap

updateArrRelDef :: (MonadTx m) => QualifiedTable
                -> QualifiedTable -> RelName -> m ()
updateArrRelDef newQT qt rn = do
  oldDefV <- liftTx $ getRelDef qt rn
  oldDef  <- decodeValue oldDefV
  liftTx $ updateRel qt rn $ toJSON $ mkNewArrRelUsing oldDef
  where
    mkNewArrRelUsing arrRelUsing = case arrRelUsing of
      RUFKeyOn (ArrRelUsingFKeyOn _ c) ->
        RUFKeyOn $ ArrRelUsingFKeyOn newQT c
      RUManual (ArrRelManualConfig (RelManualConfig _ rmCols)) ->
        RUManual $ ArrRelManualConfig $ RelManualConfig newQT rmCols

-- helper functions for rename column

-- | update columns in premissions
updatePermCols :: (MonadTx m)
               => PGCol -> PGCol -> QualifiedTable -> m ()
updatePermCols oCol nCol qt@(QualifiedObject sn tn) = do
  perms <- liftTx fetchPerms
  forM_ perms $ \(rn, ty, Q.AltJ (pDef :: Value)) ->
    case ty of
      PTInsert -> do
        perm <- decodeValue pDef
        updateInsPermCols oCol nCol qt rn perm
      PTSelect -> do
        perm <- decodeValue pDef
        updateSelPermCols oCol nCol qt rn perm
      PTUpdate -> do
        perm <- decodeValue pDef
        updateUpdPermCols oCol nCol qt rn perm
      PTDelete -> do
        perm <- decodeValue pDef
        updateDelPermCols oCol nCol qt rn perm
  where
    fetchPerms = Q.listQE defaultTxErrorHandler [Q.sql|
                  SELECT role_name, perm_type, perm_def::json
                    FROM hdb_catalog.hdb_permission
                   WHERE table_schema = $1
                     AND table_name = $2
                 |] (sn, tn) True

updateInsPermCols
  :: (MonadTx m)
  => PGCol -> PGCol
  -> QualifiedTable -> RoleName -> InsPerm -> m ()
updateInsPermCols oCol nCol qt rn (InsPerm chk preset cols) =
  when updNeeded $
    liftTx $ updatePermDefInCatalog PTInsert qt rn $
      InsPerm updBoolExp updPreset updCols
  where
    updNeeded = updNeededFromPreset || updNeededFromBoolExp || updNeededFromCols
    (updPreset, updNeededFromPreset) = fromM $ updatePreset oCol nCol <$> preset
    (updCols, updNeededFromCols) = fromM $ updateCols oCol nCol <$> cols
    (updBoolExp, updNeededFromBoolExp) = updateBoolExp oCol nCol chk

    fromM = maybe (Nothing, False) (first Just)

updateSelPermCols
  :: (MonadTx m)
  => PGCol -> PGCol
  -> QualifiedTable -> RoleName -> SelPerm -> m ()
updateSelPermCols oCol nCol qt rn (SelPerm cols fltr limit aggAllwd) =
  when ( updNeededFromCols || updNeededFromBoolExp) $
    liftTx $ updatePermDefInCatalog PTSelect qt rn $
      SelPerm updCols updBoolExp limit aggAllwd
  where
    (updCols, updNeededFromCols) = updateCols oCol nCol cols
    (updBoolExp, updNeededFromBoolExp) = updateBoolExp oCol nCol fltr

updateUpdPermCols
  :: (MonadTx m)
  => PGCol -> PGCol
  -> QualifiedTable -> RoleName -> UpdPerm -> m ()
updateUpdPermCols oCol nCol qt rn (UpdPerm cols fltr) =
  when ( updNeededFromCols || updNeededFromBoolExp) $
    liftTx $ updatePermDefInCatalog PTUpdate qt rn $
      UpdPerm updCols updBoolExp
  where
    (updCols, updNeededFromCols) = updateCols oCol nCol cols
    (updBoolExp, updNeededFromBoolExp) = updateBoolExp oCol nCol fltr

updateDelPermCols
  :: (MonadTx m)
  => PGCol -> PGCol
  -> QualifiedTable -> RoleName -> DelPerm -> m ()
updateDelPermCols oCol nCol qt rn (DelPerm fltr) = do
  let updatedFltrExp = updateBoolExp oCol nCol fltr
  when (snd updatedFltrExp) $
    liftTx $ updatePermDefInCatalog PTDelete qt rn $
      DelPerm $ fst updatedFltrExp

updatePreset :: PGCol -> PGCol -> Object -> (Object, Bool)
updatePreset oCol nCol obj =
  (M.fromList updItems, or isUpds)
  where
    (updItems, isUpds) = unzip $ map procObjItem $ M.toList obj
    procObjItem (k, v) =
      let pgCol = PGCol k
          isUpdated = pgCol == oCol
          updCol = bool pgCol nCol isUpdated
      in ((getPGColTxt updCol, v), isUpdated)

updateCols :: PGCol -> PGCol -> PermColSpec -> (PermColSpec, Bool)
updateCols oCol nCol cols = case cols of
  PCStar -> (cols, False)
  PCCols c -> ( PCCols $ flip map c $ \col -> if col == oCol then nCol else col
              , oCol `elem` c
              )

updateBoolExp :: PGCol -> PGCol -> BoolExp -> (BoolExp, Bool)
updateBoolExp oCol nCol (BoolExp boolExp) =
  first BoolExp $ updateBoolExp' oCol nCol boolExp

updateBoolExp' :: PGCol -> PGCol -> GBoolExp ColExp -> (GBoolExp ColExp, Bool)
updateBoolExp' oCol nCol boolExp = case boolExp of
  BoolAnd exps -> (BoolAnd *** or) (updateExps exps)

  BoolOr exps -> (BoolOr *** or) (updateExps exps)

  be@(BoolFld (ColExp c v)) -> if oCol == PGCol (getFieldNameTxt c)
                               then ( BoolFld $ ColExp (fromPGCol nCol) v
                                    , True
                                    )
                               else (be, False)
  BoolNot be -> let updatedExp = updateBoolExp' oCol nCol be
                in ( BoolNot $ fst updatedExp
                   , snd updatedExp
                   )
  where
    updateExps exps = unzip $ flip map exps $ updateBoolExp' oCol nCol

-- | update remote columns of relationships
updateRelRemoteCols
  :: (MonadTx m)
  => PGCol -> PGCol
  -> QualifiedTable
  -> (QualifiedTable, [RelInfo])
  -> m ()
updateRelRemoteCols oCol nCol table (qt, rels) =
  forM_ rels $ \rel -> when (table == riRTable rel) $
    case riType rel of
      ObjRel -> updateObjRelRemoteCol oCol nCol qt $ riName rel
      ArrRel -> updateArrRelRemoteCol oCol nCol qt $ riName rel

updateObjRelRemoteCol :: (MonadTx m) => PGCol -> PGCol
                 -> QualifiedTable -> RelName -> m ()
updateObjRelRemoteCol oCol nCol qt rn = do
  oldDefV <- liftTx $ getRelDef qt rn
  oldDef :: ObjRelUsing <- decodeValue oldDefV
  case oldDef of
    RUFKeyOn _ -> return ()
    RUManual (ObjRelManualConfig manConf) -> do
      let (updatedManualConf, updNeeded) =
            updateColForManualConfig oCol nCol Map.map snd manConf
      when updNeeded $
        liftTx $ updateRel qt rn $ toJSON
          (RUManual $ ObjRelManualConfig updatedManualConf :: ObjRelUsing)

updateArrRelRemoteCol :: (MonadTx m) => PGCol -> PGCol
                -> QualifiedTable -> RelName -> m ()
updateArrRelRemoteCol oCol nCol qt rn = do
  oldDefV <- liftTx $ getRelDef qt rn
  oldDef <- decodeValue oldDefV
  updateArrRel oldDef
  where
    updateArrRel arrRelUsing = case arrRelUsing of
      RUFKeyOn (ArrRelUsingFKeyOn t c) -> when (c == oCol) $
          liftTx $ updateRel qt rn $ toJSON
            (RUFKeyOn (ArrRelUsingFKeyOn t nCol) :: ArrRelUsing)
      RUManual (ArrRelManualConfig manConf) -> do
        let (updatedManualConf, updNeeded) =
              updateColForManualConfig oCol nCol Map.map snd manConf
        when updNeeded $
          liftTx $ updateRel qt rn $ toJSON
            (RUManual $ ArrRelManualConfig updatedManualConf :: ArrRelUsing)

-- | update native columns in relationships
updateRelNativeCols
  :: (MonadTx m) => PGCol -> PGCol -> [RelInfo] -> QualifiedTable -> m ()
updateRelNativeCols oCol nCol rels qt =
  forM_ rels $ \rel -> case riType rel of
    ObjRel -> updateObjRelNativeCol oCol nCol qt $ riName rel
    ArrRel -> updateArrRelNativeCol oCol nCol qt $ riName rel

updateObjRelNativeCol :: (MonadTx m) => PGCol -> PGCol
                 -> QualifiedTable -> RelName -> m ()
updateObjRelNativeCol oCol nCol qt rn = do
  oldDefV <- liftTx $ getRelDef qt rn
  oldDef :: ObjRelUsing <- decodeValue oldDefV
  case oldDef of
    RUFKeyOn c -> when (c == oCol) $
      liftTx $ updateRel qt rn $ toJSON
        (RUFKeyOn nCol :: ObjRelUsing)
    RUManual (ObjRelManualConfig manConf) -> do
      let (updatedManualConf, updNeeded) =
            updateColForManualConfig oCol nCol Map.mapKeys fst manConf
      when updNeeded $
        liftTx $ updateRel qt rn $ toJSON
          (RUManual $ ObjRelManualConfig updatedManualConf :: ObjRelUsing)

updateArrRelNativeCol :: (MonadTx m) => PGCol -> PGCol
                -> QualifiedTable -> RelName -> m ()
updateArrRelNativeCol oCol nCol qt rn = do
  oldDefV <- liftTx $ getRelDef qt rn
  oldDef :: ArrRelUsing <- decodeValue oldDefV
  updateArrRel oldDef
  where
    updateArrRel arrRelUsing = case arrRelUsing of
      RUFKeyOn _ -> return ()
      RUManual (ArrRelManualConfig manConf) -> do
        let (updatedManualConf, updNeeded) =
              updateColForManualConfig oCol nCol Map.mapKeys fst manConf
        when updNeeded $
          liftTx $ updateRel qt rn $ toJSON
            (RUManual $ ArrRelManualConfig updatedManualConf :: ArrRelUsing)

-- | update columns in manual_configuration
type ColMapModifier = (PGCol -> PGCol) -> Map.Map PGCol PGCol -> Map.Map PGCol PGCol
type ColAccessor = (PGCol, PGCol) -> PGCol

updateColForManualConfig
  :: PGCol -> PGCol
  -> ColMapModifier -> ColAccessor
  -> RelManualConfig -> (RelManualConfig, Bool)
updateColForManualConfig oCol nCol modFn accFn (RelManualConfig tn rmCols) =
  let updatedColMap =
        flip modFn rmCols $ \col -> bool col nCol $ col == oCol
  in
  ( RelManualConfig tn updatedColMap
  , oCol `elem` map accFn (Map.toList rmCols)
  )
