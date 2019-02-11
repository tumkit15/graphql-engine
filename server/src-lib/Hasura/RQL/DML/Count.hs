module Hasura.RQL.DML.Count
  ( CountQueryP1(..)
  , getCountDeps
  , validateCountQWith
  , validateCountQ
  , runCount
  , countQToTx
  ) where

import           Data.Aeson
import           Instances.TH.Lift       ()

import qualified Data.ByteString.Builder as BB
import qualified Data.Sequence           as DS

import           Hasura.Prelude
import           Hasura.RQL.DML.Internal
import           Hasura.RQL.GBoolExp
import           Hasura.RQL.Types
import           Hasura.SQL.Types

import qualified Database.PG.Query       as Q
import qualified Hasura.SQL.DML          as S

data CountQueryP1
  = CountQueryP1
  { cqp1Table    :: !QualifiedTable
  , cqp1Where    :: !(AnnBoolExpSQL, Maybe AnnBoolExpSQL)
  , cqp1Distinct :: !(Maybe [PGCol])
  } deriving (Show, Eq)

getCountDeps
  :: CountQueryP1 -> [SchemaDependency]
getCountDeps (CountQueryP1 tn (_, mWc) mDistCols) =
  mkParentDep tn
  : fromMaybe [] whereDeps
  <> fromMaybe [] distDeps
  where
    distDeps   = map (mkColDep "untyped" tn) <$> mDistCols
    whereDeps   = getBoolExpDeps tn <$> mWc

mkSQLCount
  :: CountQueryP1 -> S.Select
mkSQLCount (CountQueryP1 tn (permFltr, mWc) mDistCols) =
  S.mkSelect
    { S.selExtr = [S.Extractor S.countStar Nothing]
    , S.selFrom = Just $ S.FromExp
                  [S.mkSelFromExp False innerSel $ TableName "r"]
    }
  where

    finalWC =
      toSQLBoolExp (S.QualTable tn) $
      maybe permFltr (andAnnBoolExps permFltr) mWc

    innerSel = partSel
      { S.selFrom  = Just $ S.mkSimpleFromExp tn
      , S.selWhere = S.WhereFrag <$> Just finalWC
      }

    partSel = case mDistCols of
      Just distCols ->
        let extrs = flip map distCols $ \c -> S.Extractor (S.mkSIdenExp c) Nothing
        in S.mkSelect
          { S.selDistinct = Just S.DistinctSimple
          , S.selExtr     = extrs
          }
      Nothing -> S.mkSelect
                 { S.selExtr = [S.Extractor S.SEStar Nothing] }

-- SELECT count(*) FROM (SELECT DISTINCT c1, .. cn FROM .. WHERE ..) r;
-- SELECT count(*) FROM (SELECT * FROM .. WHERE ..) r;
validateCountQWith
  :: (UserInfoM m, QErrM m, CacheRM m)
  => (PGColType -> Value -> m S.SQLExp)
  -> CountQuery
  -> m CountQueryP1
validateCountQWith prepValBuilder (CountQuery qt mDistCols mWhere) = do
  tableInfo <- askTabInfo qt

  -- Check if select is allowed
  selPerm <- modifyErr (<> selNecessaryMsg) $
             askSelPermInfo tableInfo

  let colInfoMap = tiFieldInfoMap tableInfo

  forM_ mDistCols $ \distCols -> do
    let distColAsrns = [ checkSelOnCol selPerm
                       , assertPGCol colInfoMap relInDistColsErr]
    withPathK "distinct" $ verifyAsrns distColAsrns distCols

  -- convert the where clause
  annSQLBoolExp <- forM mWhere $ \be ->
    withPathK "where" $
    convBoolExp' colInfoMap selPerm be prepValBuilder

  return $ CountQueryP1
    qt
    (spiFilter selPerm, annSQLBoolExp)
    mDistCols
  where
    selNecessaryMsg =
      "; \"count\" is only allowed if the role "
      <> "has \"select\" permissions on the table"
    relInDistColsErr =
      "Relationships can't be used in \"distinct\"."

validateCountQ
  :: (QErrM m, UserInfoM m, CacheRM m)
  => CountQuery -> m (CountQueryP1, DS.Seq Q.PrepArg)
validateCountQ =
  liftDMLP1 . validateCountQWith binRHSBuilder

countQToTx
  :: (QErrM m, MonadTx m)
  => (CountQueryP1, DS.Seq Q.PrepArg) -> m RespBody
countQToTx (u, p) = do
  qRes <- liftTx $ execSingleRowAndCol p $ mkSQLCount u
  return $ BB.toLazyByteString $ encodeCount qRes
  where
    encodeCount c =
      BB.byteString "{\"count\":" <> BB.intDec c <> BB.char7 '}'

runCount
  :: (QErrM m, UserInfoM m, CacheRWM m, MonadTx m)
  => CountQuery -> m RespBody
runCount q =
  validateCountQ q >>= countQToTx
