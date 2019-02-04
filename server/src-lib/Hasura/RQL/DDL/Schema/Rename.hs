module Hasura.RQL.DDL.Schema.Rename
  ( renameTableInCatalog
  , renameColInCatalog
  , renameRelInCatalog
  )
where

import           Hasura.Prelude
import           Hasura.RQL.DDL.Permission
import           Hasura.RQL.DDL.Permission.Internal
import           Hasura.RQL.DDL.Relationship.Types
import           Hasura.RQL.Types
import           Hasura.SQL.Types

import qualified Data.HashMap.Strict                as M
import qualified Data.Map.Strict                    as Map
import qualified Database.PG.Query                  as Q

import           Control.Arrow                      (first)
import           Data.Aeson

data RenameItem a
  = RenameItem
  { rfOld :: !a
  , rfNew :: !a
  } deriving (Show, Eq)

data RenameField
  = RFCol !(RenameItem PGCol)
  | RFRel !(RenameItem RelName)
  | RFTable !(RenameItem QualifiedTable)
  deriving (Show, Eq)

renameTableInCatalog
  :: (MonadTx m, CacheRM m)
  => QualifiedTable -> QualifiedTable -> m ()
renameTableInCatalog newQT oldQT = do
  sc <- askSchemaCache
  let allDeps = getDependentObjs sc $ SOTable oldQT
      renameFld = RFTable $ RenameItem oldQT newQT
  -- update all dependant schema objects
  forM_ allDeps $ updateSchemaObj oldQT renameFld
  -- -- Update table name in hdb_catalog
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

renameColInCatalog
  :: (MonadTx m, CacheRM m)
  => PGCol -> PGCol -> QualifiedTable -> TableInfo -> m ()
renameColInCatalog oCol nCol qt ti = do
  sc <- askSchemaCache
  -- Check if any relation exists with new column name
  assertFldNotExists
  -- Fetch dependent objects
  let depObjs = getDependentObjs sc $ SOTableObj qt $ TOCol oCol
      renameFld = RFCol $ RenameItem oCol nCol
  -- Update dependent objects
  forM_ depObjs $ updateSchemaObj qt renameFld
  where
    assertFldNotExists =
      case M.lookup (fromPGCol oCol) $ tiFieldInfoMap ti of
        Just (FIRelationship _) ->
          throw400 AlreadyExists $ "cannot rename column " <> oCol
          <<> " to " <> nCol <<> " in table " <> qt <<>
          " as a relationship with the name already exists"
        _ -> return ()

renameRelInCatalog
  :: (MonadTx m, CacheRM m)
  => QualifiedTable -> RelName -> RelName -> m ()
renameRelInCatalog qt oldRN newRN = do
  sc <- askSchemaCache
  let depObjs = getDependentObjs sc $ SOTableObj qt $ TORel oldRN
      renameFld = RFRel $ RenameItem oldRN newRN

  forM_ depObjs $ updateSchemaObj qt renameFld
  liftTx updateRelName
  where
    QualifiedObject sn tn = qt
    updateRelName =
      Q.unitQE defaultTxErrorHandler [Q.sql|
        UPDATE hdb_catalog.hdb_relationship
           SET rel_name = $1
         WHERE table_schema = $2
           AND table_name = $3
           AND rel_name = $4
      |] (newRN, sn, tn, oldRN) True


updateSchemaObj
  :: (MonadTx m, CacheRM m)
  => QualifiedTable -> RenameField -> SchemaObjId -> m ()
updateSchemaObj qt rf = \case
  SOTableObj depQT (TORel rn)       ->
    updateRelFlds qt depQT rn rf
  SOTableObj depQT (TOPerm role pt) ->
    updatePermFlds qt depQT role pt rf
  SOQTemplate _ -> return ()
  _ -> return ()

updateRelFlds
  :: (MonadTx m, CacheRM m)
  => QualifiedTable -> QualifiedTable -> RelName -> RenameField -> m ()
