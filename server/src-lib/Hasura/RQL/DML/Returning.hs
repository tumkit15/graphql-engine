module Hasura.RQL.DML.Returning where

import           Hasura.Prelude
import           Hasura.RQL.DML.Internal
import           Hasura.RQL.DML.Select
import           Hasura.RQL.Types
import           Hasura.SQL.Types

import qualified Data.ByteString.Builder as BB
import qualified Data.Text               as T
import qualified Data.Vector             as V
import qualified Hasura.SQL.DML          as S

data MutQueryFld
  = MQFSimple !Bool !AnnSel
  | MQFAgg !AnnAggSel
  | MQFFunc !SQLFunctionSel
  | MQFExp !T.Text
  deriving (Show, Eq)
type MutQFlds = Fields MutQueryFld

data MutFld
  = MCount
  | MExp !T.Text
  | MRet ![(FieldName, AnnFld)]
  | MQuery !MutQFlds
  deriving (Show, Eq)

type MutFlds = [(T.Text, MutFld)]

pgColsFromMutFld :: MutFld -> [(PGCol, PGColType)]
pgColsFromMutFld = \case
  MCount   -> []
  MExp _   -> []
  MQuery _ -> []
  MRet selFlds ->
    flip mapMaybe selFlds $ \(_, annFld) -> case annFld of
    FCol (PGColInfo col colTy _) -> Just (col, colTy)
    _                            -> Nothing

pgColsFromMutFlds :: MutFlds -> [(PGCol, PGColType)]
pgColsFromMutFlds = concatMap (pgColsFromMutFld . snd)

mkDefaultMutFlds :: Maybe [PGColInfo] -> MutFlds
mkDefaultMutFlds = \case
  Nothing   -> mutFlds
  Just cols -> ("returning", MRet $ pgColsToSelFlds cols):mutFlds
  where
    mutFlds = [("affected_rows", MCount)]
    pgColsToSelFlds cols = flip map cols $ \pgColInfo ->
      (fromPGCol $ pgiName pgColInfo, FCol pgColInfo)

qualTableToAliasIden :: QualifiedTable -> Iden
qualTableToAliasIden qt =
  Iden $ snakeCaseTable qt <> "__mutation_result_alias"

mkMutQueryExp :: MutQFlds -> S.SQLExp
mkMutQueryExp qFlds =
  S.applyJsonBuildObj jsonBuildObjArgs
  where
    jsonBuildObjArgs =
      flip concatMap qFlds $
      \(k, qFld) -> [S.SELit $ getFieldNameTxt k, mkSQL qFld]
    mkSQL = \case
      MQFSimple singleObj annSel ->
        S.SESelect $ mkSQLSelect singleObj annSel
      MQFAgg annAggSel           ->
        S.SESelect $ mkAggSelect annAggSel
      MQFFunc sqlFuncSel         ->
        S.SESelectWith $ mkFuncSelectWith sqlFuncSel
      MQFExp e                   -> S.SELit e

mkMutFldExp :: QualifiedTable -> Bool -> MutFld -> S.SQLExp
mkMutFldExp qt singleObj = \case
  MCount -> S.SESelect $
    S.mkSelect
    { S.selExtr = [S.Extractor S.countStar Nothing]
    , S.selFrom = Just $ S.FromExp $ pure frmItem
    }
  MExp t -> S.SELit t
  MRet selFlds ->
    -- let tabFrom = TableFrom qt $ Just frmItem
    let tabFrom = TableFrom qt $ Just  $ qualTableToAliasIden qt
        tabPerm = TablePerm annBoolExpTrue Nothing
    in S.SESelect $ mkSQLSelect singleObj $
       AnnSelG selFlds tabFrom tabPerm noTableArgs
  MQuery qFlds -> mkMutQueryExp qFlds
  where
    frmItem = S.FIIden $ qualTableToAliasIden qt

mkSelWith
  :: QualifiedTable -> S.CTE -> MutFlds -> Bool -> S.SelectWith
mkSelWith qt cte mutFlds singleObj =
  S.SelectWith [(alias, cte)] sel
  where
    alias = S.Alias $ qualTableToAliasIden qt
    sel = S.mkSelect { S.selExtr = [S.Extractor extrExp Nothing] }

    extrExp = S.applyJsonBuildObj jsonBuildObjArgs

    jsonBuildObjArgs =
      flip concatMap mutFlds $
      \(k, mutFld) -> [S.SELit k, mkMutFldExp qt singleObj mutFld]

encodeJSONVector :: (a -> BB.Builder) -> V.Vector a -> BB.Builder
encodeJSONVector builder xs
  | V.null xs = BB.char7 '[' <> BB.char7 ']'
  | otherwise = BB.char7 '[' <> builder (V.unsafeHead xs) <>
                V.foldr go (BB.char7 ']') (V.unsafeTail xs)
    where go v b  = BB.char7 ',' <> builder v <> b

checkRetCols
  :: (UserInfoM m, QErrM m)
  => FieldInfoMap
  -> SelPermInfo
  -> [PGCol]
  -> m [PGColInfo]
checkRetCols fieldInfoMap selPermInfo cols = do
  mapM_ (checkSelOnCol selPermInfo) cols
  forM cols $ \col -> askPGColInfo fieldInfoMap col relInRetErr
  where
    relInRetErr = "Relationships can't be used in \"returning\"."