updateRelFlds qt depQT relName = \case
  RFCol (RenameItem oCol nCol) ->
    if qt == depQT
      then updateRelNativeCols oCol nCol qt relName
    else updateRelRemoteCols oCol nCol depQT relName
  RFTable (RenameItem oldQT newQT) ->
    updateRelDefs oldQT newQT depQT relName
  RFRel _ -> return ()

type RelTabModifier m = QualifiedTable -> QualifiedTable -> QualifiedTable -> RelName -> m ()

-- update table names in relationship definition
updateRelDefs :: (MonadTx m, CacheRM m) => RelTabModifier m
updateRelDefs oldQT newQT qt relName = do
  fim <- askFieldInfoMap qt
  ri <- askRelType fim relName ""
  case riType ri of
    ObjRel -> updateObjRelDef oldQT newQT qt relName
    ArrRel -> updateArrRelDef oldQT newQT qt relName

updateObjRelDef :: (MonadTx m) => RelTabModifier m
updateObjRelDef oldQT newQT qt rn = do
  oldDefV <- liftTx $ getRelDef qt rn
  oldDef :: ObjRelUsing <- decodeValue oldDefV
  case oldDef of
    RUFKeyOn _ -> return ()
    RUManual (ObjRelManualConfig (RelManualConfig dbQT rmCols)) -> do
      let newDef = mkObjRelUsing rmCols
      when (dbQT == oldQT ) $
        liftTx $ updateRel qt rn $ toJSON (newDef :: ObjRelUsing)
  where
    mkObjRelUsing colMap = RUManual $ ObjRelManualConfig $
      RelManualConfig newQT colMap

updateArrRelDef :: (MonadTx m) => RelTabModifier m
updateArrRelDef oldQT newQT qt rn = do
  oldDefV <- liftTx $ getRelDef qt rn
  oldDef  <- decodeValue oldDefV
  let (newDef, doUpdate) = mkNewArrRelUsing oldDef
  when doUpdate $ liftTx $ updateRel qt rn $ toJSON newDef
  where
    mkNewArrRelUsing arrRelUsing = case arrRelUsing of
      RUFKeyOn (ArrRelUsingFKeyOn dbQT c) ->
        ( RUFKeyOn $ ArrRelUsingFKeyOn newQT c
        , oldQT == dbQT
        )
      RUManual (ArrRelManualConfig (RelManualConfig dbQT rmCols)) ->
        ( RUManual $ ArrRelManualConfig $ RelManualConfig newQT rmCols
        , oldQT == dbQT
        )

getRelDef :: QualifiedTable -> RelName -> Q.TxE QErr Value
getRelDef (QualifiedObject sn tn) rn =
  Q.getAltJ . runIdentity . Q.getRow <$> Q.withQE defaultTxErrorHandler
    [Q.sql|
     SELECT rel_def::json FROM hdb_catalog.hdb_relationship
      WHERE table_schema = $1 AND table_name = $2
        AND rel_name = $3
    |] (sn, tn, rn) True

updateRel :: QualifiedTable -> RelName -> Value -> Q.TxE QErr ()
updateRel (QualifiedObject sn tn) rn relDef =
  Q.unitQE defaultTxErrorHandler [Q.sql|
           UPDATE hdb_catalog.hdb_relationship
              SET rel_def = $1 :: jsonb
            WHERE table_schema = $2
              AND table_name = $3
              AND rel_name = $4
                |] (Q.AltJ relDef, sn , tn, rn) True


-- | update fields in premissions
updatePermFlds :: (MonadTx m, CacheRM m)
  => QualifiedTable -> QualifiedTable
  -> RoleName -> PermType -> RenameField -> m ()
updatePermFlds qt depQT rn pt rf = do
  Q.AltJ pDef <- liftTx fetchPermDef
  case pt of
    PTInsert -> do
      perm <- decodeValue pDef
      updateInsPermCols rf qt depQT rn perm
    PTSelect -> do
      perm <- decodeValue pDef
      updateSelPermCols rf qt depQT rn perm
    PTUpdate -> do
      perm <- decodeValue pDef
      updateUpdPermCols rf qt depQT rn perm
    PTDelete -> do
      perm <- decodeValue pDef
      updateDelPermCols rf qt depQT rn perm
  where
    QualifiedObject sn tn = depQT
    fetchPermDef =
      runIdentity . Q.getRow <$>
        Q.withQE defaultTxErrorHandler [Q.sql|
                  SELECT perm_def::json
                    FROM hdb_catalog.hdb_permission
                   WHERE table_schema = $1
                     AND table_name = $2
                     AND role_name = $3
                     AND perm_type = $4
                 |] (sn, tn, rn, permTypeToCode pt) True

type PermModifier m a = RenameField -> QualifiedTable -> QualifiedTable -> RoleName -> a -> m ()

updateInsPermCols :: (MonadTx m, CacheRM m) => PermModifier m InsPerm
updateInsPermCols rf qt depQT rn (InsPerm chk preset cols) = do
  (updBoolExp, updNeededFromBoolExp) <- updateBoolExp qt depQT rf chk
  let updNeeded = updNeededFromPreset || updNeededFromBoolExp || updNeededFromCols
  when updNeeded $
    liftTx $ updatePermDefInCatalog PTInsert depQT rn $
      InsPerm updBoolExp updPreset updCols
  where
    (updPreset, updNeededFromPreset) = fromM $ updatePreset qt depQT rf <$> preset
    (updCols, updNeededFromCols) = fromM $ updateCols qt depQT rf <$> cols
    fromM = maybe (Nothing, False) (first Just)

updateSelPermCols :: (MonadTx m, CacheRM m) => PermModifier m SelPerm
updateSelPermCols rf qt depQT rn (SelPerm cols fltr limit aggAllwd) = do
  (updBoolExp, updNeededFromBoolExp) <- updateBoolExp qt depQT rf fltr
  when ( updNeededFromCols || updNeededFromBoolExp) $
    liftTx $ updatePermDefInCatalog PTSelect depQT rn $
      SelPerm updCols updBoolExp limit aggAllwd
  where
    (updCols, updNeededFromCols) = updateCols qt depQT rf cols

updateUpdPermCols :: (MonadTx m, CacheRM m) => PermModifier m UpdPerm
updateUpdPermCols rf qt depQT rn (UpdPerm cols fltr) = do
  (updBoolExp, updNeededFromBoolExp) <- updateBoolExp qt depQT rf fltr
  when ( updNeededFromCols || updNeededFromBoolExp) $
    liftTx $ updatePermDefInCatalog PTUpdate depQT rn $
      UpdPerm updCols updBoolExp
  where
    (updCols, updNeededFromCols) = updateCols qt depQT rf cols

updateDelPermCols :: (MonadTx m, CacheRM m) => PermModifier m DelPerm
updateDelPermCols rf qt depQT rn (DelPerm fltr) = do
  (updBoolExp, updNeededFromBoolExp) <- updateBoolExp qt depQT rf fltr
  when updNeededFromBoolExp $
    liftTx $ updatePermDefInCatalog PTDelete depQT rn $
      DelPerm updBoolExp

updatePreset
  :: QualifiedTable -> QualifiedTable
  -> RenameField -> Object -> (Object, Bool)
updatePreset qt depQT rf obj =
  if qt == depQT then
     case rf of
       RFCol (RenameItem oCol nCol) -> updatePreset' oCol nCol obj
       _                            -> (obj, False)
  else (obj, False)

updatePreset' :: PGCol -> PGCol -> Object -> (Object, Bool)
updatePreset' oCol nCol obj =
  (M.fromList updItems, or isUpds)
  where
    (updItems, isUpds) = unzip $ map procObjItem $ M.toList obj
    procObjItem (k, v) =
      let pgCol = PGCol k
          isUpdated = pgCol == oCol
          updCol = bool pgCol nCol isUpdated
      in ((getPGColTxt updCol, v), isUpdated)

updateCols
  :: QualifiedTable -> QualifiedTable
  -> RenameField -> PermColSpec -> (PermColSpec, Bool)
updateCols qt depQT rf permSpec =
  if qt == depQT then
    case rf of
      RFCol (RenameItem oCol nCol) -> updateCols' oCol nCol permSpec
      _                            -> (permSpec, False)
  else (permSpec, False)

updateCols' :: PGCol -> PGCol -> PermColSpec -> (PermColSpec, Bool)
updateCols' oCol nCol cols = case cols of
  PCStar -> (cols, False)
  PCCols c -> ( PCCols $ flip map c $ \col -> if col == oCol then nCol else col
              , oCol `elem` c
              )

updateBoolExp
  :: (QErrM m, CacheRM m)
  => QualifiedTable -> QualifiedTable
  -> RenameField -> BoolExp -> m (BoolExp, Bool)
updateBoolExp qt depQT rf be =
  case rf of
    RFCol (RenameItem oCol nCol) -> updateBoolExp' qt depQT (fromPGCol oCol) (fromPGCol nCol) be
    RFRel (RenameItem oRN nRN)   -> updateBoolExp' qt depQT (fromRel oRN) (fromRel nRN) be
    RFTable _                    -> return (be, False)

updateBoolExp'
  :: (QErrM m, CacheRM m)
  => QualifiedTable -> QualifiedTable
  -> FieldName -> FieldName -> BoolExp -> m (BoolExp, Bool)
updateBoolExp' qt depQT oFld nFld boolExp =
  first BoolExp <$> case unBoolExp boolExp of
    BoolAnd exps -> procBoolExps BoolAnd exps

    BoolOr exps -> procBoolExps BoolOr exps

    be@(BoolFld (ColExp fld v)) -> do
      let modBoolFld = BoolFld $ ColExp nFld v

          -- depQT == qt
          ifTabEqualsDepTab = return $
            bool (be, False) (modBoolFld, True) $ oFld == fld

          -- depQT /= qt
          ifTabNotEqsDepTabl = do
            fim <- askFieldInfoMap depQT
            remTable <- riRTable <$>
              askRelType fim (RelName $ getFieldNameTxt fld) ""
            colExp <- decodeValue v
            (ube, b) <- updateBoolExp' qt remTable oFld nFld colExp
            return (BoolFld $ ColExp fld (toJSON ube), b)

      bool ifTabNotEqsDepTabl ifTabEqualsDepTab $ depQT == qt

    BoolNot be -> do
      updatedExp <- updateBoolExp' qt depQT oFld nFld $ BoolExp be
      return ( BoolNot $ unBoolExp $ fst updatedExp
             , snd updatedExp
             )
  where
    updateExps exps = fmap unzip $ forM (map BoolExp exps) $
                      updateBoolExp' qt depQT oFld nFld
    procBoolExps f bExps = do
      (exps, bools) <- updateExps bExps
      return (f $ map unBoolExp exps, or bools)

-- update columns in relations
type RelColsModifier m = PGCol -> PGCol -> QualifiedTable -> RelName -> m ()

updateRelRemoteCols :: (MonadTx m, CacheRM m) => RelColsModifier m
updateRelRemoteCols oCol nCol depQT relName = do
  fim <- askFieldInfoMap depQT
  ri <- askRelType fim relName ""
  case riType ri of
    ObjRel -> updateObjRelRemoteCol oCol nCol depQT relName
    ArrRel -> updateArrRelRemoteCol oCol nCol depQT relName

updateObjRelRemoteCol :: (MonadTx m) => RelColsModifier m
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

updateArrRelRemoteCol :: (MonadTx m) => RelColsModifier m
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

updateRelNativeCols :: (MonadTx m, CacheRM m) => RelColsModifier m
updateRelNativeCols oCol nCol qt relName = do
  fim <- askFieldInfoMap qt
  ri <- askRelType fim relName ""
  case riType ri of
    ObjRel -> updateObjRelNativeCol oCol nCol qt relName
    ArrRel -> updateArrRelNativeCol oCol nCol qt relName

updateObjRelNativeCol :: (MonadTx m) => RelColsModifier m
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

updateArrRelNativeCol :: (MonadTx m) => RelColsModifier m
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
